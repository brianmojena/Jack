#!/usr/bin/env python3
"""Measure one running Jack process, without including agents or Herdr."""
import json
import subprocess
import time


def ps(*arguments):
    return subprocess.check_output(["/bin/ps", *arguments], text=True).strip()


def cpu_seconds(value):
    days = 0
    if "-" in value:
        prefix, value = value.split("-", 1)
        days = int(prefix)
    parts = [float(part) for part in value.split(":")]
    total = 0.0
    for part in parts:
        total = total * 60 + part
    return days * 86400 + total


rows = ps("-axo", "pid=,comm=").splitlines()
matches = [row.strip().split(None, 1) for row in rows if row.endswith("Jack.app/Contents/MacOS/Jack")]
if len(matches) != 1:
    raise SystemExit("Open exactly one Jack.app before measuring.")
pid, executable = matches[0]
start_cpu, start_rss = ps("-p", pid, "-o", "cputime=,rss=").split()
started = time.monotonic()
time.sleep(15)
end_cpu, end_rss = ps("-p", pid, "-o", "cputime=,rss=").split()
elapsed = time.monotonic() - started
print(json.dumps({
    "pid": int(pid),
    "seconds": round(elapsed, 2),
    "cpu_percent_one_core": round((cpu_seconds(end_cpu) - cpu_seconds(start_cpu)) / elapsed * 100, 2),
    "rss_mebibytes": round(int(end_rss) / 1024, 2),
    "executable": executable,
}, indent=2))
