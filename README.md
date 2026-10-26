# ROCm PyTorch Build for Strix Halo (gfx950)

Automated build pipeline for PyTorch with ROCm support optimized for AMD Strix Halo (gfx950) GPU.

## Architecture

### High-Level Design

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         SNOC Build Network                                │
│                                                                          │
│  ┌──────────────────────┐   ┌──────────────────┐  ┌─────────────────┐    │
│  │   SNOC Strix         │   │ snoc-thinkstation│  │  snoc-gaming    │    │
│  │   (Primary Build)    │   │  (Build node)    │  │  (Build node)   │    │
│  │                      │   │                  │  │                 │    │
│  │  AMD gfx950 GPU      │   │  gfx1201 (RDNA4) │  │ gfx1201 (RDNA4) │    │
│  │  ~64GB RAM           │   │  Docker 29+      │  │ Docker 29+      │    │
│  │  buildx node (local) │   │  buildx via SSH  │  │ buildx via SSH  │    │
│  │  sccache server      │   │  cross-compile   │  │ cross-compile   │    │
│  │  zot.service         │   │  only, no test   │  │ only, no test   │    │
│  │                      │   │                  │  │                 │    │
│  │  snoc-strix          │   │ snoc-thinkstation│  │  snoc-gaming    │    │
│  └──────────┬───────────┘   └────────┬─────────┘  └────────┬────────┘    │
│             │                        │                     │              │
│             │          Tailscale Mesh (100.x.y.z)          │              │
│             │────────────────────────┴─────────────────────┘              │
│             │                                                             │
│             ▼                                                             │
│  ┌──────────────────────────────────────────────────────────────┐         │
│  │         Zot Registry (bare metal on Strix, zot.service)       │         │
│  │         snoc-strix.fold-leaffish.ts.net:8080                  │         │
│  │                                                              │         │
│  │  • Pull-through sync → Docker Hub, GHCR, Quay                │         │
│  │  • BuildKit layer cache as OCI artifacts                      │         │
│  │  • PyTorch/ROCm image storage                                 │         │
│  │  • sccache cache directory shared via bind mount              │         │
│  └──────────────────────────────────────────────────────────────┘         │
│             │                                                              │
│             │  Prometheus text collector                                   │
│             ▼                                                              │
│  ┌──────────────────────────────────────────────────────────────┐         │
│  │         Telemetry (per-build + periodic)                       │         │
│  │                                                              │         │
│  │  • sccache hit/miss counters                                 │         │
│  │  • Build timing per target (base, pytorch, runtime)           │         │
│  │  • Cache layer hit rates                                    │         │
│  │  • GPU memory usage during build                            │         │
│  └──────────────────────────────────────────────────────────────┘         │
└──────────────────────────────────────────────────────────────────────────┘
```

### Component Data Flow

```
    Build Trigger (Make / bake.hcl)
           │
           ▼
    ┌─────────────────┐
    │  buildx bake     │  ← Declarative target graph
    │  (bake.hcl)      │
    └────────┬────────┘
             │
     ┌───────┼────────┐
     ▼       ▼        ▼
  base    pytorch   runtime
   │         │        │
   │    ┌────┘        │
   │    │             │
   ▼    ▼             ▼
  ROCm   PyTorch     Minimal
  Base    Build      Runtime
  Image    From      Image
           Source
           │
           ▼
     sccache ↔ sccache
     compiler   server
     cache      (port 4226)
           │
           ▼
     Push to Zot
     snoc-strix.fold-leaffish.ts.net:8080
```

### Build Machine Roles

**SNOC Strix (Primary)**
- gfx950 GPU with full ROCm stack
- 64GB shared memory (16GB reserved for host)
- Hosts the Zot registry (bare-metal `zot.service`, managed outside this
  repo) and the sccache server
- Primary build target — builds run here by default
- The only node that can run the GPU test stage

**snoc-thinkstation / snoc-gaming (Build nodes)**

- Joined to buildx over SSH to their Docker daemons: buildx creates and
  owns a buildkit container on each, so neither needs buildkitd, TLS
  certs, or the buildx plugin installed
- Both gfx1201 (RDNA4) — they cross-compile for gfx950 fine, but cannot
  run `make test`
- Reach Zot over the tailnet at `snoc-strix.fold-leaffish.ts.net:8080`
- `make builder-pool` groups all three into one builder named `pool`,
  which fans build *targets* out across nodes (it does not split a single
  image across them)

### Docker Image Lifecycle

```
Dockerfile.base          Dockerfile.pytorch        Dockerfile.runtime
        │                          │                        │
        ▼                          ▼                        ▼
  rocm/dev-ubu:7.14      ← pytorch 2.14.1 ← base image      ← pytorch wheel
  + Python 3.12          + HIP/CUDA src   + sccache client  + runtime deps
  + dev tools            + ROCm tools      + env setup
  + NCCL/MKLDNN          + cmake + build   - build tools
  - ROCm headers         + sccache          only
