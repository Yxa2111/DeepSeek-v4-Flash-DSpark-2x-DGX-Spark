#!/usr/bin/env python3
"""Quick ~30–45 min stability: smoke → context ladder → soak → vision mid-ctx."""

from __future__ import annotations

import argparse
import base64
import json
import os
import signal
import statistics
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def request_json(url: str, body: dict | None = None, timeout: float = 3600) -> dict:
    data = None if body is None else json.dumps(body).encode()
    headers = {"Content-Type": "application/json"} if body is not None else {}
    req = urllib.request.Request(url, data=data, headers=headers, method="GET" if body is None else "POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def tokenize(base_url: str, model: str, prompt: str) -> int:
    tok_url = base_url.removesuffix("/v1") + "/tokenize"
    return request_json(tok_url, {"model": model, "prompt": prompt})["count"]


def build_prompt(base_url: str, model: str, target: int, nonce: str) -> str:
    unit = "stability context datum "
    text = f"unique request {nonce} " + unit * max(1, target // 3)
    while True:
        count = tokenize(base_url, model, text)
        if count >= target:
            return text
        text += unit * max(1, (target - count) // 3 + 1)


def chat_stream(
    base_url: str,
    model: str,
    messages: list,
    *,
    max_tokens: int = 128,
    temperature: float = 0.0,
    thinking: bool = False,
    timeout: float = 3600,
) -> dict:
    body = {
        "model": model,
        "messages": messages,
        "stream": True,
        "stream_options": {"include_usage": True},
        "max_tokens": max_tokens,
        "temperature": temperature,
        "chat_template_kwargs": {"thinking": thinking},
    }
    req = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    first = None
    usage = None
    finish_reason = None
    saw_choice = False
    saw_done = False
    parts: list[str] = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                saw_done = True
                break
            event = json.loads(payload)
            choices = event.get("choices") or []
            delta = choices[0].get("delta", {}) if choices else {}
            content = delta.get("content") or ""
            reasoning = delta.get("reasoning") or delta.get("reasoning_content") or ""
            if first is None and (content or reasoning):
                first = time.perf_counter()
            if choices:
                saw_choice = True
                for choice in choices:
                    if choice.get("finish_reason") is not None:
                        finish_reason = str(choice["finish_reason"])
            parts.extend((content, reasoning))
            if event.get("usage"):
                usage = event["usage"]
    finished = time.perf_counter()
    if not saw_done:
        raise RuntimeError("chat stream ended before SSE [DONE]")
    if not saw_choice:
        raise RuntimeError("chat stream ended without a choice event")
    if finish_reason is None:
        raise RuntimeError("chat stream ended without a finish reason")
    required_usage = {"prompt_tokens", "completion_tokens", "total_tokens"}
    missing_usage = required_usage - set(usage or {})
    if missing_usage:
        missing = ", ".join(sorted(missing_usage))
        raise RuntimeError(f"chat stream is missing usage fields: {missing}")
    text = "".join(parts)
    prompt_tokens = (usage or {}).get("prompt_tokens", 0)
    output_tokens = (usage or {}).get("completion_tokens", 0)
    ttft = (first or finished) - started
    decode_s = max(0.001, finished - (first or finished))
    return {
        "ok": bool(text.strip()) or output_tokens > 0,
        "ttft_s": ttft,
        "elapsed_s": finished - started,
        "prompt_tokens": prompt_tokens,
        "output_tokens": output_tokens,
        "finish_reason": finish_reason,
        "stream_complete": True,
        "prefill_tok_s": prompt_tokens / max(0.001, ttft),
        "output_tok_s": output_tokens / decode_s,
        "preview": text[:240].replace("\n", " "),
    }


def vision_chat(vl_url: str, model: str, image_b64: str, prompt: str, timeout: float = 600) -> dict:
    body = {
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
                    {"type": "text", "text": prompt},
                ],
            }
        ],
        "max_tokens": 64,
        "temperature": 0.0,
    }
    started = time.perf_counter()
    data = request_json(f"{vl_url}/chat/completions", body, timeout=timeout)
    elapsed = time.perf_counter() - started
    content = (((data.get("choices") or [{}])[0].get("message") or {}).get("content")) or ""
    usage = data.get("usage") or {}
    return {
        "ok": bool(str(content).strip()),
        "elapsed_s": elapsed,
        "prompt_tokens": usage.get("prompt_tokens", 0),
        "output_tokens": usage.get("completion_tokens", 0),
        "preview": str(content)[:240].replace("\n", " "),
    }


