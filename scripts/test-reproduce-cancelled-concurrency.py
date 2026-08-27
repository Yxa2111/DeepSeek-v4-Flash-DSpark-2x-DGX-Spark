#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


TARGET = Path(__file__).with_name("reproduce-cancelled-concurrency.py")


def load_target():
    spec = importlib.util.spec_from_file_location("cancelled_concurrency", TARGET)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ParseCompletionSSETest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_target()

    def test_text_finish_and_usage(self) -> None:
        raw = (
            b'data: {"choices":[{"text":"alpha","finish_reason":null}]}\n\n'
            b'data: {"choices":[{"text":" beta","finish_reason":"length"}],'
            b'"usage":{"prompt_tokens":8,"completion_tokens":2}}\n\n'
            b'data: [DONE]\n\n'
        )
        text, finish_reason, usage = self.module.parse_completion_sse(raw)
        self.assertEqual(text, "alpha beta")
        self.assertEqual(finish_reason, "length")
        self.assertEqual(usage, {"prompt_tokens": 8, "completion_tokens": 2})

    def test_ignores_non_data_lines(self) -> None:
        text, finish_reason, usage = self.module.parse_completion_sse(
            b": keepalive\n\ndata: [DONE]\n\n"
        )
        self.assertEqual(text, "")
        self.assertIsNone(finish_reason)
        self.assertEqual(usage, {})


if __name__ == "__main__":
    unittest.main()
