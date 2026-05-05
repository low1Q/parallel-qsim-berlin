#!/usr/bin/env python3
"""
extract_sim_runtime_from_logs.py

Liest Rust-QSim-Client-Logs ein und extrahiert die Simulationslaufzeit aus Zeilen wie:

2026-04-28T14:45:19.241898Z INFO ... close time.busy=475s time.idle=17.8µs

Zusätzlich werden Metadaten aus Dateinamen wie

sim16_hor0_w4_r24_bin900_batch25000_9181868_client.log

extrahiert.

Beispiel:
    python3 extract_sim_runtime_from_logs.py logs/*client.log > output/analysis/simulation_runtimes_from_logs.csv
"""

from __future__ import annotations

import csv
import re
import sys
from pathlib import Path
from typing import Optional


FILENAME_RE = re.compile(
    r"sim(?P<sim_cpus>\d+)_"
    r"hor(?P<horizon>\d+)_"
    r"w(?P<worker_threads>\d+)_"
    r"r(?P<router_threads>\d+)_"
    r"bin(?P<bin_size>\d+)_"
    r"batch(?P<batch_size>\d+)"
    r"(?:_(?P<job_id>\d+))?"
)

# Beispiele:
#   close time.busy=475s time.idle=17.8µs
#   close time.busy=24.3s time.idle=...
#   close time.busy=1.2ms ...
BUSY_RE = re.compile(r"close\s+time\.busy=(?P<value>[0-9]+(?:\.[0-9]+)?)(?P<unit>ns|µs|us|ms|s|m|h)\b")

# ISO-Zeitstempel am Zeilenanfang, falls man später Start/Ende prüfen möchte
TIMESTAMP_RE = re.compile(r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)")


def to_seconds(value: str, unit: str) -> float:
    x = float(value)
    unit = unit.replace("us", "µs")
    if unit == "ns":
        return x / 1_000_000_000
    if unit == "µs":
        return x / 1_000_000
    if unit == "ms":
        return x / 1_000
    if unit == "s":
        return x
    if unit == "m":
        return x * 60
    if unit == "h":
        return x * 3600
    raise ValueError(f"unknown unit: {unit}")


def parse_filename(path: Path) -> dict[str, Optional[str]]:
    m = FILENAME_RE.search(path.name)
    fields = {
        "sim_cpus": None,
        "horizon": None,
        "worker_threads": None,
        "router_threads": None,
        "bin_size": None,
        "batch_size": None,
        "job_id": None,
    }
    if m:
        fields.update(m.groupdict())
    return fields


def parse_log(path: Path) -> dict[str, object]:
    meta = parse_filename(path)

    runtime_s: Optional[float] = None
    runtime_raw: Optional[str] = None
    runtime_line: Optional[str] = None
    close_timestamp: Optional[str] = None

    completed = False
    sent_ok: Optional[int] = None
    total_events: Optional[int] = None

    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line_stripped = line.rstrip("\n")

                busy_match = BUSY_RE.search(line_stripped)
                if busy_match:
                    runtime_s = to_seconds(busy_match.group("value"), busy_match.group("unit"))
                    runtime_raw = busy_match.group(0)
                    runtime_line = line_stripped
                    ts_match = TIMESTAMP_RE.search(line_stripped)
                    if ts_match:
                        close_timestamp = ts_match.group("ts")

                if "Run completed for configuration" in line_stripped or "make[1]: Leaving directory" in line_stripped:
                    completed = True

                total_match = re.search(r"EventSharingServiceAdapter received total events:\s*(\d+)", line_stripped)
                if total_match:
                    total_events = int(total_match.group(1))

                sent_match = re.search(r"\[event_sharing\]\s+final stats:\s+sent_ok=(\d+)", line_stripped)
                if sent_match:
                    sent_ok = int(sent_match.group(1))

    except OSError as e:
        return {
            "file": str(path),
            **meta,
            "runtime_s": None,
            "rtr": None,
            "runtime_raw": None,
            "close_timestamp": None,
            "completed": False,
            "total_events": None,
            "sent_ok": None,
            "parse_status": f"error: {e}",
            "runtime_line": None,
        }

    rtr = 86400 / runtime_s if runtime_s and runtime_s > 0 else None

    return {
        "file": str(path),
        **meta,
        "runtime_s": runtime_s,
        "rtr": rtr,
        "runtime_raw": runtime_raw,
        "close_timestamp": close_timestamp,
        "completed": completed,
        "total_events": total_events,
        "sent_ok": sent_ok,
        "parse_status": "ok" if runtime_s is not None else "runtime_not_found",
        "runtime_line": runtime_line,
    }


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "Usage: python3 extract_sim_runtime_from_logs.py logs/*client.log > simulation_runtimes_from_logs.csv",
            file=sys.stderr,
        )
        return 2

    paths: list[Path] = []
    for arg in sys.argv[1:]:
        p = Path(arg)
        if p.is_dir():
            paths.extend(sorted(p.glob("*client.log")))
        else:
            paths.append(p)

    fieldnames = [
        "file",
        "sim_cpus",
        "horizon",
        "worker_threads",
        "router_threads",
        "bin_size",
        "batch_size",
        "job_id",
        "runtime_s",
        "rtr",
        "runtime_raw",
        "close_timestamp",
        "completed",
        "total_events",
        "sent_ok",
        "parse_status",
        "runtime_line",
    ]

    writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames)
    writer.writeheader()

    for path in paths:
        row = parse_log(path)
        writer.writerow(row)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
