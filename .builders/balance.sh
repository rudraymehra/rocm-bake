#!/bin/bash
# balance.sh - schedule bake targets across the fleet by current load.
#
# Why this exists: buildx's multi-node builder does not balance. Node
# selection is driven by platform matching, and when every node
# advertises linux/amd64 the choice among them ignores capacity — we
# watched all five targets land on snoc-gaming (16 cores, 15GB) while
# snoc-think (32 cores, 122GB) sat idle. There is no hook to change
# that, so the scheduling happens here instead: one bake invocation per
# target, each pinned to a builder we pick.
#
# Consequence: targets must exchange results through the registry
# rather than bake's `target:` contexts, because those only work within
# a single invocation. So every stage pushes, and later stages pull.
#
# Usage: ./balance.sh [--dry-run]
#
# Env:
#   NODES        space-separated builder names (default: the snoc-* set)
#   REGISTRY     passed through to bake
#   MIN_MEM_GB   skip nodes with less free memory than this (default 8)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DRY_RUN=0
BEST_ONLY=0
PUSH=1
STREAM="${BALANCE_STREAM:-0}"
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --best)     BEST_ONLY=1 ;;   # print the strongest node and exit
        --no-push)  PUSH=0 ;;
        --stream)   STREAM=1 ;;  # multiplex target logs to the terminal
    esac
done

NODES="${NODES:-snoc-think snoc-strix snoc-gaming}"
MIN_MEM_GB="${MIN_MEM_GB:-8}"

# Stages run in order; targets within a stage run concurrently on
# different nodes. The dependencies are real: pytorch needs base, and
# aiter needs both pytorch and the triton wheels.
STAGE_1="pytorch-base"
STAGE_2="pytorch triton-wheel"
STAGE_3="pytorch-run pytorch-wheel aiter-wheel"

# ── node capacity ────────────────────────────────────────────────
# score = free GB of RAM + idle cores. Memory is weighted equally with
# cores on purpose: a cold PyTorch build runs one cc1plus per core and
# each takes 1-2GB, so RAM is what actually bounds a big node.
node_score() {
    local builder="$1" endpoint stats cores load freemem idle score
    endpoint=$(timeout 10 docker buildx inspect "$builder" 2>/dev/null \
        | awk '/^Endpoint:/ {print $2; exit}')
    [ -n "$endpoint" ] || { echo "0"; return; }

    case "$endpoint" in
        ssh://*) stats=$(timeout 10 ssh -n -o BatchMode=yes "${endpoint#ssh://}" \
            "nproc; cat /proc/loadavg | cut -d' ' -f1; free -g | awk '/^Mem:/{print \$7}'" 2>/dev/null) ;;
        *)       stats=$(nproc; cut -d' ' -f1 /proc/loadavg; free -g | awk '/^Mem:/{print $7}') ;;
    esac

    cores=$(echo "$stats" | sed -n 1p)
    load=$(echo "$stats" | sed -n 2p)
    freemem=$(echo "$stats" | sed -n 3p)
    [ -n "$cores" ] && [ -n "$freemem" ] || { echo "0"; return; }

    # Nodes too short on memory are excluded outright rather than
    # ranked low: a build that OOMs wastes more than it saves.
    if [ "$freemem" -lt "$MIN_MEM_GB" ]; then echo "0"; return; fi

    idle=$(awk -v c="$cores" -v l="${load:-0}" 'BEGIN{v=c-l; print (v>0)?v:0}')
    score=$(awk -v m="$freemem" -v i="$idle" 'BEGIN{printf "%.0f", m + i}')
    echo "$score"
}

declare -A SCORE

score_all() {
    local n
    for n in $NODES; do
        SCORE[$n]=$(node_score "$n")
    done
}

# Ranked best-first, excluding anything scored 0 (unreachable, or below
# the memory floor). Runs in a subshell via mapfile, hence score_all
# being a separate step in the parent.
rank_nodes() {
    local n
    for n in $NODES; do
        printf '%s %s\n' "${SCORE[$n]:-0}" "$n"
    done | sort -rn | awk '$1 > 0 {print $2}'
}

# bake target -> make target. Spelled out rather than derived: the two
# naming schemes genuinely differ (pytorch-run is push-runtime,
# pytorch-wheel is push-torch-wheel) and a clever substitution gets
# those wrong silently.
make_target() {
    case "$1" in
        pytorch-base)  echo push-base ;;
        pytorch)       echo push-pytorch ;;
        pytorch-run)   echo push-runtime ;;
        pytorch-wheel) echo push-torch-wheel ;;
        triton-wheel)  echo push-triton-wheel ;;
        aiter-wheel)   echo push-aiter-wheel ;;
        *)             echo "push-$1" ;;
    esac
}

# ── run one stage, one target per node, highest score first ──────
run_stage() {
    local stage="$1" ranked=() pids=() tailpids=() rc=0 i=0
    score_all
    mapfile -t ranked < <(rank_nodes)

    if [ "${#ranked[@]}" -eq 0 ]; then
        echo "balance: no node has ${MIN_MEM_GB}GB free; refusing to schedule" >&2
        return 1
    fi

    echo "── stage: $stage"
    for n in "${ranked[@]}"; do printf '     %-14s score=%s\n' "$n" "${SCORE[$n]:-0}"; done

    for target in $stage; do
        local node="${ranked[$((i % ${#ranked[@]}))]}"
        i=$((i + 1))
        echo "   $target -> $node   (log: /tmp/balance-$target.log)"
        [ "$DRY_RUN" = 1 ] && continue
        local mk; mk=$(make_target "$target")
        [ "$PUSH" = 0 ] && mk="${mk/push-/build-}"
        : > "/tmp/balance-$target.log"
        if [ "$STREAM" = 1 ]; then
            BUILDKIT_PROGRESS=plain make "$mk" BUILDER="$node" \
                > "/tmp/balance-$target.log" 2>&1 &
        else
            make "$mk" BUILDER="$node" > "/tmp/balance-$target.log" 2>&1 &
        fi
        pids+=($!)
        # Interleaved buildx progress is unreadable, so each target is
        # prefixed with its name when streaming.
        if [ "$STREAM" = 1 ]; then
            tail -F -n +1 "/tmp/balance-$target.log" 2>/dev/null \
                | sed -u "s/^/$(printf '%-14s' "$target") | /" &
            tailpids+=($!)
        fi
    done

    for p in "${pids[@]:-}"; do
        [ -n "$p" ] || continue
        wait "$p" || rc=1
    done
    for p in "${tailpids[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    # Surface the reason without needing the log file.
    if [ "$rc" != 0 ] && [ "$STREAM" != 1 ]; then
        for target in $stage; do
            grep -qiE '^ERROR|error:' "/tmp/balance-$target.log" 2>/dev/null || continue
            echo "   $target failed:"
            grep -iE '^ERROR|error:' "/tmp/balance-$target.log" \
                | grep -v 'cache importer\|rpc error' | tail -3 | sed 's/^/     /'
        done
    fi
    return $rc
}

# --best: resolve a single node for callers that have one target to
# place, such as the Makefile turning BUILDER=snoc-pool into a concrete
# builder. Falls back to the first configured node so a scoring failure
# degrades to "pick something" rather than breaking the build.
if [ "$BEST_ONLY" = 1 ]; then
    score_all
    best=$(rank_nodes | head -1)
    echo "${best:-${NODES%% *}}"
    exit 0
fi

for stage in "$STAGE_1" "$STAGE_2" "$STAGE_3"; do
    run_stage "$stage" || { echo "balance: stage failed: $stage" >&2; exit 1; }
done

echo "balance: all stages complete"
