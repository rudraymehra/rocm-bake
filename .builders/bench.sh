#!/bin/bash
# bench.sh - measure build time under cold, warm and hot cache conditions.
#
# The three scenarios exist because they fail differently, and only one
# of them is the common case:
#
#   cold  No layer cache, no compiler cache. What a new machine or a
#         changed base image costs. Upper bound.
#   warm  Layer and compiler caches are populated, but SOURCE_DATE_EPOCH
#         moved — which is what every new commit does, including commits
#         that touch nothing this image depends on. This is the case
#         that matters day to day, and the one currently broken: a new
#         commit gives the base a new digest, so every downstream FROM
#         misses even though no input changed.
#   hot   Same commit, everything cached. Lower bound; mostly a check
#         that the caches are being read at all.
#
# Cold runs are isolated by SCCACHE_WEBDAV_KEY_PREFIX so they never
# pollute or evict the fleet's shared compiler cache. The prefix is a
# directory in the WebDAV store and is deleted afterwards. Verified:
# writes land under /var/cache/sccache-webdav/<prefix>/.
#
# Results append as JSON lines, one per build, so a partial run is still
# usable and successive nights accumulate rather than overwrite.
#
# Usage:
#   ./bench.sh <scenario> [target ...]     run one scenario
#   ./bench.sh all                         cold, then warm, then hot
#   ./bench.sh report                      render results as markdown

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# /var/tmp, not /tmp: /tmp is a 16GB tmpfs here and a single base image
# export already filled it once.
BENCH_DIR="${BENCH_DIR:-/var/tmp/rocm-bench}"
RESULTS="${BENCH_DIR}/results.jsonl"
LOGS="${BENCH_DIR}/logs"
mkdir -p "${LOGS}"

BUILDER="${BUILDER:-snoc-think}"
TARGETS_DEFAULT="pytorch-base triton-wheel pytorch"

export no_proxy="${no_proxy:-localhost,127.0.0.1,::1,.ts.net,.local,10.0.0.0/8,100.64.0.0/10}"
export NO_PROXY="${no_proxy}"

log() { printf '[bench %(%H:%M:%S)T] %s\n' -1 "$*"; }

# Refuse to run while a real build is in flight: two builds on one node
# contend for cores and memory, and every timing from this harness would
# be meaningless. Better to skip a slot than record a bad number.
busy() {
    # Exclude our own pid and children; pgrep -f would otherwise match
    # this script's own command line and report busy forever.
    pgrep -f 'balance.sh|telemetry/build.sh|buildx bake' 2>/dev/null \
        | grep -qv "^${$}$"
}

# ── one build ────────────────────────────────────────────────────
# Emits a JSON line. Never aborts the harness: a failing build is a
# result, and recording it is the point.
bench_run() {
    local scenario="$1" target="$2" extra="${3:-}"
    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    local log="${LOGS}/${scenario}-${target}-${stamp}.log"
    local epoch; epoch=$(git log -1 --format=%ct 2>/dev/null)
    local prefix=""

    case "${scenario}" in
        cold)
            prefix="bench-cold-${stamp}"
            extra="${extra} --no-cache"
            ;;
        warm)
            # What a new commit does: same content, later timestamp.
            epoch=$((epoch + 60))
            ;;
        hot) ;;
    esac

    log "${scenario}/${target} on ${BUILDER} -> $(basename "${log}")"

    # The builders are shared with other projects — a concurrent vLLM
    # build on snoc-strix skewed the first timings taken here. Record
    # the node's load so a contaminated run is visible in the results
    # rather than quietly wrong.
    local load
    if [ "${BUILDER}" = "snoc-strix" ]; then
        load=$(cut -d' ' -f1 /proc/loadavg)
    else
        load=$(timeout 10 ssh -n -o BatchMode=yes "${BUILDER/snoc-think/snoc-thinkstation}" \
               "cut -d' ' -f1 /proc/loadavg" 2>/dev/null)
    fi

    local start end rc
    start=$(date +%s)
    (
        export SOURCE_DATE_EPOCH="${epoch}"
        [ -n "${prefix}" ] && export SCCACHE_WEBDAV_KEY_PREFIX="${prefix}"
        # shellcheck disable=SC2086
        # build-, not push-: the docker credential helper on this host
        # fails with "gpg: public key decryption failed" outside an
        # interactive session, so writes to the registry are impossible
        # unattended. cache-to is cleared for the same reason — it is a
        # registry write. Reads (cache-from) are anonymous and still
        # work, so cache *hits* are measured faithfully; what these
        # numbers exclude is push time, which is not what we are timing.
        BUILDKIT_PROGRESS=plain TELEMETRY=1 \
            make "build-$(mk_name "${target}")" BUILDER="${BUILDER}" \
            BAKE_EXTRA="--set *.cache-to= ${extra}"
    ) > "${log}" 2>&1
    rc=$?
    end=$(date +%s)

    # Clean the isolated prefix immediately; a cold run writes the whole
    # compile output and these add up fast.
    if [ -n "${prefix}" ]; then
        sudo rm -rf "/var/cache/sccache-webdav/${prefix}" 2>/dev/null
    fi

    record "${scenario}" "${target}" "$((end - start))" "${rc}" "${log}" "${load:-0}"
}

