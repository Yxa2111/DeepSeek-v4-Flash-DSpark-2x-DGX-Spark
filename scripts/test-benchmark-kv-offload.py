#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest


PATH = Path(__file__).with_name("benchmark-kv-offload.py")
SPEC = importlib.util.spec_from_file_location("benchmark_kv_offload", PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BenchmarkKVOffloadTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
