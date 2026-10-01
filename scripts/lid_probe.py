#!/usr/bin/env python3
"""Observe a real lid-close session without changing any power settings."""

import argparse
import csv
from datetime import datetime
from pathlib import Path
import re
import subprocess
import time


PROPERTIES = ("AppleClamshellState", "SleepDisabled")
LEASE = Path.home() / "Library/Application Support/LidKeeper/active.lease"
SLEEP_EVENT = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}).*"
    r"Entering Sleep state due to '([^']+)'"
)


def snapshot():
    output = subprocess.check_output(
        ["/usr/sbin/ioreg", "-r", "-n", "IOPMrootDomain", "-d", "1"],
        text=True, timeout=3,
    )
    values = {}
    for name in PROPERTIES:
        match = re.search(r'"' + name + r'" = (Yes|No)', output)
        if not match:
            raise RuntimeError(f"Cannot read {name} from IOPMrootDomain")
        values[name] = match.group(1) == "Yes"
    return values


def sleep_events(start, end):
    output = subprocess.check_output(["/usr/bin/pmset", "-g", "log"], text=True)
    events = []
    for line in output.splitlines():
        match = SLEEP_EVENT.search(line)
        if not match:
            continue
        when = datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S %z")
        if start <= when <= end:
            events.append((when, match.group(2)))
    return events


def lease_age():
    try:
        return max(0, time.time() - LEASE.stat().st_mtime)
    except FileNotFoundError:
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=90, help="number of one-second samples (default: 90)")
    parser.add_argument("--baseline", action="store_true", help="exercise the probe with LidKeeper inactive")
    args = parser.parse_args()
    if not 2 <= args.seconds <= 600:
        parser.error("--seconds must be between 2 and 600")

    try:
        first = snapshot()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        parser.error(str(error))
    if args.baseline:
        if first["SleepDisabled"]:
            parser.error("baseline requires normal sleep (SleepDisabled = No)")
    elif not first["SleepDisabled"]:
        parser.error("start a LidKeeper session first; SleepDisabled is still No")
    else:
        age = lease_age()
        if age is None or age > 6:
            parser.error("no fresh LidKeeper worker lease; start a timed or active trigger session")

    folder = Path.home() / "Library/Logs/LidKeeper"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / ("lid-probe-" + datetime.now().astimezone().strftime("%Y%m%d-%H%M%S") + ".csv")
    samples = []
    start = datetime.now().astimezone()
    print(f"Recording {args.seconds} samples to {path}", flush=True)
    if args.baseline:
        print("Baseline only: leave LidKeeper inactive while the probe checks its own logging.", flush=True)
    else:
        print("Close the lid now, keep it closed for at least 30 seconds, then reopen it.", flush=True)
    try:
        with path.open("x", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(("timestamp", "lid_closed", "sleep_disabled", "lease_age_s", "read_error"))
            for _ in range(args.seconds):
                when = datetime.now().astimezone()
                try:
                    state = snapshot()
                    age = lease_age()
                    row = (when.isoformat(), int(state["AppleClamshellState"]), int(state["SleepDisabled"]),
                           "" if age is None else round(age, 2), "")
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    row = (when.isoformat(), "", "", "", str(error))
                writer.writerow(row)
                handle.flush()
                samples.append(row)
                time.sleep(1)
    except KeyboardInterrupt:
        print("Stopped early; analyzing collected samples.")

    end = datetime.now().astimezone()
    gaps = [
        (datetime.fromisoformat(right[0]) - datetime.fromisoformat(left[0])).total_seconds()
        for left, right in zip(samples, samples[1:])
    ]
    closed = sum(row[1] == 1 for row in samples)
    bad_state = sum(row[2] == 0 for row in samples)
    stale = 0 if args.baseline else sum(row[3] == "" or row[3] > 6 for row in samples)
    errors = sum(bool(row[4]) for row in samples)
    largest_gap = max(gaps, default=0)
    try:
        events = sleep_events(start, end)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"Could not read pmset sleep history: {error}")
        events = []
        errors += 1

    print(f"Closed-lid samples: {closed}; largest heartbeat gap: {largest_gap:.1f}s; sleep-disabled No samples: {bad_state}; stale/missing lease samples: {stale}; read errors: {errors}")
    for when, reason in events:
        print(f"macOS sleep event: {when.isoformat()} — {reason}")
    if args.baseline:
        print("BASELINE ONLY: this run did not test LidKeeper.")
    elif events or bad_state or stale:
        print("FAIL: macOS slept, the override switched off, or the LidKeeper worker stopped renewing its lease.")
    elif closed >= 25 and largest_gap < 3 and not errors:
        print("PASS: the job ran for at least 25 samples with the lid registered closed, with no observed sleep transition.")
    else:
        print("INCONCLUSIVE: no closed-lid sample, a heartbeat gap, or a read error needs investigation.")
    print(f"Raw samples: {path}")


if __name__ == "__main__":
    main()
