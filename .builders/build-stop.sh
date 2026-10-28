#!/bin/bash
# build-stop.sh - stop builds started from this repo.
#
# Reads PIDs recorded by the things that start builds, rather than
# matching command lines. Two earlier attempts used `pgrep -f` and both
# killed the shell that invoked them: the patterns ("balance.sh",
# "buildx bake") appear verbatim in the command line of whatever ran
# make, and in this recipe's own subshells, so the search matched
# itself. A recorded PID cannot do that.
#
# It also keeps the blast radius right. The builders are shared with a
# sibling project; killing by pattern would stop its builds too.
#
# Killing the client is what cancels the build — buildkitd aborts a
# solve when its client disconnects. There is no `buildx cancel`.

set -uo pipefail

PIDFILE="${BUILD_PIDFILE:-/tmp/.rocm-build.pids}"

# Descendants first, so a parent cannot respawn or orphan them.
kill_tree() {
    local pid="$1" sig="$2" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child" "$sig"
    done
    kill "-$sig" "$pid" 2>/dev/null
}

[ -s "$PIDFILE" ] || { echo "  nothing from this repo is running"; exit 0; }

# A PID alone is not proof: the file accumulates entries across runs,
# and the OS reuses numbers. Killing a recycled PID would hit an
# unrelated process — including, on these shared builders, another
# project's build. Confirm the command line still looks like ours.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
alive=()
while read -r pid; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cmd" in
        *"$REPO"*|*balance.sh*|*telemetry/build.sh*) alive+=("$pid") ;;
        *) echo "  skipping $pid: not one of ours (pid reused)" ;;
    esac
done < "$PIDFILE"

if [ "${#alive[@]}" -eq 0 ]; then
    rm -f "$PIDFILE"
    echo "  nothing from this repo is running"
    exit 0
fi

for pid in "${alive[@]}"; do
    printf '  stopping %-8s %s\n' "$pid" \
        "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-70)"
    kill_tree "$pid" TERM
done

sleep 3

for pid in "${alive[@]}"; do
    kill -0 "$pid" 2>/dev/null || continue
    echo "  force-killing $pid"
    kill_tree "$pid" KILL
done

rm -f "$PIDFILE"
echo "  stopped"