```

## Components

- **Zot Registry** - Lightweight OCI registry with on-demand sync from Docker Hub, GHCR, and Quay. Runs bare-metal on Strix as `zot.service`; this repo consumes it and never starts, stops, or configures it
- **Buildx Bake** - Declarative multi-stage build definitions with cache management
- **Dockerfiles** - Three stages: base → build → runtime
- **sccache** - Compiler cache server on port 4226 (200GB cache per node)
- **BuildKitd** - BuildKit daemon with ROCm GPU passthrough
- **Telemetry** - Prometheus text collector for build metrics

## Prerequisites

### SNOC Strix (Primary Build Machine)

```bash
# ROCm 7.14+
# Docker 27+ with containerd worker
# Buildx with container driver
# GPU: AMD gfx950 (Strix Halo)
# RAM: 64GB+ shared (reserve 16GB for host)
# Disk: 200GB+ for build cache
```

### snoc-thinkstation / snoc-gaming (Build nodes)

```bash
# Docker 27+ (no buildkitd, no TLS certs, no buildx plugin needed)
# Reachable as `ssh snoc-thinkstation` / `ssh snoc-gaming` from Strix
# Able to reach http://snoc-strix.fold-leaffish.ts.net:8080 over the tailnet
# Disk: 200GB+ for build cache
```

## Quick Start

### 1. Check the Zot Registry

Zot already runs on Strix as a bare-metal systemd service, deployed from
elsewhere. This repo uses it as-is — there is nothing to start here, and
starting a second registry would fight the one the rest of the fleet
pulls through.

```bash
make zot-check     # service active + registry reachable
make zot-catalog   # what it currently holds
make zot-logs      # journalctl -u zot -f
```

Reads are anonymous. Pushes need the `ci` account from
`/etc/zot/htpasswd`:

```bash
docker login snoc-strix.fold-leaffish.ts.net:8080 -u ci
```

It serves plain HTTP on the tailnet, so clients must trust it explicitly.
The Docker daemon reads `/etc/docker/daemon.json`:

```json
{
  "insecure-registries": ["snoc-strix.fold-leaffish.ts.net:8080"],
  "registry-mirrors": ["http://snoc-strix.fold-leaffish.ts.net:8080"]
}
```

BuildKit does not inherit that — it reads
`.builders/buildkitd-strix.toml`, which `make builder-strix` passes via
`--config`.

### 2. Configure Buildx Builders

On **SNOC Strix**:
```bash
# Both flags are required. --config so buildkit talks plain HTTP to Zot;
# network=host so it can resolve the tailnet name in the first place.
docker buildx create --name strix --driver docker-container \
  --driver-opt network=host \
  --config .builders/buildkitd-strix.toml
docker buildx use strix
```

Add the other nodes (they join over SSH; nothing to install on them):

```bash
make builder-think     # snoc-thinkstation
make builder-gaming    # snoc-gaming
make builder-pool      # all three as one builder named "pool"
make builder-status    # docker buildx ls
```

Then build on the whole fleet with `make build-all BUILDER=pool`, or on
one node with `docker buildx bake -f bake.hcl --builder think pytorch`.

### 3. Deploy sccache on All Nodes

```bash
# Deploy to Strix
sudo ./.builders/deploy-sccache.sh strix

# Deploy to the other nodes
ssh snoc-thinkstation 'sudo ./.builders/deploy-sccache.sh think'
ssh snoc-gaming       'sudo ./.builders/deploy-sccache.sh gaming'
```

Verify sccache is running:
```bash
SCCACHE_SERVER_PORT=4226 sccache --show-stats
```

### 4. Build PyTorch

Build all targets:
```bash
docker buildx bake -f bake.hcl
```

Push to Zot registry:
```bash
docker buildx bake -f bake.hcl --push
```

Build only PyTorch (not base/runtime):
```bash
docker buildx bake -f bake.hcl pytorch
```

Use Strix builder specifically:
```bash
docker buildx bake -f bake.hcl --builder strix pytorch
```

### 5. Run Telemetry Collector

```bash
# Collect current metrics
./telemetry/collect.sh > /tmp/build_metrics.prom

