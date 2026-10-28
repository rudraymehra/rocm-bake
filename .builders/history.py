#!/usr/bin/env python3
"""Render buildx history with the node each build is running on.

`docker buildx history ls` prints a BUILD ID but not the node, which
makes a multi-node builder like snoc-pool opaque: five builds listed
under one builder with no way to see they all landed on one machine.
The node is in the record already — refs are "builder/node/id" — so
this re-renders the same data with that column exposed.
"""
import json
import subprocess
import sys
from datetime import datetime, timezone


def duration(record):
    """Elapsed time, from the timestamps; ls only reports it in table mode."""
    started = record.get("created_at")
    if not started:
        return "?"
    try:
        begin = datetime.fromisoformat(started.replace("Z", "+00:00"))
    except ValueError:
        return "?"
    ended = record.get("completed_at")
    if ended and record.get("status") != "Running":
        try:
            end = datetime.fromisoformat(ended.replace("Z", "+00:00"))
        except ValueError:
            return "?"
        suffix = ""
    else:
        end = datetime.now(timezone.utc)
        suffix = "+"
    secs = int((end - begin).total_seconds())
    if secs < 60:
        return f"{secs}s{suffix}"
    return f"{secs // 60}m{secs % 60:02d}s{suffix}"


def main():
    builder = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    try:
        out = subprocess.run(
            ["docker", "buildx", "history", "ls", "--builder", builder,
             "--format", "json"],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except subprocess.TimeoutExpired:
        print(f"  (history query timed out for {builder})")
        return

    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        parts = rec.get("ref", "").split("/")
        node = parts[1] if len(parts) >= 3 else "-"
        build = parts[-1][:12]
        name = (rec.get("name") or "-").replace("rocm-pytorch-build/", "")
        rows.append((node, build, name[:34], rec.get("status", "?"), duration(rec)))

    if not rows:
        return
    for node, build, name, status, dur in rows[:limit]:
        print(f"  {node:<14} {build:<13} {name:<34} {status:<10} {dur:>8}")


if __name__ == "__main__":
    main()
