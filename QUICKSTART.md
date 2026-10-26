# Quick Start — ROCm PyTorch Build Lab

Get a working build environment on SNOC Strix (primary), with
snoc-thinkstation and snoc-gaming as extra build nodes, in under 15
minutes.

## Prerequisites

- All nodes on the same Tailscale network
- Strix: AMD gfx950 GPU, 64 GB RAM, Docker 27+ — runs Zot and the GPU tests
- snoc-thinkstation, snoc-gaming: Docker 27+ and SSH from Strix. Both are
  gfx1201 (RDNA4): they cross-compile for gfx950 but cannot run the test
  stage

Verify Docker is ready:

```bash
docker --version
docker buildx version
```

## Step 1 — Clone the repo

```bash
cd ~/Projects
git clone <your-repo-url> rocm-pytorch-build
cd rocm-pytorch-build
```

## Step 2 — Check Zot (Strix only)

Zot is the local OCI registry that caches images and holds the BuildKit
layer cache. It already runs on Strix as a bare-metal systemd service
(`zot.service`, config in `/etc/zot/config.json`), deployed and owned
outside this repo. **Do not start a second one** — this repo consumes the
existing service and never manages its lifecycle.

```bash
make zot-check
```

Expected: `zot.service: active` and `Zot registry is ready at
snoc-strix.fold-leaffish.ts.net:8080`. To see what it holds:

```bash
make zot-catalog
```

Anonymous read is open; pushing needs the `ci` account from
`/etc/zot/htpasswd`:

```bash
docker login snoc-strix.fold-leaffish.ts.net:8080 -u ci
```

The registry serves plain HTTP over the tailnet, so the Docker daemon
needs it in `/etc/docker/daemon.json` (already set on Strix):

```json
{
  "insecure-registries": ["snoc-strix.fold-leaffish.ts.net:8080"],
  "registry-mirrors": ["http://snoc-strix.fold-leaffish.ts.net:8080"]
}
```

## Step 3 — Create the buildx builder (Strix)

```bash
make builder-strix
```

The builder needs `.builders/buildkitd-strix.toml` to reach the registry
over plain HTTP — `make builder-strix` passes it. Creating the builder by
hand without both flags fails: `--config` for plain HTTP to Zot,
`network=host` so the builder can resolve the tailnet name at all.

```bash
docker buildx create --name strix --driver docker-container \
  --driver-opt network=host \
  --config .builders/buildkitd-strix.toml
docker buildx use strix
```

(Optional) Add the other two nodes. They join over SSH to their Docker
daemons, so nothing needs installing on them — no buildkitd, no TLS
certs, not even the buildx plugin:

```bash
make builder-think     # snoc-thinkstation
make builder-gaming    # snoc-gaming
make builder-pool      # all three as one builder named "pool"
make builder-status    # docker buildx ls
```

Then target the whole fleet:

```bash
make build-all BUILDER=pool
```

The pool fans *targets* out across nodes; it does not split one image
across them. Both remote nodes are gfx1201 (RDNA4), so they can
cross-compile for gfx950 but cannot run the GPU test stage — keep
`make test` on Strix.

## Step 4 — Deploy sccache (both nodes)

sccache speeds up repeated builds by caching compiled object files.

```bash
sudo ./.builders/deploy-sccache.sh strix
```

On the other nodes:

```bash
ssh snoc-thinkstation 'sudo ./.builders/deploy-sccache.sh think'
ssh snoc-gaming       'sudo ./.builders/deploy-sccache.sh gaming'
```

Verify:

```bash
SCCACHE_SERVER_PORT=4226 sccache --show-stats
```

You should see current stats (hits = 0 on first run).

## Step 5 — Build

Build the full pipeline:

```bash
docker buildx bake -f bake.hcl
```

Or individual targets:

```bash
docker buildx bake -f bake.hcl pytorch-base   # ROCm base image only
docker buildx bake -f bake.hcl pytorch          # PyTorch build (takes ~30-60 min)
docker buildx bake -f bake.hcl pytorch-run      # Minimal runtime image
```

Push to Zot:

```bash
docker buildx bake -f bake.hcl --push
```

## Step 6 — Verify the build

```bash
docker run --rm -it --device /dev/kfd --device /dev/dri \
  snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/pytorch:2.14.1-10.1-gfx950
```

Then in the container:

```python
import torch
print(torch.__version__)       # 2.14.1+rocm10.1
print(torch.cuda.is_available())  # True
print(torch.cuda.get_device_name(0))
```

## Custom versions

Change defaults at build time:

```bash
# Use ROCm 7.14 instead of 10.1
docker buildx bake -f bake.hcl \
  --set "target.pytorch.args.ROCM_VERSION=7.14" pytorch

# Build for multiple arches
docker buildx bake -f bake.hcl \
  --set "target.pytorch.args.PYTORCH_ROCM_ARCH='gfx90a;gfx942;gfx950'" pytorch

# Disable optional libraries
docker buildx bake -f bake.hcl \
  --set "target.pytorch.args.USE_AITER=OFF" \
  --set "target.pytorch.args.USE_FLASH_ATTENTION=OFF" pytorch
```

## Clean up

Remove all built images:

```bash
make clean-all
```

## What next?

- See `README.md` for full architecture, telemetry, and troubleshooting
- `.github/workflows/` contains CI, build, and version-check workflows
- `.builders/` has systemd service files for buildkitd and sccache
- Zot is not managed here: `systemctl status zot`, `make zot-logs`