def ensure_image(path: Path) -> Path:
    if path.exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        from PIL import Image
    except ImportError:
        import subprocess

        subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "pillow", "-q"])
        from PIL import Image

    Image.new("RGB", (96, 96), (220, 20, 20)).save(path, quality=90)
    return path


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc).strftime('%H:%M:%S')}Z] {msg}", flush=True)


def soak_checkpoint(
    rounds: list[dict],
    *,
    complete: bool,
    interrupted: bool = False,
    error: str | None = None,
) -> dict:
    """Build a truthful durable soak state for partial and terminal reports."""
    rounds_ok = bool(rounds) and all(r.get("ok") for r in rounds)
    phase = {
        "rounds": rounds,
        "rounds_ok": rounds_ok,
        "complete": complete,
        "interrupted": interrupted,
        "ok": complete and rounds_ok and not interrupted,
    }
    if error:
        phase["error"] = error
    return phase


def atomic_write_json(path: Path, value: dict) -> None:
    """Atomically publish one private JSON checkpoint and fsync its directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8888/v1")
    parser.add_argument("--vl-url", default="http://127.0.0.1:8889/v1")
    parser.add_argument("--model", default="deepseek-v4-flash-0731")
    parser.add_argument("--vl-model", default="qwen3-vl-4b")
    parser.add_argument(
        "--skip-vl",
        action="store_true",
        default=os.environ.get("ENABLE_VL_SIDECAR", "0") != "1",
        help="Skip vision-sidecar checks (readiness probe and phase 3). Defaults to "
             "skipping unless ENABLE_VL_SIDECAR=1, so the text-only serve profile "
             "runs out of the box.",
    )
    parser.add_argument(
        "--ladder",
        default="8192,32768,131072,262144",
        help="Comma-separated prompt token targets for the context ladder",
    )
    parser.add_argument("--decode-tokens", type=int, default=64)
    parser.add_argument("--soak-minutes", type=float, default=12.0)
    parser.add_argument("--soak-prompt-tokens", type=int, default=32768)
    parser.add_argument("--soak-concurrency", type=int, default=2)
    parser.add_argument("--vision-prefix-tokens", type=int, default=65536)
    parser.add_argument("--image", default="results/smoke-solid-red.jpg")
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    out = Path(
        args.output
        or f"results/stability-quick-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}.json"
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    report: dict = {
        "schema_version": 2,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "base_url": args.base_url,
        "vl_url": args.vl_url,
        "model": args.model,
        "vl_model": args.vl_model,
        "phases": {},
        "failures": [],
    }

    def save() -> None:
        report["updated_at"] = datetime.now(timezone.utc).isoformat()
        atomic_write_json(out, report)

    def interrupt(_signum: int, _frame: object) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)

    # --- Phase 0: readiness ---
    log("Phase 0: readiness smoke")
    try:
        main_models = request_json(f"{args.base_url}/models", timeout=30)
        vl_models = {} if args.skip_vl else request_json(f"{args.vl_url}/models", timeout=30)
        smoke = chat_stream(
            args.base_url,
            args.model,
            [{"role": "user", "content": "Reply with exactly: OK"}],
            max_tokens=16,
            thinking=False,
            timeout=180,
        )
        if not smoke["ok"] or "OK" not in smoke["preview"].upper():
            raise RuntimeError(f"text smoke bad: {smoke}")
        if args.skip_vl:
            vsmoke = {"ok": True, "skipped": True, "preview": "(skipped)", "elapsed_s": 0.0}
        else:
            img = ensure_image(Path(args.image))
            b64 = base64.b64encode(img.read_bytes()).decode()
            vsmoke = vision_chat(args.vl_url, args.vl_model, b64, "One word: what color is this solid square?")
            if not vsmoke["ok"]:
                raise RuntimeError(f"vision smoke failed: {vsmoke}")
        report["phases"]["readiness"] = {
            "main_model": (main_models.get("data") or [{}])[0].get("id"),
            "main_max_model_len": (main_models.get("data") or [{}])[0].get("max_model_len"),
            "vl_model": (vl_models.get("data") or [{}])[0].get("id"),
            "text_smoke": smoke,
            "vision_smoke": vsmoke,
            "ok": True,
        }
        log(f"  text OK ({smoke['elapsed_s']:.1f}s); vision '{vsmoke['preview']}' ({vsmoke['elapsed_s']:.1f}s)")
    except Exception as exc:  # noqa: BLE001
        report["phases"]["readiness"] = {"ok": False, "error": str(exc)}
        report["failures"].append({"phase": "readiness", "error": str(exc)})
        save()
        log(f"FAIL readiness: {exc}")
        return 1
    save()

    # --- Phase 1: context ladder ---
    log("Phase 1: context ladder")
    ladder_cases = []
    for target in [int(x) for x in args.ladder.split(",") if x.strip()]:
        log(f"  building ~{target} tok prompt…")
        t0 = time.perf_counter()
        try:
            prompt = build_prompt(args.base_url, args.model, target, f"ladder-{target}")
            build_s = time.perf_counter() - t0
            messages = [
                {
                    "role": "user",
                    "content": (
                        prompt
                        + "\n\nIgnore the filler. Reply with exactly: LADDER_OK "
                        + str(target)
                    ),
                }
            ]
            log(f"  decoding @ ~{target} (build {build_s:.1f}s)…")
            result = chat_stream(
                args.base_url,
                args.model,
                messages,
                max_tokens=args.decode_tokens,
                thinking=False,
                timeout=3600,
            )
            result["target_prompt_tokens"] = target
            result["build_s"] = build_s
            result["ok"] = result["ok"] and "LADDER_OK" in result["preview"].upper()
            if not result["ok"]:
                report["failures"].append({"phase": "ladder", "target": target, "result": result})
            ladder_cases.append(result)
            log(
                f"  {'PASS' if result['ok'] else 'FAIL'} {target}: "
                f"prompt={result['prompt_tokens']} out={result['output_tokens']} "
                f"ttft={result['ttft_s']:.1f}s decode={result['output_tok_s']:.1f} tok/s "
                f"preview={result['preview'][:80]!r}"
            )
        except Exception as exc:  # noqa: BLE001
            case = {"target_prompt_tokens": target, "ok": False, "error": str(exc)}
            ladder_cases.append(case)
            report["failures"].append({"phase": "ladder", "target": target, "error": str(exc)})
            log(f"  FAIL {target}: {exc}")
        report["phases"]["ladder"] = {"cases": ladder_cases, "ok": all(c.get("ok") for c in ladder_cases)}
        save()

    # --- Phase 2: concurrent soak ---
    log(f"Phase 2: soak {args.soak_minutes:.0f}m @ {args.soak_prompt_tokens} tok ×{args.soak_concurrency}")
    soak_deadline = time.time() + args.soak_minutes * 60
    soak_rounds: list[dict] = []
    soak_error: str | None = None
    round_i = 0
    report["phases"]["soak"] = soak_checkpoint(soak_rounds, complete=False)
    save()
    try:
        while time.time() < soak_deadline:
            round_i += 1
            remaining = soak_deadline - time.time()
            log(f"  soak round {round_i} ({remaining / 60:.1f}m left)…")
            try:
                prompts = [
                    build_prompt(
                        args.base_url,
                        args.model,
                        args.soak_prompt_tokens,
                        f"soak-r{round_i}-c{c}",
                    )
                    for c in range(args.soak_concurrency)
                ]
                # sequential within round to avoid hammering RAM while building; parallel decode
                import concurrent.futures

                def one(idx: int, prompt: str) -> dict:
                    return chat_stream(
                        args.base_url,
                        args.model,
                        [
                            {
                                "role": "user",
                                "content": prompt + f"\n\nReply with exactly: SOAK_OK {round_i}-{idx}",
                            }
                        ],
                        max_tokens=48,
                        thinking=False,
                    )

                with concurrent.futures.ThreadPoolExecutor(max_workers=args.soak_concurrency) as pool:
                    futs = [pool.submit(one, i, p) for i, p in enumerate(prompts)]
                    results = [f.result() for f in futs]
                ok = all(
                    r.get("ok") and "SOAK_OK" in r.get("preview", "").upper()
                    for r in results
                )
                med_out = statistics.median(r["output_tok_s"] for r in results)
                round_rec = {
                    "round": round_i,
                    "ok": ok,
                    "median_output_tok_s": med_out,
                    "results": results,
                }
                if not ok:
                    report["failures"].append(
                        {"phase": "soak", "round": round_i, "results": results}
                    )
                soak_rounds.append(round_rec)
                log(
                    f"  {'PASS' if ok else 'FAIL'} round {round_i}: "
                    f"median decode {med_out:.1f} tok/s"
                )
                if not ok:
                    soak_error = f"soak round {round_i} returned an invalid response"
            except Exception as exc:  # noqa: BLE001
                soak_rounds.append({"round": round_i, "ok": False, "error": str(exc)})
                report["failures"].append(
                    {"phase": "soak", "round": round_i, "error": str(exc)}
                )
                log(f"  FAIL round {round_i}: {exc}")
                soak_error = str(exc)
            report["phases"]["soak"] = soak_checkpoint(
                soak_rounds,
                complete=False,
                error=soak_error,
            )
            save()
            if soak_error is not None:
                break
    except KeyboardInterrupt:
        error = "interrupted before configured soak duration elapsed"
        report["phases"]["soak"] = soak_checkpoint(
            soak_rounds,
            complete=False,
            interrupted=True,
            error=error,
        )
        report["failures"].append({"phase": "soak", "error": error})
        report["interrupted_at"] = datetime.now(timezone.utc).isoformat()
        report["ok"] = False
        save()
        log(f"FAIL soak: {error} → {out}")
        return 130

    if soak_error is not None:
        report["ok"] = False
        save()
        log(f"FAIL soak: {soak_error} → {out}")
        return 1

    report["phases"]["soak"] = soak_checkpoint(soak_rounds, complete=True)
    save()

    # --- Phase 3: vision while holding long 0731 prefix ---
    if args.skip_vl:
        log("Phase 3: vision mid-context SKIPPED (no vision sidecar; --skip-vl)")
        report["phases"]["vision_mid"] = {"skipped": True, "ok": True}
        save()
    else:
        log(f"Phase 3: vision mid-context (0731 prefix ~{args.vision_prefix_tokens})")
        try:
            prefix = build_prompt(
                args.base_url, args.model, args.vision_prefix_tokens, "vision-prefix"
            )
            # Hold KV with a short decode first
            hold = chat_stream(
                args.base_url,
                args.model,
                [
                    {
                        "role": "user",
                        "content": prefix + "\n\nReply with exactly: PREFIX_HELD",
                    }
                ],
                max_tokens=32,
                thinking=False,
            )
            img = ensure_image(Path(args.image))
            b64 = base64.b64encode(img.read_bytes()).decode()
            vmid = vision_chat(
                args.vl_url,
                args.vl_model,
                b64,
                "One word color of this solid square (expect Red).",
            )
            # Continue on 0731 after VL call (new request; proves API still healthy)
            resume = chat_stream(
                args.base_url,
                args.model,
                [
                    {
                        "role": "user",
                        "content": prefix + "\n\nReply with exactly: AFTER_VISION_OK",
                    }
                ],
                max_tokens=32,
                thinking=False,
            )
            ok = (
                hold.get("ok")
                and "PREFIX_HELD" in hold.get("preview", "").upper()
                and vmid.get("ok")
                and resume.get("ok")
                and "AFTER_VISION_OK" in resume.get("preview", "").upper()
            )
            phase = {"hold": hold, "vision": vmid, "resume": resume, "ok": ok}
            if not ok:
                report["failures"].append({"phase": "vision_mid", "detail": phase})
            report["phases"]["vision_mid"] = phase
            log(
                f"  {'PASS' if ok else 'FAIL'} hold={hold.get('prompt_tokens')} "
                f"vision='{vmid.get('preview')}' resume={resume.get('preview', '')[:40]!r}"
            )
        except Exception as exc:  # noqa: BLE001
            report["phases"]["vision_mid"] = {"ok": False, "error": str(exc)}
            report["failures"].append({"phase": "vision_mid", "error": str(exc)})
            log(f"  FAIL vision_mid: {exc}")
        save()

    report["finished_at"] = datetime.now(timezone.utc).isoformat()
    report["ok"] = not report["failures"] and all(
        (report["phases"].get(name) or {}).get("ok") for name in ("readiness", "ladder", "soak", "vision_mid")
    )
    save()
    elapsed = (
        datetime.fromisoformat(report["finished_at"]) - datetime.fromisoformat(report["started_at"])
    ).total_seconds()
    log(f"{'PASS' if report['ok'] else 'FAIL'} overall in {elapsed / 60:.1f}m → {out}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
