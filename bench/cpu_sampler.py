#!/usr/bin/env -S uv run --with psutil --quiet -s
"""
CPU and memory sampler. Polls a target PID + all descendants and writes one line
per sample to a file: `<timestamp_ms> <cpu_pct_sum> <rss_bytes_sum>`. Runs until
SIGTERM or PID disappears.

Usage: cpu_sampler.py <pid> <out_file> [interval_s=0.25]

cpu_pct_sum is the sum across the target PID and every transitive child, where
each process's % is measured as 100 * delta(cpu_time) / delta(wall_time) across
the sample interval. A single core fully busy = 100%. N cores fully busy = N*100%.

rss_bytes_sum is the sum of resident set size across the same process tree at the
sample instant. Shared library pages may be counted once per process by the OS
RSS accounting, so this is best interpreted as per-stack process-tree RSS rather
than unique physical memory.
"""

import os
import sys
import time
import psutil


SAMPLE_HEADER = "ts_ms cpu_pct rss_bytes"


def collect_tree(root_pid: int) -> list[psutil.Process]:
    procs: list[psutil.Process] = []
    try:
        root = psutil.Process(root_pid)
    except psutil.NoSuchProcess:
        return procs
    procs.append(root)
    try:
        procs.extend(root.children(recursive=True))
    except psutil.NoSuchProcess:
        pass
    return procs


def cpu_times_total(p: psutil.Process) -> float:
    try:
        t = p.cpu_times()
        return t.user + t.system
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return 0.0


def rss_bytes_total(p: psutil.Process) -> int:
    try:
        return int(p.memory_info().rss)
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return 0


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: cpu_sampler.py <pid> <out_file> [interval_s=0.25]", file=sys.stderr)
        return 2

    pid = int(sys.argv[1])
    out_path = sys.argv[2]
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.25

    # Initial snapshot.
    prev_t = time.monotonic()
    prev_cpu: dict[int, float] = {}
    for p in collect_tree(pid):
        prev_cpu[p.pid] = cpu_times_total(p)

    with open(out_path, "w") as f:
        f.write(f"{SAMPLE_HEADER}\n")
        f.flush()
        while True:
            time.sleep(interval)
            if not psutil.pid_exists(pid):
                return 0
            now = time.monotonic()
            dt = now - prev_t
            prev_t = now

            curr_cpu: dict[int, float] = {}
            rss_bytes = 0
            for p in collect_tree(pid):
                curr_cpu[p.pid] = cpu_times_total(p)
                rss_bytes += rss_bytes_total(p)

            # Sum delta CPU time across union of PIDs.
            delta_sum = 0.0
            for pid_, c in curr_cpu.items():
                prev = prev_cpu.get(pid_, c)
                delta_sum += max(0.0, c - prev)
            prev_cpu = curr_cpu

            pct = (delta_sum / dt) * 100.0 if dt > 0 else 0.0
            f.write(f"{int(now * 1000)} {pct:.2f} {rss_bytes}\n")
            f.flush()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
