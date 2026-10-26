# ROCm PyTorch Build for Strix Halo (gfx950)

Automated build pipeline for PyTorch with ROCm support optimized for AMD Strix Halo (gfx950) GPU.

## Architecture

### High-Level Design

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         SNOC Build Network                                │
│                                                                          │
│  ┌──────────────────────┐          ┌──────────────────────┐              │
│  │   SNOC Strix         │          │   SNOC Think          │              │
│  │   (Primary Build)    │          │   (Secondary Build)   │              │
│  │                      │          │                       │              │
│  │  AMD gfx950 GPU      │          │  GPU + Build Worker   │              │
│  │  ~64GB RAM           │          │  ~16GB RAM            │              │
│  │  BuildKitd           │          │  BuildKitd            │              │
│  │  sccache server      │          │  sccache server       │              │
│  │  Docker (container)  │          │  Docker               │              │
│  │                      │          │                       │              │
│  │  ROCm 7.1+           │          │  ROCm 7.1+            │              │
│  └──────────┬───────────┘          └──────────┬───────────┘              │
│             │                                  │                           │
│             │       Tailscale Mesh (10.64.x.x) │                           │
│             │──────────────────────────────────│                           │
│             │                                  │                           │
│             ▼                                  ▼                           │
│  ┌──────────────────────────────────────────────────────────────┐         │
│  │              Zot Registry (on Strix)                          │         │
│  │              localhost:5000                                    │         │
│  │                                                              │         │
│  │  • Pull-through cache → Docker Hub, GHCR, NVCR               │         │
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
     cache      (port 9000)
           │
           ▼
     Push to Zot
     localhost:5000
```

### Build Machine Roles

**SNOC Strix (Primary)**
- gfx950 GPU with full ROCm stack
- 64GB shared memory (16GB reserved for host)
- Runs Zot registry, sccache server, BuildKitd with containerd worker
- Primary build target — builds run here by default

**SNOC Think (Secondary)**
- Backup build node with ROCm support
- Connects via Tailscale mesh network
- Shares sccache cache directory for cross-node compiler caching
- Can run distributed builds via remote BuildKitd endpoint

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

- **Zot Registry** - Lightweight OCI registry with pull-through caching for Docker Hub, GHCR, and NVCR
- **Buildx Bake** - Declarative multi-stage build definitions with cache management
- **Dockerfiles** - Three stages: base → build → runtime
- **sccache** - Compiler cache server on port 9000 (200GB cache per node)
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

### SNOC Think (Secondary Build Machine)

```bash
# BuildKitd exposed on port 1234
# ROCm 7.14+
# Network: snoc-think reachable via Tailscale (10.64.x.x)
# Disk: 200GB+ for build cache
```

## Quick Start

### 1. Deploy Zot Registry

```bash
cd zot
docker compose up -d
```

Verify Zot is running:
```bash
curl -s http://localhost:5000/v2/_catalog
```

### 2. Configure Buildx Builders

On **SNOC Strix**:
```bash
# Create docker-container driver builder
docker buildx create --name strix --driver docker-container
docker buildx use strix
```

On **SNOC Think** (optional, for distributed builds):
```bash
# Ensure buildkitd is running and exposed
# Verify remote builder connectivity
docker buildx create --name think --driver remote tcp://snoc-think:1234
```

### 3. Deploy sccache on Both Nodes

```bash
# Deploy to Strix
sudo ./deploy-sccache.sh strix 0.7.7 200G

# Deploy to Think
sudo ./deploy-sccache.sh think 0.7.7 200G
```

Verify sccache is running:
```bash
sccache --show-stats
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
docker run --rm -it --gpus all \
  localhost:5000/rocm-pytorch/pytorch:2.14.1-7.14-gfx950
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
4. **Multi-Builder** → Builds distribute across Strix and Think

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
- `localhost:5000/rocm-pytorch/base-cache` - Base image cache
- `localhost:5000/rocm-pytorch/pytorch-cache` - PyTorch build cache
- `localhost:5000/rocm-pytorch/runtime-cache` - Runtime cache

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
4. **Multi-builder** - Distribute builds across Strix and Think
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
# Check Zot container status
docker ps | grep zot

# Check Zot logs
docker logs zot-registry

# Verify registry API
curl -s http://localhost:5000/v2/_catalog
```

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
