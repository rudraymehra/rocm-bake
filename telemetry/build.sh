#!/bin/bash
# build.sh - run a bake invocation and record telemetry for it.
#
# Usage: telemetry/build.sh [bake args...]
#        telemetry/build.sh --builder snoc-pool pytorch
#
# Runs `docker buildx bake -f bake.hcl "$@"`, then writes Prometheus
# metrics for every build that invocation produced: wall-clock duration,
# BuildKit layer-cache hit ratio, and sccache compiler-cache counters.
# Exits with the bake's own status, so it is safe to use in place of a
# bare bake call.
#
# Metrics go to $TEXTFILE_DIR (default: node_exporter's textfile
# collector) when that is writable, otherwise to ./telemetry/out. The
# file is written to a temp path and renamed, so node_exporter never
# reads a half-written file. Each builder and target set gets its own
# file, so runs in parallel (balance.sh) or one after another on other
# targets do not replace each other's metrics.
#
# Env:
#   BUILDER       buildx builder to read history from, when the bake args
#                 carry no --builder (default: current)
#   TEXTFILE_DIR  output directory
#   BAKE_FILE     bake definition (default: bake.hcl)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAKE_FILE="${BAKE_FILE:-${REPO_ROOT}/bake.hcl}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
FALLBACK_DIR="${REPO_ROOT}/telemetry/out"

for tool in docker jq; do
    command -v "$tool" > /dev/null || { echo "$0: $tool is required" >&2; exit 1; }
done

# Resolve the builder now: `buildx history` needs a concrete name, and
# the current builder can change under us between build and collection.
# The --builder passed to bake wins: the Makefile passes the node it
# chose there, while BUILDER in the environment can still be the pool
# sentinel (snoc-pool) or unset.
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
        --builder) BUILDER="${args[i + 1]:-}" ;;
        --builder=*) BUILDER="${args[i]#--builder=}" ;;
    esac
done
BUILDER="${BUILDER:-$(docker buildx inspect 2>/dev/null | awk '/^Name:/ {print $2; exit}')}"
[ -n "${BUILDER}" ] || BUILDER=default

# The Makefile passes the bake targets last.
last="${*: -1}"
METRIC_FILE="rocm_pytorch_build_$(printf '%s' "${BUILDER}_${last:-default}" | tr -c 'A-Za-z0-9_-' _).prom"