# Run periodically (every 5 minutes)
./telemetry/collect.sh --interval 300 &
```

### 6. Test the Build

```bash
# Run the built image with GPU access
docker run --rm -it --device /dev/kfd --device /dev/dri \
  snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/pytorch:2.14.1-7.14-gfx950
```

Expected output:
```
PyTorch 2.14.1+rocm7.14
Devices: 1
GPU: AMD ATI Radeon 780M/790M (gfx950)
```

## Build Pipeline Details

### Target Dependency Graph

```
pytorch-base (no deps)
    │
    ▼
pytorch (depends on pytorch-base)
    │
    ├─ pytorch-test (same as pytorch, runs verification)
    │
    ▼
pytorch-run (depends on pytorch output)
```

### Cache Strategy

1. **BuildKit Layer Cache** → Stored in Zot as OCI artifacts
2. **sccache Compiler Cache** → Per-node local storage (200GB)
3. **Pull-Through Cache** → Zot caches Docker Hub/GHCR/NVCR images on demand
4. **Multi-Builder** → Targets fan out across Strix, Thinkstation and Gaming

### Build Configuration

All targets use these shared attributes:
```
cache-from = registry cache (mode=max, full layers)
cache-to   = registry cache (mode=max, image manifest)
output     = compressed with zstd
platform   = linux/amd64
```

### sccache Integration

The build pipeline injects these environment variables into the Docker build container:

```
SCCACHE_ADDR=localhost:9000
CMAKE_C_COMPILER_LAUNCHER=sccache
CMAKE_CXX_COMPILER_LAUNCHER=sccache
CMAKE_HIP_COMPILER_LAUNCHER=sccache
```

sccache intercepts all compilation calls (gcc, g++, hcc, hipcc) and:
- Caches compiled object files by content hash
- Returns cached objects when source + flags match
- Evicts oldest entries when cache exceeds 200GB

Build completion automatically logs sccache stats to the build log.

## Telemetry & Metrics

### Architecture

The telemetry system collects three categories of metrics:

1. **Build Timing** - Wall-clock and per-step duration for each bake target
2. **sccache Stats** - Hit/miss ratios, cache size, hit rate percentage
3. **BuildKit Metrics** - Layer cache statistics from buildkitd (port 9999)

All metrics are written in Prometheus text exposition format:

```
# HELP build_duration_seconds Total build time for each target
# TYPE build_duration_seconds gauge
build_duration_seconds{target="pytorch"} 3642.5

# HELP sccache_stats Cache statistics
# TYPE sccache_stats gauge
sccache_stats{metric="hits"} 1247
sccache_stats{metric="misses"} 83
sccache_stats{metric="cache_size_bytes"} 1.2e11
```

### Telemetry Collection

The `telemetry/collect.sh` script collects metrics from:

- **sccache server** via `sccache --show-stats`
- **buildkitd** via HTTP on port 9999 (configured in buildkitd.toml)
- **Docker/Buildx** build logs for timing data
- **rocm-smi** for GPU utilization during build

Deploy on any node:
```bash
./telemetry/collect.sh > /tmp/build_metrics.prom
```

Run as a service (optional):
```bash
sudo cp telemetry/collect.service /etc/systemd/system/
sudo systemctl enable --now collect-telemetry
```

### Prometheus Integration

Add a scrape job to your Prometheus config:

```yaml
scrape_configs:
  - job_name: 'build-telemetry'
    static_configs:
      - targets: ['strix:9100', 'think:9100']
    metrics_path: '/metrics'
    scheme: 'http'
```

Or use the textfile collector:
```bash
./telemetry/collect.sh > /etc/prometheus/textfile_build_metrics.prom
```

### Dashboard Metrics

Key metrics for dashboards:
- `build_duration_seconds` — Build time by target
- `sccache_stats{metric="cache_hit_rate"}` — Compiler cache efficiency
- `buildkit_cache_hit_ratio` — Docker layer cache efficiency
- `gpu_memory_used_bytes` — Peak GPU memory during build
- `build_total_success` — Count of successful builds (up/down counter)
- `build_total_duration_seconds` — Build duration histogram

## Configuration

### Environment Variables

Edit `bake.hcl` variables or override at build time:

```bash
# Custom PyTorch version
docker buildx bake -f bake.hcl \
  --set "*.args.PYTORCH_VERSION=2.8.0" pytorch

# Custom ROCm version
docker buildx bake -f bake.hcl \
  --set "*.args.ROCM_VERSION=7.2" pytorch

