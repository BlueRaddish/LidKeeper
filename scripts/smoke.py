#!/usr/bin/env python3
"""Opt-in power-control smoke test. Keep the lid OPEN throughout.

Requires LidKeeper's one-time administrator setup via the app. Never requests sleep.
"""
import selectors
import subprocess
from pathlib import Path

binary = Path(__file__).resolve().parents[1] / "dist/LidKeeper.app/Contents/MacOS/LidKeeper"


def diagnosis():
    return subprocess.check_output([str(binary), "--diagnose"], text=True)


initial = diagnosis()
assert "Lid present: true" in initial, initial
assert "Global sleep disabled: Optional(false)" in initial, initial
assert "Limited administrator rule installed: true" in initial, (
    "Open the app and complete its one-time administrator setup first.\n" + initial
)


def check(mode):
    process = subprocess.Popen(
        [str(binary), "--worker", "2" if mode == "timeout" else "15"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            assert selector.select(timeout=10), "No worker response"
        first = process.stdout.readline().strip()
        assert first == "READY", first
        assert "Global sleep disabled: Optional(true)" in diagnosis()
        if mode == "exclusive":
            other = subprocess.run([str(binary), "--worker", "2"], input="", text=True,
                                   capture_output=True, timeout=5)
            assert other.returncode != 0 and "Another session" in other.stdout, other.stdout
        if mode in ("stop", "exclusive"):
            process.stdin.write("stop\n")
            process.stdin.flush()
        elif mode == "disconnect":
            process.stdin.close()
            process.stdin = None
        elif mode == "signal":
            process.terminate()
        process.wait(timeout=10)
        remainder = process.stdout.read().strip()
        assert process.returncode == 0, remainder
        assert "STOPPED " in remainder, remainder
        assert "Global sleep disabled: Optional(false)" in diagnosis()
        print(f"PASS {mode}: {remainder}")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


for mode in ("stop", "disconnect", "timeout", "signal", "exclusive"):
    check(mode)