# bake target -> make target suffix, matching balance.sh's mapping.
mk_name() {
    case "$1" in
        pytorch-base)  echo base ;;
        pytorch)       echo pytorch ;;
        pytorch-run)   echo runtime ;;
        pytorch-wheel) echo torch-wheel ;;
        triton-wheel)  echo triton-wheel ;;
        aiter-wheel)   echo aiter-wheel ;;
        *)             echo "$1" ;;
    esac
}

# Pull the numbers that explain the duration out of the log, so the
# result line stands on its own without re-reading it.
record() {
    local scenario="$1" target="$2" secs="$3" rc="$4" log="$5" load="$6"
    local cached total hits misses reqs maxjobs fail=""

    # Anchor to this repo's Dockerfile. The builders are shared, and
    # telemetry attributes any build running on the node at the time —
    # a run of ours once collected "vllm-lmcache/Dockerfile.nixl" from
    # an unrelated project. A bare tail -1 would record its numbers as
    # ours and silently corrupt the benchmark.
    # Count real build steps, not buildkit vertices. Telemetry's
    # "5/12 steps cached" counts loading the dockerfile, the
    # dockerignore, metadata and exporting among the 12 — none of which
    # can ever be cached, so the ratio reads far worse than reality. A
    # fully-cached base build reports 5/12 while every one of its five
    # actual steps was CACHED. Here a step is a vertex buildkit labels
    # [n/m], and cached means that same vertex reported CACHED.
    read -r cached total < <(
        awk '
            match($0, /^#[0-9]+ \[[a-z]* ?[0-9]+\/[0-9]+\]/) {
                id = substr($1, 2); step[id] = 1
            }
            match($0, /^#[0-9]+ CACHED/) {
                id = substr($1, 2); hit[id] = 1
            }
            END {
                t = 0; c = 0
                for (i in step) { t++; if (i in hit) c++ }
                print c, t
            }' "${log}")
    hits=$(grep -ahE '^Cache hits +[0-9]+' "${log}" | tail -1 | awk '{print $NF}')
    misses=$(grep -ahE '^Cache misses +[0-9]+' "${log}" | tail -1 | awk '{print $NF}')
    reqs=$(grep -ahE '^Compile requests +[0-9]+' "${log}" | tail -1 | awk '{print $NF}')
    maxjobs=$(grep -ahoE 'MAX_JOBS=[0-9]+' "${log}" | tail -1 | cut -d= -f2)

    if [ "${rc}" != 0 ]; then
        # First line that looks like a cause, not the generic wrapper.
        fail=$(grep -ahE 'Killed signal|cannot allocate|Timed out waiting|^ERROR: failed to solve' "${log}" \
               | head -1 | cut -c1-160)
    fi

    # Values go through the environment, not string interpolation: a
    # failure message containing a quote or backslash would otherwise
    # produce invalid Python and lose the whole result line.
    B_SCENARIO="${scenario}" B_TARGET="${target}" B_BUILDER="${BUILDER}" \
    B_SECS="${secs}" B_RC="${rc}" B_CACHED="${cached:-0}" B_TOTAL="${total:-0}" \
    B_REQS="${reqs:-0}" B_HITS="${hits:-0}" B_MISSES="${misses:-0}" \
    B_JOBS="${maxjobs:-0}" B_FAIL="${fail}" B_LOG="${log}" B_LOAD="${load:-0}" \
    python3 -I - <<'PY' >> "${RESULTS}"
import json, os, datetime
def num(k):
    try: return int(os.environ.get(k) or 0)
    except ValueError: return 0
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "scenario": os.environ["B_SCENARIO"],
    "target": os.environ["B_TARGET"],
    "builder": os.environ["B_BUILDER"],
    "seconds": num("B_SECS"),
    "rc": num("B_RC"),
    "steps_cached": num("B_CACHED"),
    "steps_total": num("B_TOTAL"),
    "sccache_requests": num("B_REQS"),
    "sccache_hits": num("B_HITS"),
    "sccache_misses": num("B_MISSES"),
    "max_jobs": num("B_JOBS"),
    "node_load_at_start": float(os.environ.get("B_LOAD") or 0),
    "failure": os.environ.get("B_FAIL") or None,
    "log": os.environ["B_LOG"],
}))
PY
    log "  -> ${secs}s rc=${rc} steps=${cached:-0}/${total:-0} sccache=${hits:-0}/${reqs:-0}"
}

