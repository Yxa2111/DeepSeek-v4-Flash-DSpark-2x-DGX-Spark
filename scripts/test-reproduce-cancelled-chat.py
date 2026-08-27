#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


TARGET = Path(__file__).with_name("reproduce-cancelled-chat.py")


def load_target():
    spec = importlib.util.spec_from_file_location("cancelled_chat", TARGET)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ParseChatSSETest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_target()

    def test_reasoning_content_finish_and_usage(self) -> None:
        raw = (
            b'data: {"choices":[{"delta":{"reasoning":"think "}}]}\n\n'
            b'data: {"choices":[{"delta":{"reasoning_content":"more"}}]}\n\n'
            b'data: {"choices":[{"delta":{"content":"answer"},'
            b'"finish_reason":"stop"}],"usage":{"completion_tokens":3}}\n\n'
            b'data: [DONE]\n\n'
        )
        reasoning, content, finish_reason, usage = self.module.parse_chat_sse(raw)
        self.assertEqual(reasoning, "think more")
        self.assertEqual(content, "answer")
        self.assertEqual(finish_reason, "stop")
        self.assertEqual(usage, {"completion_tokens": 3})

    def test_finite_completion_contract(self) -> None:
        marker = self.module.FINITE_COMPLETION_MARKER
        self.assertTrue(
            self.module.completion_contract_ok(
                "finite-code", "stop", f"answer\n{marker}\n"
            )
        )
        self.assertFalse(
            self.module.completion_contract_ok("finite-code", "length", marker)
        )
        self.assertFalse(
            self.module.completion_contract_ok("finite-code", "stop", "answer")
        )
        self.assertTrue(
            self.module.completion_contract_ok("migration", "length", "")
        )


if __name__ == "__main__":
    unittest.main()