# Bake writes nothing we can correlate on, so bound the history query by
# time instead. Second resolution is enough: a build takes minutes.
START_EPOCH=$(date +%s)
START_RFC=$(date -u -d "@${START_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)

echo "== bake: $* (builder=${BUILDER})"
docker buildx bake -f "${BAKE_FILE}" "$@"
BUILD_STATUS=$?
END_EPOCH=$(date +%s)
WALL_SECONDS=$((END_EPOCH - START_EPOCH))

echo "== collecting telemetry (bake exit=${BUILD_STATUS}, ${WALL_SECONDS}s)"

SAMPLES="$(mktemp)"
trap 'rm -f "${SAMPLES}"' EXIT

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
BL="builder=\"$(esc "${BUILDER}")\""

# One history record per target built. Anything created before this
# invocation started belongs to an earlier build.
#
# `history ls` prints a qualified ref (builder/node/id) but `history
# inspect` only accepts the bare id, so take the last path component.
# Compare as epochs, not strings: created_at carries sub-second digits,
# and "…:59.578Z" sorts before "…:59Z" lexicographically, so a string
# compare drops any build started in the same second as this script.
REFS=$(docker buildx history ls --builder "${BUILDER}" --format json 2>/dev/null \
    | jq -r --argjson since "${START_EPOCH}" \
        'select((.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)
         | .ref | split("/") | last' 2>/dev/null)

[ -n "${REFS}" ] || echo "   no build records since ${START_RFC} (nothing built, or history unavailable)"

for ref in ${REFS}; do
    rec=$(docker buildx history inspect "${ref}" --builder "${BUILDER}" --format json 2>/dev/null)
    [ -n "${rec}" ] || continue

    name=$(jq -r '.Name // "unknown"' <<< "${rec}")
    # Duration is nanoseconds; keep it as seconds with ms resolution.
    duration=$(jq -r '(.Duration // 0) / 1000000000 | . * 1000 | round / 1000' <<< "${rec}")
    total=$(jq -r '.NumTotalSteps // 0' <<< "${rec}")
    cached=$(jq -r '.NumCachedSteps // 0' <<< "${rec}")
    status=$(jq -r '.Status // "unknown"' <<< "${rec}")

    ratio=0
    [ "${total}" -gt 0 ] && ratio=$(awk -v c="${cached}" -v t="${total}" 'BEGIN{printf "%.4f", c/t}')

    lbl="target=\"$(esc "${name}")\",${BL}"
    {
        echo "rocm_build_duration_seconds{${lbl}} ${duration}"
        echo "rocm_build_steps_total{${lbl}} ${total}"
        echo "rocm_build_steps_cached{${lbl}} ${cached}"
        echo "rocm_build_layer_cache_hit_ratio{${lbl}} ${ratio}"
        echo "rocm_build_target_success{${lbl}} $([ "${status}" = "completed" ] && echo 1 || echo 0)"
    } >> "${SAMPLES}"

    # sccache counters come from the build log: the server lives and dies
    # with the build container, so its stats cannot be queried after the
    # fact. Dockerfile.pytorch prints `sccache --show-stats` as the last
    # thing the build step does.
    # buildx writes the replayed build log to stderr, not stdout.
    #
    # A record contains more than its own target's steps. pytorch pulls
    # triton-wheel in as a named context, so both are solved together
    # and both print a stats block into the pytorch record's log. A
    # bare `tail -1` took whichever block sorted last by step number,
    # which is triton's:
    #
    #   #27 262.2 Cache hits  5674   <- pytorch, the record's own target
    #   #28  95.6 Cache hits   361   <- triton, built as its dependency
    #
    # So every pytorch build was reported with triton's figure. The
    # vertex headers cannot disambiguate here — in a replayed record
    # they are all a bare "[builder 10/11]", with no bake-target prefix.
    #
    # What does identify the step is the file each Dockerfile tees its
    # stats to, which names the image. The step's RUN text is in its
    # header, so finding the marker gives the step number, and the
    # stats lines carrying that number are the ones to read.
    #
    # The legacy fallback matters for a few hours after the rename that
    # made these filenames unique: triton and aiter both used to tee to
    # /wheels-sccache-stats.txt, so records written before it aged out
    # would match no marker and silently drop their sccache numbers
    # from `make watch`. Those old records are genuinely ambiguous and
    # cannot be attributed exactly, but a possibly-imprecise number
    # beats a blank panel until they expire.
    marker=""; legacy=""
    case "${name}" in
        */pytorch/*|*Dockerfile.pytorch*)      marker="/opt/pytorch/sccache-stats.txt" ;;
        */triton-wheel/*|*Dockerfile.triton*)  marker="/wheels-triton-sccache-stats.txt"
                                               legacy="/wheels-sccache-stats.txt" ;;
        */aiter-wheel/*|*Dockerfile.aiter*)    marker="/wheels-aiter-sccache-stats.txt"
                                               legacy="/wheels-sccache-stats.txt" ;;
        *) marker="" ;;
    esac

    logs=$(docker buildx history logs "${ref}" --builder "${BUILDER}" 2>&1)
    if [ -n "${marker}" ]; then
        read -r hits misses < <(
            awk -v marker="${marker}" -v legacy="${legacy}" '
                # Vertex header naming the stats file: this step is ours.
                # "tee <marker>", not the bare path: the final stage
                # COPYs the same file out, so its header mentions the
                # path too and would otherwise overwrite the match with
                # a step that prints no stats at all.
                /^#[0-9]+ \[/ && index($0, "tee " marker) { ours = substr($1, 2) }
                /^#[0-9]+ \[/ && legacy != "" && index($0, "tee " legacy) {
                    if (ours == "") ours = substr($1, 2)
                }
                # Only the plain counters: "#27 262.2 Cache hits 5674"
                # is five fields with a number last. The variants
                # ("Cache hits (C/C++) 3658", "Cache hits rate 89.71 %")
                # have more, and the rate line ends in "%", which is
                # what a bare $NF picked up.
                ours != "" && $1 == "#" ours && NF == 5 && $5 ~ /^[0-9]+$/ {
                    if ($3 == "Cache" && $4 == "hits")   h = $5
                    if ($3 == "Cache" && $4 == "misses") m = $5
                }
                END { print h, m }' <<< "${logs}")
    else
        hits=$(grep -aE 'Cache hits +[0-9]+' <<< "${logs}" | tail -1 | grep -oE '[0-9]+$')
        misses=$(grep -aE 'Cache misses +[0-9]+' <<< "${logs}" | tail -1 | grep -oE '[0-9]+$')
    fi

    if [ -n "${hits:-}" ] && [ -n "${misses:-}" ]; then
        tot=$((hits + misses))
        sratio=0
        [ "${tot}" -gt 0 ] && sratio=$(awk -v h="${hits}" -v t="${tot}" 'BEGIN{printf "%.4f", h/t}')
        {
            echo "rocm_build_sccache_hits{${lbl}} ${hits}"
            echo "rocm_build_sccache_misses{${lbl}} ${misses}"
            echo "rocm_build_sccache_hit_ratio{${lbl}} ${sratio}"
        } >> "${SAMPLES}"
    fi

    echo "   ${name}: ${duration}s, ${cached}/${total} steps cached${hits:+, sccache ${hits} hits/${misses} misses}"
done

# Pick an output directory we can actually write to. Falling back keeps
# the wrapper usable by an unprivileged user; it just means Prometheus
# will not see the metrics.
OUT_DIR="${TEXTFILE_DIR}"
if ! { [ -d "${OUT_DIR}" ] && [ -w "${OUT_DIR}" ]; }; then
    OUT_DIR="${FALLBACK_DIR}"
    mkdir -p "${OUT_DIR}"
    echo "   ${TEXTFILE_DIR} not writable, using ${OUT_DIR}"
fi

TMP_FILE="$(mktemp "${OUT_DIR}/.${METRIC_FILE}.XXXXXX")"
trap 'rm -f "${SAMPLES}" "${TMP_FILE}"' EXIT

emit_help() { # name type help
    grep -q "^$1{" "${SAMPLES}" || return 0
    printf '# HELP %s %s\n# TYPE %s %s\n' "$1" "$3" "$1" "$2"
    grep "^$1{" "${SAMPLES}"
}

{
    echo "# HELP rocm_build_invocation_duration_seconds Wall-clock seconds for the whole bake invocation."
    echo "# TYPE rocm_build_invocation_duration_seconds gauge"
    echo "rocm_build_invocation_duration_seconds{${BL}} ${WALL_SECONDS}"
    echo "# HELP rocm_build_invocation_success 1 if the bake invocation exited 0."
    echo "# TYPE rocm_build_invocation_success gauge"
    echo "rocm_build_invocation_success{${BL}} $([ "${BUILD_STATUS}" -eq 0 ] && echo 1 || echo 0)"
    echo "# HELP rocm_build_last_run_timestamp_seconds Unix time the invocation finished."
    echo "# TYPE rocm_build_last_run_timestamp_seconds gauge"
    echo "rocm_build_last_run_timestamp_seconds{${BL}} ${END_EPOCH}"

    emit_help rocm_build_duration_seconds       gauge "BuildKit-reported duration per target."
    emit_help rocm_build_steps_total            gauge "Build steps in the target."
    emit_help rocm_build_steps_cached           gauge "Build steps served from the layer cache."
    emit_help rocm_build_layer_cache_hit_ratio  gauge "Cached steps over total steps."
    emit_help rocm_build_target_success         gauge "1 if the target completed."
    emit_help rocm_build_sccache_hits           gauge "Compiler-cache hits during the target's build."
    emit_help rocm_build_sccache_misses         gauge "Compiler-cache misses during the target's build."
    emit_help rocm_build_sccache_hit_ratio      gauge "Compiler-cache hits over hits+misses."
} > "${TMP_FILE}"

chmod 644 "${TMP_FILE}"
mv "${TMP_FILE}" "${OUT_DIR}/${METRIC_FILE}"
rm -f "${SAMPLES}"
trap - EXIT
echo "== wrote ${OUT_DIR}/${METRIC_FILE}"

exit "${BUILD_STATUS}"
