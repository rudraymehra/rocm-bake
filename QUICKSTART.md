# Quick Start — ROCm PyTorch Build Lab

Get a working build environment on SNOC Strix (primary) and SNOC Think (secondary) in under 15 minutes.

## Prerequisites

- Two machines on the same Tailscale network
- Strix: AMD gfx950 GPU, 64 GB RAM, Docker 27+
- Think: any ROCm-capable GPU, Docker 27+

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

## Step 2 — Deploy Zot (Strix only)

Zot is the local OCI registry that caches Docker images.

```bash
cd zot
docker compose up -d
```

Wait ~10 seconds, then verify:

```bash
curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool
```

Expected: `{}` (empty catalog is normal — no images pushed yet).

## Step 3 — Create the buildx builder (Strix)

```bash
docker buildx create --name strix --driver docker-container
docker buildx use strix
```

(Optional) On Think, add a remote builder:

```bash
docker buildx create --name think --driver remote tcp://snoc-think:1234
```

## Step 4 — Deploy sccache (both nodes)

sccache speeds up repeated builds by caching compiled object files.

```bash
sudo ./deploy-sccache.sh strix 0.7.7 200G
```

On Think (if applicable):

```bash
sudo ./deploy-sccache.sh think 0.7.7 200G
```

Verify:

```bash
sccache --show-stats
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
docker run --rm -it --gpus all \
  localhost:5000/rocm-pytorch/pytorch:2.14.1-10.1-gfx950
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
