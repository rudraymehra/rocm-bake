#!/usr/bin/env python3
"""Render buildx history with the node each build is running on.

`docker buildx history ls` prints a BUILD ID but not the node, which
makes a multi-node builder like snoc-pool opaque: five builds listed
under one builder with no way to see they all landed on one machine.
The node is in the record already — refs are "builder/node/id" — so
this re-renders the same data with that column exposed.
"""
import json
import os
import re
import subprocess
import tempfile
import time
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# A build step is a vertex buildkit labels "#7 [builder 2/9]"; a reused
# one then reports "#7 CACHED". Both carry the same vertex number, which
# is what ties a CACHED line back to the step it belongs to.
STEP_RE = re.compile(r"#(\d+) \[[a-z]* ?\d+/\d+\]")
CACHED_RE = re.compile(r"#(\d+) CACHED")


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


def layers(record, builder):
    """Layer-cache hits for this build, as cached/total steps.

    buildkit only fills these counters in when a build finishes, so a
    running one reports "-" rather than 0/0 — which would read as
    "nothing cached" instead of "not known yet".
    """
    total = record.get("total_steps") or 0
    if not total:
        return "-"
    cached = record.get("cached_steps") or 0
    return f"{cached}/{total} ({100 * cached // total}%)"


# The pipeline's own order, so the summary reads top to bottom the way
# the build actually runs rather than alphabetically.
IMAGE_ORDER = ["base", "pytorch", "triton", "runtime", "aiter"]


def image_key(name):
    """Sort key placing a target at its position in the pipeline."""
    for i, stem in enumerate(IMAGE_ORDER):
        if name.startswith(stem):
            return (i, name)
    return (len(IMAGE_ORDER), name)


def records_for(builder):
    """Raw history records for one builder, newest first."""
    try:
        out = subprocess.run(
            ["docker", "buildx", "history", "ls", "--builder", builder,
             "--format", "json"],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except (subprocess.TimeoutExpired, OSError):
        return []
    recs = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            recs.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return recs


def by_image(builders):
    """One row per final image, not per node.

    A node is an implementation detail of where a target happened to be
    scheduled — the balancer moves targets between nodes run to run, so
    a per-node view answers "what did this machine last do" when the
    question is "how much of this image did we have to rebuild". Keyed
    by target, the most recent build of each wins regardless of where
    it ran.
    """
    hours = float(os.environ.get("LAYER_SUMMARY_HOURS", "12"))
    cutoff = (datetime.now(timezone.utc)
              - timedelta(hours=hours)).isoformat().replace("+00:00", "Z")
    latest = {}
    for builder in builders:
        for rec in records_for(builder):
            raw = rec.get("name") or ""
            # The builders are shared. Without this the summary lists
            # vllm-lmcache's images, and every throwaway build anyone
            # ran on the node, as though they were ours.
            if not raw.startswith("rocm-pytorch-build/"):
                continue
            name = raw.replace("rocm-pytorch-build/", "")
            name = name.replace("Dockerfile.", "")
            # The parenthetical is the Dockerfile stage. "final" is the
            # shipped image, so naming it adds nothing — whereas
            # "(wheel)" distinguishes a second image built from the same
            # Dockerfile and is worth keeping.
            name = name.replace(" (final)", "")
            created = rec.get("created_at") or ""
            # buildx keeps records indefinitely, so without a window a
            # build from a superseded configuration sits in a live panel
            # looking current: "pytorch" and "pytorch (final)" are the
            # same image, the first recorded before target="final" was
            # pinned in 680b4cc. 12h because this is a live panel: it should
            # show what the pipeline is doing now, not what it did
            # yesterday under different settings. Override with
            # LAYER_SUMMARY_HOURS.
            if created < cutoff:
                continue
            prev = latest.get(name)
            if prev is None or created > prev[0]:
                node = rec.get("ref", "").split("/")
                latest[name] = (created,
                                node[1] if len(node) >= 3 else builder,
                                rec.get("status", "?"),
                                duration(rec),
                                layers(rec, builder))

    if not latest:
        print(f"  (no builds in the last {hours:g}h)")
        return

    # Images and wheels are different kinds of artefact and read
    # differently: an image ships a usable environment, a wheel is a
    # payload another build consumes. A wheel is any target built from
    # a "wheel" stage, which is now true of all three of them.
    groups = [
        ("images", [n for n in latest if not n.endswith("(wheel)")]),
        ("wheels", [n for n in latest if n.endswith("(wheel)")]),
    ]
    print(f"  \033[2m{'':<22} {'layers':<13} {'node':<14} "
          f"{'status':<10} {'elapsed':>8}\033[0m")
    for title, names in (g for g in groups if g[1]):
        print(f"  \033[2m{title}\033[0m")
        for name in sorted(names, key=image_key):
            _, node, status, dur, lyr = latest[name]
            # The stage is dropped here, not in the record: the group
            # already says wheel, so repeating it in every row is noise.
            show = name.replace(" (wheel)", "")
            print(f"  {show:<22} {lyr:<13} {node:<14} "
                  f"{status.lower():<10} {dur:>8}")


def main():
    if "--by-image" in sys.argv:
        by_image([a for a in sys.argv[1:] if a != "--by-image"])
        return
    args = list(sys.argv[1:])
    builder = args[0]
    limit = int(args[1]) if len(args) > 1 else 5
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
        name = name.replace("Dockerfile.", "")
        rows.append((node, build, name[:24], rec.get("status", "?"),
                     duration(rec), layers(rec, builder)))

    if not rows:
        return
    # Label the columns: without it the layer figure reads as just
    # another cache number next to sccache's, and they measure
    # different things — whole build steps skipped, versus individual
    # compiles served from the compiler cache.
    print(f"  \033[2m{'node':<14} {'build':<13} {'target':<24} "
          f"{'status':<10} {'elapsed':>8}  {'layers':>9}\033[0m")
    for node, build, name, status, dur, lyr in rows[:limit]:
        print(f"  {node:<14} {build:<13} {name:<24} {status:<10} {dur:>8}  {lyr:>9}")


if __name__ == "__main__":
    main()
