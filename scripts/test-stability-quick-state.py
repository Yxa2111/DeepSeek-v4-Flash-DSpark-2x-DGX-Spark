#!/usr/bin/env python3
"""Regression checks for truthful stability-soak checkpoint state."""

from __future__ import annotations

import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).with_name("stability-quick.py")
spec = importlib.util.spec_from_file_location("stability_quick", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def main() -> None:
    good_rounds = [{"round": 1, "ok": True}, {"round": 2, "ok": True}]

    partial = module.soak_checkpoint(good_rounds, complete=False)
    assert partial == {
        "rounds": good_rounds,
        "rounds_ok": True,
        "complete": False,
        "interrupted": False,
        "ok": False,
    }

    interrupted = module.soak_checkpoint(
        good_rounds,
        complete=False,
        interrupted=True,
        error="stopped",
    )
    assert interrupted["rounds_ok"] is True
    assert interrupted["complete"] is False
    assert interrupted["interrupted"] is True
    assert interrupted["ok"] is False
    assert interrupted["error"] == "stopped"

    complete = module.soak_checkpoint(good_rounds, complete=True)
    assert complete["complete"] is True
    assert complete["ok"] is True

    failed = module.soak_checkpoint(
        good_rounds + [{"round": 3, "ok": False}],
        complete=True,
    )
    assert failed["rounds_ok"] is False
    assert failed["ok"] is False

    empty = module.soak_checkpoint([], complete=True)
    assert empty["rounds_ok"] is False
    assert empty["ok"] is False

    print("test-stability-quick-state: 5 passed")


if __name__ == "__main__":
    main()
