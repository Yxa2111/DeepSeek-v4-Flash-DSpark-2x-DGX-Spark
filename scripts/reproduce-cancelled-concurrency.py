#!/usr/bin/env python3
"""Stress vLLM by disconnecting all but one concurrent streaming request.

This reproduces the operational shape where a burst of clients is stopped and
one older long-running request must continue to completion.  It deliberately
uses curl subprocesses so terminating a client closes the HTTP connection,
rather than merely cancelling a local asyncio task.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tempfile
import time
from typing import Any
import urllib.request


TOKEN_CORPUS = (
    "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi "
    "omicron pi rho sigma tau upsilon phi chi psi omega code repository test "
    "compiler scheduler storage inference deterministic cancellation survivor"
)


def request_json(url: str, body: dict[str, object] | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    with urllib.request.urlopen(
        urllib.request.Request(url, data=data, headers=headers), timeout=60
    ) as response:
        return json.load(response)


def metric_value(base_url: str, name: str) -> float:
    with urllib.request.urlopen(f"{base_url}/metrics", timeout=60) as response:
        metrics = response.read().decode("utf-8", "replace")
    total = 0.0
    for line in metrics.splitlines():
        if not line.startswith(name):
            continue
        try:
            total += float(line.rsplit(" ", 1)[1])
        except (IndexError, ValueError):
            pass
    return total


def error_summary(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"


def parse_completion_sse(raw: bytes) -> tuple[str, str | None, dict[str, int]]:
    text_parts: list[str] = []
    finish_reason: str | None = None
    usage: dict[str, int] = {}
    for raw_line in raw.splitlines():
        line = raw_line.decode("utf-8", "replace").strip()
        if not line.startswith("data: "):
            continue
        payload = line[6:]
        if payload == "[DONE]":
            continue
        event = json.loads(payload)
        if isinstance(event.get("usage"), dict):
            usage = {
                key: int(value)
                for key, value in event["usage"].items()
                if isinstance(value, (int, float))
            }
        for choice in event.get("choices", []):
            text_parts.append(str(choice.get("text", "")))
            if choice.get("finish_reason") is not None:
                finish_reason = str(choice["finish_reason"])
    return "".join(text_parts), finish_reason, usage


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8888")
    parser.add_argument("--model", default="deepseek-v4-flash-0731")
    parser.add_argument("--concurrency", type=int, default=10)
    parser.add_argument("--prompt-tokens", type=int, default=8192)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--cancel-after", type=float, default=5)
    parser.add_argument("--settle-seconds", type=float, default=5)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--seed", type=int, default=53569)
    parser.add_argument("--survivor", type=int, default=0)
    parser.add_argument("--survivor-trace")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.concurrency < 2:
        parser.error("concurrency must be at least 2")
    if not 0 <= args.survivor < args.concurrency:
        parser.error("survivor must index one of the concurrent clients")
    if min(args.prompt_tokens, args.max_tokens) <= 0:
        parser.error("prompt-tokens and max-tokens must be positive")

    base_url = args.base_url.rstrip("/")
    pool = request_json(
        f"{base_url}/tokenize", {"model": args.model, "prompt": TOKEN_CORPUS}
    )["tokens"]
    rng = random.Random(f"cancelled-concurrency:{args.seed}:{args.prompt_tokens}")
    common_prompt = [int(pool[rng.randrange(len(pool))]) for _ in range(args.prompt_tokens)]
    started_at = time.perf_counter()
    processes: list[subprocess.Popen[bytes]] = []
    outputs: list[Path] = []

    with tempfile.TemporaryDirectory(prefix="dspark-cancel-") as temp_dir:
        for index in range(args.concurrency):
            prompt = list(common_prompt)
            prompt[-1] = int(pool[index % len(pool)])
            body = json.dumps(
                {
                    "model": args.model,
                    "prompt": prompt,
                    "max_tokens": args.max_tokens,
                    "temperature": 0,
                    "seed": args.seed + index,
                    "ignore_eos": True,
                    "stream": True,
                    "stream_options": {"include_usage": True},
                }
            ).encode()
            output_path = Path(temp_dir) / f"client-{index}.sse"
            output_handle = output_path.open("wb")
            process = subprocess.Popen(
                [
                    "curl",
                    "-sS",
                    "-N",
                    "--max-time",
                    str(args.timeout),
                    "-H",
                    "Content-Type: application/json",
                    "--data-binary",
                    "@-",
                    f"{base_url}/v1/completions",
                ],
                stdin=subprocess.PIPE,
                stdout=output_handle,
                stderr=subprocess.PIPE,
            )
            assert process.stdin is not None
            process.stdin.write(body)
            process.stdin.close()
            output_handle.close()
            processes.append(process)
            outputs.append(output_path)

        time.sleep(args.cancel_after)
        cancelled = []
        for index, process in enumerate(processes):
            if index == args.survivor:
                continue
            if process.poll() is None:
                process.terminate()
            cancelled.append(index)

        survivor = processes[args.survivor]
        timed_out = False
        try:
            survivor_rc = survivor.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            survivor.kill()
            survivor_rc = survivor.wait()

        for index, process in enumerate(processes):
            if index == args.survivor:
                continue
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

        survivor_body = outputs[args.survivor].read_bytes()
        survivor_done = b"data: [DONE]" in survivor_body
        survivor_sha256 = hashlib.sha256(survivor_body).hexdigest()
        survivor_text, survivor_finish_reason, survivor_usage = \
            parse_completion_sse(survivor_body)

    if args.survivor_trace:
        trace_path = Path(args.survivor_trace)
        trace_path.parent.mkdir(parents=True, exist_ok=True)
        trace_path.write_text(survivor_text, encoding="utf-8")

    time.sleep(args.settle_seconds)
    metrics_error: str | None = None
    running: float | None = None
    waiting: float | None = None
    try:
        running = metric_value(base_url, "vllm:num_requests_running{")
        waiting = metric_value(base_url, "vllm:num_requests_waiting{")
    except Exception as exc:  # The engine may have crashed under the probe.
        metrics_error = error_summary(exc)
    elapsed = time.perf_counter() - started_at
    report: dict[str, Any] = {
        "schema_version": 1,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "base_url": base_url,
        "model": args.model,
        "concurrency": args.concurrency,
        "prompt_tokens": args.prompt_tokens,
        "max_tokens": args.max_tokens,
        "cancel_after_s": args.cancel_after,
        "survivor": args.survivor,
        "cancelled": cancelled,
        "survivor_returncode": survivor_rc,
        "survivor_done": survivor_done,
        "survivor_timed_out": timed_out,
        "survivor_sse_sha256": survivor_sha256,
        "survivor_text_sha256": hashlib.sha256(
            survivor_text.encode("utf-8")
        ).hexdigest(),
        "survivor_text_chars": len(survivor_text),
        "survivor_finish_reason": survivor_finish_reason,
        "survivor_usage": survivor_usage,
        "survivor_trace": args.survivor_trace,
        "elapsed_s": elapsed,
        "final_running": running,
        "final_waiting": waiting,
        "metrics_error": metrics_error,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)

    if (
        survivor_rc != 0
        or not survivor_done
        or timed_out
        or running is None
        or waiting is None
        or running
        or waiting
    ):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
