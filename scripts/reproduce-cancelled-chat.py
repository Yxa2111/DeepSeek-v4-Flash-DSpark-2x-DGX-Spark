#!/usr/bin/env python3
"""A/B coherent chat reasoning after cancelling a real HTTP concurrency burst."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
from typing import Any
import urllib.request


SYSTEM_PROMPT = (
    "You are a senior Go distributed-systems engineer. Think rigorously, avoid "
    "repeating prior analysis, and finish with a concrete implementation plan."
)
TASK = """
Design a production migration for this repository from an in-memory scheduler
to a crash-consistent, sharded scheduler. Cover ownership boundaries, durable
state, request identity, cancellation, recovery ordering, backpressure,
observability, rollout, rollback, and tests. Identify race conditions and give
Go-like pseudocode for the critical state machine. Produce a detailed but
finite answer; do not repeat a section merely to make it longer.
""".strip()


def request_json(url: str, body: dict[str, object] | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    with urllib.request.urlopen(
        urllib.request.Request(url, data=data, headers=headers), timeout=60
    ) as response:
        return json.load(response)


def token_count(base_url: str, model: str, text: str) -> int:
    result = request_json(
        f"{base_url}/tokenize", {"model": model, "prompt": text}
    )
    if "count" in result:
        return int(result["count"])
    return len(result["tokens"])


def build_repository_context(
    base_url: str, model: str, target_tokens: int
) -> tuple[str, int]:
    lines = ["Synthetic repository inventory follows."]
    index = 0
    count = 0
    while count < target_tokens:
        shard = index % 37
        phase = (index * 7) % 23
        lines.append(
            f"Module {index:05d} scheduler/shard_{shard:02d}: phase {phase:02d}; "
            f"owns queue q{shard:02d}, persists generation {index * 13 + 5}, "
            "requires monotonic lease fencing, idempotent completion, bounded "
            "retry, and typed cancellation evidence."
        )
        index += 1
        if index % 128 == 0:
            count = token_count(base_url, model, "\n".join(lines))
    text = "\n".join(lines)
    return text, token_count(base_url, model, text)


def parse_chat_sse(
    raw: bytes,
) -> tuple[str, str, str | None, dict[str, int]]:
    reasoning_parts: list[str] = []
    content_parts: list[str] = []
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
            delta = choice.get("delta") or {}
            reasoning_parts.append(
                str(delta.get("reasoning") or delta.get("reasoning_content") or "")
            )
            content_parts.append(str(delta.get("content") or ""))
            if choice.get("finish_reason") is not None:
                finish_reason = str(choice["finish_reason"])
    return "".join(reasoning_parts), "".join(content_parts), finish_reason, usage


def metric_value(base_url: str, prefix: str) -> float:
    with urllib.request.urlopen(f"{base_url}/metrics", timeout=60) as response:
        raw = response.read().decode("utf-8", "replace")
    total = 0.0
    for line in raw.splitlines():
        if line.startswith(prefix):
            total += float(line.rsplit(" ", 1)[1])
    return total


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8888")
    parser.add_argument("--model", default="deepseek-v4-flash-0731")
    parser.add_argument("--concurrency", type=int, default=10)
    parser.add_argument("--context-tokens", type=int, default=32000)
    parser.add_argument("--max-tokens", type=int, default=16384)
    parser.add_argument("--cancel-after", type=float, default=5)
    parser.add_argument("--survivor", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--settle-seconds", type=float, default=10)
    parser.add_argument("--reasoning-trace", required=True)
    parser.add_argument("--content-trace", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    if args.concurrency < 1:
        parser.error("concurrency must be at least 1")
    if not 0 <= args.survivor < args.concurrency:
        parser.error("survivor must index a client")
    if min(args.context_tokens, args.max_tokens) <= 0:
        parser.error("context-tokens and max-tokens must be positive")

    base_url = args.base_url.rstrip("/")
    repository_context, measured_context_tokens = build_repository_context(
        base_url, args.model, args.context_tokens
    )
    processes: list[subprocess.Popen[bytes]] = []
    outputs: list[Path] = []
    started = time.perf_counter()

    with tempfile.TemporaryDirectory(prefix="dspark-chat-cancel-") as temp_dir:
        for index in range(args.concurrency):
            user_prompt = (
                repository_context
                + "\n\n"
                + TASK
                + f"\nRequest lane: {index}."
            )
            body = {
                "model": args.model,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_prompt},
                ],
                "stream": True,
                "stream_options": {"include_usage": True},
                "max_tokens": args.max_tokens,
                "temperature": 0.6,
                "top_p": 0.95,
                "chat_template_kwargs": {
                    "thinking": True,
                    "reasoning_effort": "max",
                },
            }
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
                    f"{base_url}/v1/chat/completions",
                ],
                stdin=subprocess.PIPE,
                stdout=output_handle,
                stderr=subprocess.PIPE,
            )
            assert process.stdin is not None
            process.stdin.write(json.dumps(body).encode())
            process.stdin.close()
            output_handle.close()
            processes.append(process)
            outputs.append(output_path)

        time.sleep(args.cancel_after)
        cancelled: list[int] = []
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

        survivor_raw = outputs[args.survivor].read_bytes()

    reasoning, content, finish_reason, usage = parse_chat_sse(survivor_raw)
    reasoning_path = Path(args.reasoning_trace)
    content_path = Path(args.content_trace)
    reasoning_path.parent.mkdir(parents=True, exist_ok=True)
    content_path.parent.mkdir(parents=True, exist_ok=True)
    reasoning_path.write_text(reasoning, encoding="utf-8")
    content_path.write_text(content, encoding="utf-8")

    time.sleep(args.settle_seconds)
    running = metric_value(base_url, "vllm:num_requests_running{")
    waiting = metric_value(base_url, "vllm:num_requests_waiting{")
    report: dict[str, Any] = {
        "schema_version": 1,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "base_url": base_url,
        "model": args.model,
        "concurrency": args.concurrency,
        "target_context_tokens": args.context_tokens,
        "measured_context_tokens": measured_context_tokens,
        "max_tokens": args.max_tokens,
        "cancel_after_s": args.cancel_after,
        "survivor": args.survivor,
        "cancelled": cancelled,
        "survivor_returncode": survivor_rc,
        "survivor_done": b"data: [DONE]" in survivor_raw,
        "survivor_timed_out": timed_out,
        "finish_reason": finish_reason,
        "usage": usage,
        "reasoning_chars": len(reasoning),
        "content_chars": len(content),
        "reasoning_sha256": hashlib.sha256(reasoning.encode()).hexdigest(),
        "content_sha256": hashlib.sha256(content.encode()).hexdigest(),
        "reasoning_trace": args.reasoning_trace,
        "content_trace": args.content_trace,
        "elapsed_s": time.perf_counter() - started,
        "final_running": running,
        "final_waiting": waiting,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)

    if (
        survivor_rc != 0
        or not report["survivor_done"]
        or timed_out
        or running
        or waiting
    ):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
