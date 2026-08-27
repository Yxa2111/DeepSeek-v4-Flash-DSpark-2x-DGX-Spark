#!/usr/bin/env python3
"""Fail-closed SSE and atomic-checkpoint tests for stability-quick.py."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("stability-quick.py")
spec = importlib.util.spec_from_file_location("stability_quick_stream", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def event(value: dict) -> bytes:
    return f"data: {json.dumps(value)}\n".encode()


class FakeResponse:
    def __init__(self, lines: list[bytes]) -> None:
        self.lines = lines

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def __iter__(self):
        return iter(self.lines)


def completed_lines() -> list[bytes]:
    return [
        event({"choices": [{"delta": {"content": "SOAK_OK"}, "finish_reason": None}]}),
        event(
            {
                "choices": [{"delta": {}, "finish_reason": "stop"}],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": 2,
                    "total_tokens": 12,
                },
            }
        ),
        b"data: [DONE]\n",
    ]


class StreamTests(unittest.TestCase):
    def run_lines(self, lines: list[bytes]) -> dict:
        with mock.patch.object(module.urllib.request, "urlopen", return_value=FakeResponse(lines)):
            return module.chat_stream("http://test/v1", "model", [], timeout=1)

    def test_complete_stream_passes(self) -> None:
        result = self.run_lines(completed_lines())
        self.assertTrue(result["ok"])
        self.assertTrue(result["stream_complete"])
        self.assertEqual(result["finish_reason"], "stop")
        self.assertEqual(result["prompt_tokens"], 10)

    def test_missing_done_fails(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "before SSE"):
            self.run_lines(completed_lines()[:-1])

    def test_missing_choice_fails(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "choice event"):
            self.run_lines(
                [
                    event(
                        {
                            "choices": [],
                            "usage": {
                                "prompt_tokens": 1,
                                "completion_tokens": 0,
                                "total_tokens": 1,
                            },
                        }
                    ),
                    b"data: [DONE]\n",
                ]
            )

    def test_missing_finish_reason_fails(self) -> None:
        lines = completed_lines()
        lines[1] = event(
            {
                "choices": [],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": 2,
                    "total_tokens": 12,
                },
            }
        )
        with self.assertRaisesRegex(RuntimeError, "finish reason"):
            self.run_lines(lines)

    def test_missing_usage_field_fails(self) -> None:
        lines = completed_lines()
        lines[1] = event(
            {
                "choices": [{"delta": {}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 2},
            }
        )
        with self.assertRaisesRegex(RuntimeError, "total_tokens"):
            self.run_lines(lines)

    def test_atomic_checkpoint_is_private_and_replaces(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "nested" / "report.json"
            module.atomic_write_json(target, {"state": 1})
            module.atomic_write_json(target, {"state": 2})
            self.assertEqual(json.loads(target.read_text()), {"state": 2})
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertFalse(any(item.name.endswith(".tmp") for item in target.parent.iterdir()))


if __name__ == "__main__":
    unittest.main()
