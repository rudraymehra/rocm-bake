#!/bin/bash
# build-report.sh - Emit build timing and cache telemetry in Prometheus
# text exposition format.
#
# Usage: ./build-report.sh [builder] [--install]
#
#   builder     buildx builder to read history from (default: strix)
#   --install   write atomically into the node_exporter textfile
#               collector instead of stdout (needs sudo)
#
# Two sources, neither of which needs a collector daemon:
#
#   1. `docker buildx history` — BuildKit already records every build's
#      duration and how many steps came from the layer cache. No log
#      parsing, no instrumentation in the Dockerfile.
#   2. `sccache --show-stats` — compiler cache hits/misses from the
#      sccache server on the build node. For an ssh:// builder the
#      server lives on that remote node, so the stats are read there.
#
# Run it after a build:
#   make build-pytorch && ./.builders/build-report.sh strix --install

set -euo pipefail

BUILDER="${1:-strix}"
INSTALL=0
[ "${2:-}" = "--install" ] && INSTALL=1
[ "${1:-}" = "--install" ] && { INSTALL=1; BUILDER="strix"; }

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
OUT_NAME="rocm_pytorch_build.prom"
SCCACHE_PORT="${SCCACHE_SERVER_PORT:-4226}"

if ! docker buildx inspect "${BUILDER}" > /dev/null 2>&1; then
    echo "No such builder: ${BUILDER}" >&2
    exit 1
fi

# An ssh:// builder's sccache server is on the remote node, not here.
# awk must read docker's output to the end. Exiting at the first match
# closes the pipe, docker dies on SIGPIPE with status 255, and pipefail
# plus errexit then kill this script with no message at all.
ENDPOINT=$(docker buildx inspect "${BUILDER}" 2>/dev/null \
    | awk '/^Endpoint:/ && !seen {print $2; seen=1}')
case "${ENDPOINT}" in
    ssh://*) SCCACHE_RUNNER="ssh ${ENDPOINT#ssh://}" ;;
    *)       SCCACHE_RUNNER="" ;;
esac

HISTORY_JSON=$(docker buildx history inspect --builder "${BUILDER}" \
    --format json 2>/dev/null || echo '')
SCCACHE_JSON=$(${SCCACHE_RUNNER} env SCCACHE_SERVER_PORT="${SCCACHE_PORT}" \
    sccache --show-stats --stats-format json 2>/dev/null || echo '')

render() {
    # Heredoc rather than -c: the renderer is full of quotes, and
    # escaping them through a single-quoted shell argument is a trap.
    BUILDER="${BUILDER}" python3 -I - "$1" "$2" <<'PYEOF'
import json, os, sys, time

builder = os.environ["BUILDER"]
history_raw, sccache_raw = sys.argv[1], sys.argv[2]
out = []

def metric(name, help_text, mtype, samples):
    if not samples:
        return
    out.append("# HELP %s %s" % (name, help_text))
    out.append("# TYPE %s %s" % (name, mtype))
    for labels, value in samples:
        out.append("%s{%s} %s" % (name, labels, value) if labels
                   else "%s %s" % (name, value))

# ── Build timing and layer cache, from the BuildKit history API ──
if history_raw.strip():
    h = json.loads(history_raw)
    target = h.get("Name") or "unknown"
    status = h.get("Status") or "unknown"
    lbl = 'builder="%s",target="%s"' % (builder, target)
    # Duration is nanoseconds.
    duration = h.get("Duration")
    if duration is not None:
        metric("rocm_build_duration_seconds",
               "Wall-clock duration of the most recent build",
               "gauge", [(lbl, duration / 1e9)])
    total = h.get("NumTotalSteps")
    cached = h.get("NumCachedSteps")
    if total is not None:
        metric("rocm_build_steps_total", "Build steps in the most recent build",
               "gauge", [(lbl, total)])
    if cached is not None:
        metric("rocm_build_steps_cached", "Build steps served from the layer cache",
               "gauge", [(lbl, cached)])
    if total:
        metric("rocm_build_layer_cache_ratio",
               "Fraction of build steps served from the layer cache",
               "gauge", [(lbl, round(cached / total, 4))])
    metric("rocm_build_success",
           "1 if the most recent build completed, 0 otherwise",
           "gauge", [(lbl, 1 if status.lower() == "completed" else 0)])
    completed = h.get("CompletedAt")
    if completed:
        out.append("# HELP rocm_build_last_timestamp_seconds Unix time of the "
                   "most recent build")
        out.append("# TYPE rocm_build_last_timestamp_seconds gauge")
        out.append("rocm_build_last_timestamp_seconds{%s} %d" % (
            lbl, int(time.mktime(time.strptime(completed[:19],
                                               "%Y-%m-%dT%H:%M:%S")))))

# ── Compiler cache, from the sccache server ──
if sccache_raw.strip():
    s = json.loads(sccache_raw).get("stats", {})
    lbl = 'builder="%s"' % builder

    def total_of(key):
        # hits/misses/errors are {"counts": {"C/C++": n, ...}}
        v = s.get(key)
        if isinstance(v, dict):
            return sum(v.get("counts", {}).values())
        return v or 0

    hits, misses = total_of("cache_hits"), total_of("cache_misses")
    for name, value, help_text in (
        ("rocm_build_sccache_hits", hits, "sccache cache hits"),
        ("rocm_build_sccache_misses", misses, "sccache cache misses"),
        ("rocm_build_sccache_errors", total_of("cache_errors"), "sccache cache errors"),
        ("rocm_build_sccache_compile_requests", s.get("compile_requests", 0),
         "Compile requests seen by sccache"),
        ("rocm_build_sccache_cache_writes", s.get("cache_writes", 0),
         "sccache cache writes"),
        ("rocm_build_sccache_compile_fails", s.get("compile_fails", 0),
         "Compilations that failed under sccache"),
    ):
        metric(name, help_text, "counter", [(lbl, value)])

    if hits + misses:
        metric("rocm_build_sccache_hit_ratio",
               "sccache hit rate over hits+misses", "gauge",
               [(lbl, round(hits / (hits + misses), 4))])
else:
    # Distinguish "no server" from "server with zero hits" — otherwise a
    # silently uncached build looks identical to a cold cache.
    metric("rocm_build_sccache_up",
           "1 if the sccache server answered, 0 if it was unreachable",
           "gauge", [('builder="%s"' % builder, 0)])

print("\n".join(out))
PYEOF
}

REPORT=$(render "${HISTORY_JSON}" "${SCCACHE_JSON}")

if [ -z "${REPORT}" ]; then
    echo "No build history or sccache stats available for ${BUILDER}" >&2
    exit 1
fi

if [ "${INSTALL}" = "1" ]; then
    TMP=$(mktemp)
    printf '%s\n' "${REPORT}" > "${TMP}"
    # The collector reads whole files; write then rename so it never sees
    # a partial one.
    sudo install -d -m 755 "${TEXTFILE_DIR}"
    sudo install -m 644 "${TMP}" "${TEXTFILE_DIR}/${OUT_NAME}"
    rm -f "${TMP}"
    echo "Wrote ${TEXTFILE_DIR}/${OUT_NAME}"
else
    printf '%s\n' "${REPORT}"
fi
