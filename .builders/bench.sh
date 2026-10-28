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

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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
# Ask the builder, not the process table. `pgrep -f` matches a pattern
# anywhere in a command line — including the command line of whatever
# invoked this script, and of this function's own subshell — so the
# previous version reported busy against itself. It was also
# fleet-wide: a build on any node blocked a benchmark on an idle one,
# and these builders are shared with another project.
#
# buildx reports what a specific builder is actually solving, which is
# the question that matters: can this node take work now.
busy() {
    local running
    running=$(timeout 30 docker buildx history ls --builder "$BUILDER" \
        --filter status=running --format '{{.Name}}' 2>/dev/null | head -1)
    [ -n "$running" ]
}

# MemAvailable on the node that will run the build, in whole GB.
# Same local-or-ssh split as the load sampling below: snoc-strix is
# this host, everything else is remote.
node_mem_avail_gb() {
    if [ "${BUILDER}" = "snoc-strix" ]; then
        awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo
    else
        timeout 10 ssh -n -o BatchMode=yes \
            "${BUILDER/snoc-think/snoc-thinkstation}" \
            "awk '/^MemAvailable:/ {printf \"%d\", \$2/1048576}' /proc/meminfo" \
            2>/dev/null
    fi
}

# ── one build ────────────────────────────────────────────────────
# Emits a JSON line. Never aborts the harness: a failing build is a
# result, and recording it is the point.
bench_run() {
    local scenario="$1" target="$2" extra="${3:-}" extra_env=""
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
            #
            # Bumping SOURCE_DATE_EPOCH alone is a no-op here. Each
            # image now receives its own timestamp as a build arg
            # (SDE_BASE, SDE_PYTORCH, ...), computed by the Makefile
            # from the last commit touching its Dockerfile, and a build
            # arg takes precedence over the environment. The env var is
            # only consulted when the arg is absent, which never
            # happens through make — so warm silently measured hot.
            epoch=$((epoch + 60))
            extra_env="SDE_BASE=${epoch} SDE_PYTORCH=${epoch} \
                       SDE_TRITON=${epoch} SDE_AITER=${epoch} \
                       SDE_RUNTIME=${epoch}"
            ;;
        hot) ;;
    esac

    log "${scenario}/${target} on ${BUILDER} -> $(basename "${log}")"

    # The builders are shared with other projects — a concurrent vLLM
    # build on snoc-strix skewed the first timings taken here. Record
    # the node's load so a contaminated run is visible in the results
    # rather than quietly wrong.
    local load
    if [ "${BUILDER}" = "snoc-strix" ]; then  # this host
        load=$(cut -d' ' -f1 /proc/loadavg)
    else
        load=$(timeout 10 ssh -n -o BatchMode=yes "${BUILDER/snoc-think/snoc-thinkstation}" \
               "cut -d' ' -f1 /proc/loadavg" 2>/dev/null)
    fi

    # Wait for memory to settle before starting.
    #
    # MAX_JOBS is derived inside the build from MemAvailable, sampled
    # once when the compile step starts and fixed for the whole build.
    # Launching a benchmark straight after another one samples it while
    # buildkit is still flushing the previous build's layers: a cold
    # pytorch started that way derived MAX_JOBS=3 on a 30GB node that
    # reported 18GB free two minutes later, and a cold time at 3 jobs
    # is not comparable to one at 10. Across slots this node has
    # produced 3, 4, 7 and 10 — mostly scheduling artefact, not node.
    #
    # Polling until two consecutive reads agree keeps the derivation
    # (which is the thing being exercised) while removing the artefact.
    local mem prev=0 settled=0
    for _ in $(seq 1 "${MEM_SETTLE_TRIES:-18}"); do
        mem=$(node_mem_avail_gb)
        [ -n "${mem}" ] || break
        if [ "${mem}" -ge "${MIN_MEM_GB:-8}" ] && \
           [ "$(( mem > prev ? mem - prev : prev - mem ))" -le 2 ] && \
           [ "${prev}" != 0 ]; then
            settled=1; break
        fi
        prev="${mem}"
        sleep 10
    done
    if [ "${settled}" = 1 ]; then
        log "  memory settled at ${mem}GB available"
    else
        log "  memory did not settle (last ${mem:-?}GB); MAX_JOBS may be low"
    fi

    # Settling is necessary but not sufficient, and on its own it does
    # not buy comparability. MAX_JOBS is sampled when the *compile*
    # step starts, by which point the build's own earlier steps —
    # fetching the base image, the checkout, aotriton — have taken
    # memory of their own: a cold pytorch that settled at 21GB still
    # derived 5, not the 10 the same node gives a hot run whose early
    # steps are all cache hits. The derivation therefore tracks how
    # much work precedes the compile, which differs by scenario, so
    # cold and hot are measured at different job counts by
    # construction.
    #
    # Set BENCH_MAX_JOBS to pin it when the point is to compare
    # scenarios. Left unset the derivation runs, which is what to use
    # when the point is to exercise the derivation itself.
    local pin_jobs=""
    if [ -n "${BENCH_MAX_JOBS:-}" ]; then
        pin_jobs="--set *.args.MAX_JOBS=${BENCH_MAX_JOBS}"
        log "  MAX_JOBS pinned to ${BENCH_MAX_JOBS}"
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
            ${extra_env} \
            BAKE_EXTRA="--set *.cache-to= ${pin_jobs} ${extra}"
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
    #
    # The vertex name carries a bake-target prefix whenever the build
    # has more than one target, and pytorch now always does — it pulls
    # triton-wheel in as a named context. So buildkit emits
    # "[pytorch builder 4/11]" and "[triton-wheel builder 9/11]" where
    # a single-target build emits a bare "[builder 9/11]". The regex
    # below only allowed the bare form, so a pytorch benchmark counted
    # zero steps out of zero and recorded 0/0.
    #
    # Count only vertices belonging to the target being measured:
    # strip an optional leading "<target> ", then require what remains
    # to be "<stage> n/m". Another target's prefix leaves two words
    # before the numbers and fails to match, which keeps triton's
    # steps out of a pytorch result.
    read -r cached total < <(
        awk -v tgt="${target}" '
            match($0, /^#[0-9]+ \[[^]]*[0-9]+\/[0-9]+\]/) {
                hdr = substr($0, RSTART, RLENGTH)
                sub(/^#[0-9]+ \[/, "", hdr); sub(/\]$/, "", hdr)
                sub("^" tgt " ", "", hdr)
                if (hdr !~ /^[a-z-]* *[0-9]+\/[0-9]+$/) next
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
    # sccache's stats come from the build output, mapped to the target
    # by buildkit's step number.
    #
    # Not from ^Cache hits: the lines carry a buildkit prefix
    # ("#32 178.7 Cache hits  5674"), so that anchor never matched and
    # every run recorded 0 hits.
    #
    # And not from the telemetry summary either, which was the first
    # fix and was wrong. A pytorch build prints two stats blocks, its
    # own and triton's, and telemetry attributes triton's numbers to
    # both images: a run whose pytorch compile reported 5674 hits was
    # summarised as "rocm-pytorch-build/pytorch/...: sccache 361
    # hits/0 misses", which is triton's figure. Trusting it moved the
    # bug rather than fixing it.
    #
    # Buildkit does carry the association, in the step number: the
    # vertex header "#32 [pytorch builder 10/11] RUN ..." ties step 32
    # to pytorch, and every stats line from that step is prefixed
    # "#32 ". Mapping headers to targets and then selecting that
    # target's steps is exact, with no heuristic about ordering or
    # magnitude.
    read -r hits misses reqs < <(
        awk -v tgt="${target}" '
            # Vertex header: remember which target owns this step.
            match($0, /^#[0-9]+ \[[^]]*\]/) {
                hdr = substr($0, RSTART, RLENGTH)
                id = substr($1, 2)
                sub(/^#[0-9]+ \[/, "", hdr); sub(/\]$/, "", hdr)
                # Ours if the header carries this bake target as a
                # prefix, or carries no prefix at all — a single-target
                # build emits a bare "[builder  9/11]". Testing for an
                # absent prefix with "no space in the header" was
                # wrong: that bare form has one, so a cold triton
                # recorded 0/0.
                stripped = hdr
                sub("^" tgt " ", "", stripped)
                owner[id] = (stripped ~ /^[a-z-]* *[0-9]+\/[0-9]+$/) ? 1 : 0
            }
            # Stats line from a step we own. Last block wins.
            /^#[0-9]+ [0-9.]+ (Cache hits|Cache misses|Compile requests) +[0-9]+$/ {
                id = substr($1, 2)
                if (!(id in owner) || !owner[id]) next
                if ($3 == "Compile" && $4 == "requests") r = $NF
                else if ($3 == "Cache" && $4 == "hits")   h = $NF
                else if ($3 == "Cache" && $4 == "misses") m = $NF
            }
            END { print h+0, m+0, (h+0)+(m+0) }' "${log}")
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