# ── report ───────────────────────────────────────────────────────
render_report() {
    python3 -I - "${RESULTS}" <<'PY'
import json, sys, collections
rows = []
try:
    for line in open(sys.argv[1]):
        line = line.strip()
        if line:
            rows.append(json.loads(line))
except FileNotFoundError:
    print("No results yet."); raise SystemExit

if not rows:
    print("No results yet."); raise SystemExit

print("| scenario | target | time | steps cached | sccache hit | jobs | result |")
print("|---|---|---|---|---|---|---|")
for r in rows:
    secs = r["seconds"]
    t = f"{secs//60}m{secs%60:02d}s" if secs >= 60 else f"{secs}s"
    steps = f'{r["steps_cached"]}/{r["steps_total"]}' if r["steps_total"] else "-"
    req = r["sccache_requests"]
    hit = f'{100*r["sccache_hits"]//req}%' if req else "-"
    res = "ok" if r["rc"] == 0 else "FAIL"
    print(f'| {r["scenario"]} | {r["target"]} | {t} | {steps} | {hit} | '
          f'{r["max_jobs"] or "-"} | {res} |')

print()
best = collections.defaultdict(dict)
for r in rows:
    if r["rc"] == 0:
        best[r["target"]][r["scenario"]] = r["seconds"]
for tgt, s in best.items():
    if "cold" in s and "hot" in s and s["cold"]:
        print(f'{tgt}: hot is {s["cold"]/max(s["hot"],1):.1f}x faster than cold')
PY
}

# ── entry ────────────────────────────────────────────────────────
scenario="${1:-all}"; shift || true
targets="${*:-${TARGETS_DEFAULT}}"

if [ "${scenario}" = "report" ]; then
    render_report
    exit 0
fi

if busy; then
    log "a build is already running; skipping this slot"
    exit 0
fi

case "${scenario}" in
    all)
        for s in cold warm hot; do
            for t in ${targets}; do bench_run "${s}" "${t}"; done
        done
        ;;
    cold|warm|hot)
        for t in ${targets}; do bench_run "${scenario}" "${t}"; done
        ;;
    *)
        echo "usage: bench.sh {cold|warm|hot|all|report} [target ...]" >&2
        exit 2
        ;;
esac

log "done; ./bench.sh report to render"
