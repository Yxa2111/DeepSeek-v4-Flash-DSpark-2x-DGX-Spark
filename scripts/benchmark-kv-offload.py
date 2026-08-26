#!/usr/bin/env python3
"""Deterministic cold/hot prefix probe for vLLM external KV offload."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import random
import re
import time
import urllib.request


TOKEN_CORPUS = (
    "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi "
    "omicron pi rho sigma tau upsilon phi chi psi omega hardware software "
    "memory compute network storage inference benchmark deterministic offload"
)
METRIC_PREFIXES = (
    "vllm:external_prefix_cache_",
    "vllm:kv_offload_",
    "vllm:request_prefill_",
    "vllm:prompt_tokens_",
)
METRIC_RE = re.compile(
    r"^(?P<name>[A-Za-z_:][A-Za-z0-9_:]*)(?:\{[^}]*\})?\s+"
    r"(?P<value>[-+0-9.eE]+)$"
)


def request_json(url: str, body: dict[str, object] | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    with urllib.request.urlopen(
        urllib.request.Request(url, data=data, headers=headers), timeout=60
    ) as response:
        return json.load(response)


def fetch_metrics(base_url: str) -> dict[str, float]:
    with urllib.request.urlopen(f"{base_url}/metrics", timeout=60) as response:
        text = response.read().decode("utf-8", "replace")
    return parse_metrics(text)


def parse_metrics(text: str) -> dict[str, float]:
    values: dict[str, float] = {}
    for line in text.splitlines():
        match = METRIC_RE.match(line)
        if not match or not match["name"].startswith(METRIC_PREFIXES):
            continue
        name = match["name"]
        values[name] = values.get(name, 0.0) + float(match["value"])
    return values


def metric_delta(before: dict[str, float], after: dict[str, float]) -> dict[str, float]:
    return {
        name: after.get(name, 0.0) - before.get(name, 0.0)
        for name in sorted(before.keys() | after.keys())
        if after.get(name, 0.0) - before.get(name, 0.0) != 0
    }


def tokenize(base_url: str, model: str) -> list[int]:
    response = request_json(
        f"{base_url}/tokenize", {"model": model, "prompt": TOKEN_CORPUS}
    )
    return [int(token) for token in response["tokens"]]


def make_prompt(pool: list[int], size: int, seed: int) -> list[int]:
    if not pool:
        raise RuntimeError("tokenizer returned an empty token pool")
    rng = random.Random(f"dspark-kv-offload:{seed}:{size}")
    return [pool[rng.randrange(len(pool))] for _ in range(size)]


def run_completion(
    base_url: str, model: str, prompt: list[int], max_tokens: int, timeout: float
) -> dict[str, object]:
    body = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "temperature": 0,
        "seed": 1,
        "ignore_eos": True,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    request = urllib.request.Request(
        f"{base_url}/v1/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    started = time.perf_counter()
    first_event: float | None = None
    text_parts: list[str] = []
    usage: dict[str, int] = {}
    finish_reason = None
    with urllib.request.urlopen(request, timeout=timeout) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            event = json.loads(payload)
            if event.get("usage"):
                usage = {
                    key: int(value)
                    for key, value in event["usage"].items()
                    if isinstance(value, (int, float))
                }
            choices = event.get("choices", [])
            if choices and first_event is None:
                first_event = time.perf_counter()
            for choice in choices:
                text_parts.append(str(choice.get("text", "")))
                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]
    finished = time.perf_counter()
    completion = "".join(text_parts)
    return {
        "ttft_s": (first_event or finished) - started,
        "elapsed_s": finished - started,
        "usage": usage,
        "finish_reason": finish_reason,
        "completion_sha256": hashlib.sha256(completion.encode()).hexdigest(),
        "completion_bytes": len(completion.encode()),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8888")
    parser.add_argument("--model", default="deepseek-v4-flash-0731")
    parser.add_argument("--phase", required=True, choices=("cold", "hot", "repeat"))
    parser.add_argument("--case", required=True)
    parser.add_argument("--sizes", default="8192,32768,100000")
    parser.add_argument("--seed", type=int, default=53569)
    parser.add_argument("--max-tokens", type=int, default=1)
    parser.add_argument("--settle-seconds", type=float, default=10)
    parser.add_argument("--timeout", type=float, default=1800)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    sizes = [int(value) for value in args.sizes.split(",")]
    if any(size <= 0 for size in sizes) or args.max_tokens <= 0:
        parser.error("sizes and max-tokens must be positive")

    version = request_json(f"{base_url}/version").get("version", "unknown")
    pool = tokenize(base_url, args.model)
    results = []
    for size in sizes:
        prompt = make_prompt(pool, size, args.seed)
        prompt_sha256 = hashlib.sha256(
            ",".join(str(token) for token in prompt).encode()
        ).hexdigest()
        before = fetch_metrics(base_url)
        completion = run_completion(
            base_url, args.model, prompt, args.max_tokens, args.timeout
        )
        time.sleep(args.settle_seconds)
        after = fetch_metrics(base_url)
        delta = metric_delta(before, after)
        result = {
            "target_tokens": size,
            "prompt_sha256": prompt_sha256,
            **completion,
            "metrics_delta": delta,
        }
        results.append(result)
        print(
            f"{args.case}/{args.phase} {size}: TTFT={completion['ttft_s']:.3f}s "
            f"elapsed={completion['elapsed_s']:.3f}s metrics={json.dumps(delta, sort_keys=True)}",
            flush=True,
        )

    report = {
        "schema_version": 1,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "case": args.case,
        "phase": args.phase,
        "base_url": base_url,
        "model": args.model,
        "version": version,
        "sizes": sizes,
        "seed": args.seed,
        "max_tokens": args.max_tokens,
        "settle_seconds": args.settle_seconds,
        "token_pool_sha256": hashlib.sha256(
            ",".join(str(token) for token in pool).encode()
        ).hexdigest(),
        "results": results,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
