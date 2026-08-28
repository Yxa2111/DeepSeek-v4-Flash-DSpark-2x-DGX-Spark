#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock


PATH = Path(__file__).with_name("benchmark-kv-offload.py")
SPEC = importlib.util.spec_from_file_location("benchmark_kv_offload", PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeResponse:
    def __init__(self, lines):
        self.lines = lines

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def __iter__(self):
        return iter(self.lines)


class BenchmarkKVOffloadTest(unittest.TestCase):
    def test_request_headers_use_first_configured_key_without_logging_it(self):
        with mock.patch.dict(
            MODULE.os.environ,
            {"DSPARK_API_KEYS": "first-key second-key"},
            clear=True,
        ):
            headers = MODULE.request_headers(json_body=True)
        self.assertEqual(headers["Authorization"], "Bearer first-key")
        self.assertEqual(headers["Content-Type"], "application/json")

    def test_vllm_api_key_takes_precedence(self):
        with mock.patch.dict(
            MODULE.os.environ,
            {
                "DSPARK_API_KEYS": "configured-key",
                "VLLM_API_KEY": "legacy-key",
            },
            clear=True,
        ):
            headers = MODULE.request_headers()
        self.assertEqual(headers, {"Authorization": "Bearer legacy-key"})

    def test_metric_parser_sums_labels_and_filters(self):
        parsed = MODULE.parse_metrics(
            """
vllm:kv_offload_load_bytes_total{engine="0"} 10
vllm:kv_offload_load_bytes_total{engine="1"} 20
vllm:external_prefix_cache_hits_total 3
unrelated_metric 99
"""
        )
        self.assertEqual(parsed["vllm:kv_offload_load_bytes_total"], 30)
        self.assertEqual(parsed["vllm:external_prefix_cache_hits_total"], 3)
        self.assertNotIn("unrelated_metric", parsed)

    def test_metric_delta_keeps_new_metrics(self):
        self.assertEqual(MODULE.metric_delta({"a": 2}, {"a": 5, "b": 7}), {"a": 3, "b": 7})

    def test_prompt_is_deterministic_and_size_scoped(self):
        pool = [1, 2, 3, 4]
        self.assertEqual(MODULE.make_prompt(pool, 32, 9), MODULE.make_prompt(pool, 32, 9))
        self.assertNotEqual(MODULE.make_prompt(pool, 32, 9), MODULE.make_prompt(pool, 32, 10))
        self.assertEqual(len(MODULE.make_prompt(pool, 17, 9)), 17)

    def test_completion_rejects_stream_eof_before_done(self):
        response = FakeResponse(
            [
                b'data: {"choices": [{"text": "", "finish_reason": null}]}\n',
            ]
        )
        with mock.patch.object(MODULE.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(RuntimeError, r"before SSE \[DONE\]"):
                MODULE.run_completion("http://test", "model", [1], 1, 5)

    def test_completion_accepts_complete_stream_with_usage(self):
        usage = {
            "prompt_tokens": 1,
            "completion_tokens": 1,
            "total_tokens": 2,
        }
        response = FakeResponse(
            [
                b'data: {"choices": [{"text": "x", "finish_reason": "length"}]}\n',
                f"data: {json.dumps({'choices': [], 'usage': usage})}\n".encode(),
                b"data: [DONE]\n",
            ]
        )
        with mock.patch.object(MODULE.urllib.request, "urlopen", return_value=response):
            result = MODULE.run_completion("http://test", "model", [1], 1, 5)
        self.assertEqual(result["usage"], usage)
        self.assertEqual(result["finish_reason"], "length")
        self.assertEqual(result["completion_bytes"], 1)


if __name__ == "__main__":
    unittest.main()
