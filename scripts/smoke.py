#!/usr/bin/env python3
"""Opt-in physical-Mac API smoke test. Keep the lid OPEN throughout.

Temporarily suppresses lid sleep. Does not request system sleep. Run after build.
"""
import selectors
import subprocess
from pathlib import Path

binary = Path(__file__).resolve().parents[1] / ".build/release/LidKeeper"


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
        print(f"PASS {mode}: {remainder}")
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


for mode in ("stop", "disconnect", "timeout", "signal", "exclusive"):
    check(mode)
