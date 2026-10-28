#!/bin/bash
# gpu-test.sh - run the built images on a real GPU and check they work.
#
# Everything else in this repo verifies imports, because a buildkit RUN
# has no /dev/kfd: torch.cuda.is_available() is false inside a build no
# matter how correct the wheel is. That gap is how
# HSA_OVERRIDE_GFX_VERSION=11.0.2 survived in every published image —
# it broke device init on a real gfx1201 and nothing could see it.
#
# Usage:  ./gpu-test.sh [--host <ssh-host>] [--arch gfxNNNN] [--image <ref>]
#                       [--with-triton] [--no-pull]
#
# With --host everything happens there over ssh, which is the normal
# case: the GPU is rarely on the machine driving the build.

set -uo pipefail

HOST=""
IMAGE=""
ARCH="${PYTORCH_ROCM_ARCH:-gfx950}"
# Off by default: the pytorch image ships its own triton (0714318), so
# installing the triton-wheel image on top would hide an image that has
# lost it again. --with-triton tests that wheel instead.
WITH_TRITON=0
PULL=1
REGISTRY="${REGISTRY:-snoc-strix.fold-leaffish.ts.net:8080}"
REGISTRY_NAME="${REGISTRY_NAME:-rocm-pytorch}"
PYTORCH_VERSION="${PYTORCH_VERSION:-2.14.1}"
ROCM_VERSION="${ROCM_VERSION:-10.1.0-full}"

while [ $# -gt 0 ]; do
    case "$1" in
        --host)       HOST="$2"; shift 2 ;;
        --image)      IMAGE="$2"; shift 2 ;;
        --arch)       ARCH="$2"; shift 2 ;;
        --with-triton) WITH_TRITON=1; shift ;;
        --no-triton)  WITH_TRITON=0; shift ;;
        --no-pull)    PULL=0; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Tags use bake's ARCH_TAG: a multi-arch list "gfx942;gfx950" is tagged
# gfx942_gfx950, and ";" is not allowed in a tag.
ARCH_TAG="${ARCH//;/_}"
[ -n "$IMAGE" ] || IMAGE="${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
TRITON_IMAGE="${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${ROCM_VERSION}-${ARCH_TAG}"

PROBE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gpu-probe.py"
[ -f "$PROBE_FILE" ] || { echo "missing $PROBE_FILE" >&2; exit 2; }

echo "=== GPU test ==="
echo "  image:  ${IMAGE}"
echo "  host:   ${HOST:-local}"
echo "  triton: $([ "$WITH_TRITON" = 1 ] && echo "${TRITON_IMAGE##*/}" || echo "the image's own")"
echo

# Everything below runs on the GPU host, built as one script so the ssh
# and local paths are the same code.
#
# The probe travels as a file rather than as a `python -c` argument:
# embedding Python in a command line that then crosses ssh means two
# rounds of quoting, and the first version of this mangled it.
REMOTE=$(cat <<REMOTE_EOF
set -uo pipefail
IMAGE="${IMAGE}"
TRITON_IMAGE="${TRITON_IMAGE}"
ARCH="${ARCH}"
WITH_TRITON="${WITH_TRITON}"
PULL="${PULL}"

work=\$(mktemp -d)
trap 'rm -rf "\$work"' EXIT
cat > "\$work/probe.py" <<'PROBE_EOF'
$(cat "$PROBE_FILE")
PROBE_EOF
chmod 0644 "\$work/probe.py"

# A failed pull must stop the test: otherwise docker run uses whatever
# older image is cached under this tag and the test passes on it.
# --no-pull tests an image that only exists locally.
if [ "\$PULL" = 1 ] && ! docker pull -q "\$IMAGE" >/dev/null; then
    echo "cannot pull \$IMAGE; not testing a cached copy (use --no-pull for a local image)" >&2
    exit 1
fi

# --with-triton: test the separately published triton wheel instead of
# the one in the image. Pulled out with docker cp because that image is
# FROM scratch and has no shell.
install_cmd="true"
if [ "\$WITH_TRITON" = 1 ] && docker pull -q "\$TRITON_IMAGE" >/dev/null 2>&1; then
    cid=\$(docker create "\$TRITON_IMAGE" /bin/true 2>/dev/null)
    if [ -n "\$cid" ]; then
        docker cp "\$cid:/wheels/." "\$work/" >/dev/null 2>&1
        docker rm "\$cid" >/dev/null 2>&1
    fi
    if ls "\$work"/*.whl >/dev/null 2>&1; then
        chmod 0644 "\$work"/*.whl
        install_cmd="pip install --no-cache-dir --no-deps -q /rpb/*.whl"
    fi
fi

# Group IDs, not names: the image has no "render" group, so
# --group-add render fails outright. Numeric ids always resolve.
groups=""
for g in video render; do
    gid=\$(getent group \$g | cut -d: -f3)
    [ -n "\$gid" ] && groups="\$groups --group-add \$gid"
done

# HSA_OVERRIDE_GFX_VERSION is cleared explicitly: images published
# before it was removed still carry it, and it breaks device init by
# masquerading every GPU as gfx1102. A no-op once those are rebuilt.
docker run --rm \\
    --device=/dev/kfd --device=/dev/dri \\
    \$groups \\
    --ulimit memlock=-1 --ipc=host \\
    --security-opt seccomp=unconfined \\
    -e EXPECT_ARCH="\$ARCH" \\
    -e HSA_OVERRIDE_GFX_VERSION= \\
    -v "\$work":/rpb:ro \\
    --entrypoint bash "\$IMAGE" -c "\$install_cmd; python /rpb/probe.py"
REMOTE_EOF
)

if [ -n "$HOST" ]; then
    ssh -o BatchMode=yes "$HOST" "bash -s" <<< "$REMOTE"
else
    bash -c "$REMOTE"
fi
rc=$?

echo
if [ $rc -eq 0 ]; then
    echo "=== GPU test passed ==="
else
    echo "=== GPU test FAILED (exit $rc) ==="
fi
exit $rc