# Custom registry
docker buildx bake -f bake.hcl \
  --set "*.args.REGISTRY=myregistry.com:5000" \
  --set "*.args.REGISTRY_NAME=rocm-pytorch" pytorch

# Build from specific git ref
docker buildx bake -f bake.hcl \
  --set "*.args.GIT_REF=refs/heads/develop" pytorch
```

### Cache Configuration

Cache is stored in Zot at:

- `snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/base-cache` - Base image cache
- `snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/pytorch-cache` - PyTorch build cache
- `snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/runtime-cache` - Runtime cache

To use cache from another build:
```bash
docker buildx bake -f bake.hcl \
  --set "*.args.CACHE_FROM=other-registry:5000/rocm-pytorch/cache:main" pytorch
```

## Build Targets

| Target | Description | Tags |
|--------|-------------|------|
|| `pytorch-base` | ROCm dev base with Python/toolchain | `rocm-pytorch/base:7.14-3.12` |
|| `pytorch` | Full PyTorch build with deps | `rocm-pytorch/pytorch:2.14.1-7.14-gfx950` |
|| `pytorch-run` | Minimal runtime image | `rocm-pytorch/runtime:2.14.1-7.14` |
|| `pytorch-test` | Build + verify test | `rocm-pytorch/pytorch:2.14.1-7.14-gfx950-test` |
| `default` | All targets | - |
| `multi-build` | Multi-builder group | - |

## Architecture Optimization

### gfx950 Build Flags

Strix Halo uses AMD's new hybrid architecture:
- **Compute**: RDNA 3.5 (graphics) + CDNA 3 (compute)
- **Memory**: 128-bit DDR5 bus, ~64GB shared
- **CU Count**: ~12 CUs

The build targets `gfx950` specifically with fallback compatibility:
```
HIP_ARCHITECTURES="gfx900;gfx940;gfx941;gfx942;gfx950;gfx1100;gfx1101;gfx1102"
```

### Build Optimization Strategy

1. **Layer caching** - Base image built first, cached in Zot
2. **Incremental builds** - Changes to PyTorch source only rebuild affected layers
3. **Registry cache** - Cache stored in Zot, accessible from any builder
4. **Multi-builder** - Fan targets out across Strix, Thinkstation and Gaming
5. **Compression** - Output compressed with zstd for smaller image size
6. **sccache** - Compiler-level caching skips redundant HIP/CUDA compilation
7. **Telemetry** - Real-time metrics for monitoring build health and cache efficiency

## Troubleshooting

### Build fails with "HIP not found"

```bash
# Verify ROCm modules loaded
rocm-smi --showversion

# Check if GPU is visible
ls -la /dev/kfd /dev/dri
```

### Zot connection refused

```bash
# Check the Zot service (bare metal, not a container)
systemctl status zot

# Check Zot logs
sudo journalctl -u zot -n 50

# Verify registry API
curl -s http://snoc-strix.fold-leaffish.ts.net:8080/v2/_catalog
```

Two different failures look similar from a build log:

- `no such host` — the builder cannot resolve the tailnet name. It was
  created without `--driver-opt network=host`, so Docker gave it the
  upstream resolver instead of the host's MagicDNS one.
- `http: server gave HTTP response to HTTPS client` — DNS is fine but the
  client will not speak plain HTTP. For the Docker daemon, check
  `insecure-registries` in `/etc/docker/daemon.json`; for BuildKit,
  confirm the builder was created with
  `--config .builders/buildkitd-strix.toml`.

Both settings are fixed at builder-create time, so the fix is always
`docker buildx rm <name>` then `make builder-<name>`; editing the toml
does nothing to an existing builder. Inspect with
`docker buildx inspect <name>`. If pushes get 401, `docker login
snoc-strix.fold-leaffish.ts.net:8080 -u ci`.

### Buildx builder not available

```bash
# List builders
docker buildx ls

# Create builder if missing
docker buildx create --name strix --driver docker-container
docker buildx use strix
```

### Insufficient disk space

```bash
# Check Docker disk usage
docker system df

# Clean up unused resources
docker system prune -a
```

### sccache not caching

```bash
# Check sccache server is running
sccache --show-stats

# If stats show errors, restart the server
sccache --stop-server
sccache --start-server --cache-size=200G
```

### Telemetry not collecting

```bash
# Check sccache stats collection
./telemetry/collect.sh --test

# Check buildkitd metrics endpoint
curl -s http://localhost:9999/debug/vars

# Check log output
tail -f /var/log/sccache/sccache.log
```

## License

MIT
