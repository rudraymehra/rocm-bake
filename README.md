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
- `make builder-snoc-pool` groups all three into one builder named `pool`,
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
# RAM: 30GB shared with the GPU (reserve headroom for host + display)
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

The step-by-step runbook lives in [QUICKSTART.md](QUICKSTART.md): check
Zot, create the builders, deploy the shared compiler cache, build, and
verify. This file is the reference — architecture, how the caches fit
together, every tunable, and troubleshooting.


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

1. **BuildKit Layer Cache** → Stored in Zot as OCI artifacts, so a layer
   built on one node is reusable from any of them
2. **sccache Compiler Cache** → One shared store on Strix (memcached,
   8GB RAM then spilling to a 200GB file on disk). An object compiled on
   any node is a hit on the others
3. **Pull-Through Cache** → Zot syncs Docker Hub/GHCR/Quay on demand
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

Each build container runs its own sccache server, and all of them share
one store: memcached on Strix, reached over the tailnet.

```
SCCACHE_MEMCACHED=tcp://snoc-strix.fold-leaffish.ts.net:11211
SCCACHE_SERVER_PORT=4250
CMAKE_C_COMPILER_LAUNCHER=sccache
CMAKE_CXX_COMPILER_LAUNCHER=sccache
CMAKE_HIP_COMPILER_LAUNCHER=sccache
```

sccache intercepts compiler invocations (gcc, g++, hipcc), caches object
files by a hash of source plus flags, and returns the cached object when
both match. Deploy the store with `.builders/deploy-memcached.sh`.

Three constraints make this work, and each one fails quietly if broken:

- **A shared server is impossible.** sccache's client sends a *path*,
  and the server reads and hashes the file itself. A server on the host
  cannot see a build container's sources — every compile dies with
  `No such file or directory`. Only the storage layer can be shared.
- **Port 4250, not the default 4226.** Builders run with
  `network=host`, so a client on the default port attaches to the node's
  own `sccache.service` and hits the problem above (exit code 254).
- **The store's hostname needs `[dns]` in the buildkitd config.** RUN
  steps get a resolv.conf pointing at a public resolver, not the node's,
  so a tailnet name is unresolvable from inside a build. The symptom is
  `cache storage failed to read ... I/O error`, which reads like a dead
  store rather than a DNS fault.

`Dockerfile.pytorch` refuses to start a compile when the store is
unreachable, rather than spending an hour rebuilding uncached. Override
with `--set '*.args.REQUIRE_SCCACHE=0'`. The build prints
`sccache --show-stats` as its last action, which is where the telemetry
wrapper reads the counters from.

## Telemetry & Metrics

Every build records its own telemetry. `telemetry/build.sh` wraps a bake
invocation, runs it, then writes Prometheus metrics for each target it
produced — and exits with the bake's own status, so it is a drop-in
replacement for a bare `bake` call. The `make build-*` targets already
route through it; set `TELEMETRY=0` for a bare bake.

```bash
./telemetry/build.sh --builder snoc-pool pytorch
make build-pytorch                  # same thing, via the Makefile
```

Both data sources already exist, so nothing has to be instrumented and
no collector daemon runs:

- **BuildKit's history API** (`docker buildx history inspect`) records
  every build's duration and how many steps came from the layer cache.
- **sccache's own stats**, printed at the end of the build step and
  scraped back out of the build log. They cannot be queried afterwards:
  the sccache server lives and dies with the build container.

### Metrics

| Metric | Meaning |
| --- | --- |
| `rocm_build_duration_seconds` | BuildKit-reported duration, per target |
| `rocm_build_steps_total` / `_cached` | Build steps, and how many were cached |
| `rocm_build_layer_cache_hit_ratio` | Cached steps over total steps |
| `rocm_build_target_success` | 1 if the target completed |
| `rocm_build_sccache_hits` / `_misses` | Compiler-cache counters for that build |
| `rocm_build_sccache_hit_ratio` | Hits over hits+misses |
| `rocm_build_invocation_duration_seconds` | Wall-clock for the whole bake |
| `rocm_build_invocation_success` | 1 if the bake exited 0 |
| `rocm_build_last_run_timestamp_seconds` | When the invocation finished |

All carry a `builder` label; per-target metrics also carry `target`.

### Prometheus integration

Metrics are written to node_exporter's textfile collector when it is
writable, otherwise to `telemetry/out/` (gitignored):

```
/var/lib/node_exporter/textfile_collector/rocm_pytorch_build.prom
```

node_exporter is already running on `:9100` here, so a scrape of that
target picks them up with no extra job. The file is written to a temp
path and renamed, so the collector never reads a partial file. Writing
to the collector directory needs permission on it — otherwise the
wrapper falls back and says so.

To inspect the shared compiler cache itself:

```bash
printf 'stats\r\nquit\r\n' | nc snoc-strix.fold-leaffish.ts.net 11211 \
  | grep -E 'get_hits|get_misses|bytes|extstore_pages_used|evictions'
```

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

# Point at a different compiler-cache store
docker buildx bake -f bake.hcl \
  --set "*.args.SCCACHE_MEMCACHED=tcp://other-host:11211" pytorch

# Build even though the compiler cache is unreachable
docker buildx bake -f bake.hcl \
  --set "*.args.REQUIRE_SCCACHE=0" pytorch
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `REGISTRY` | `snoc-strix.fold-leaffish.ts.net:8080` | Zot registry |
| `SCCACHE_MEMCACHED` | `tcp://snoc-strix…:11211` | Shared compiler-cache store |
| `SCCACHE_SERVER_PORT` | `4250` | In-container sccache port; must not be 4226 |
| `REQUIRE_SCCACHE` | `1` | Fail the build if the store is unreachable |
| `PYTORCH_ROCM_ARCH` | `gfx950` | Semicolon-separated GPU arch list |

`TELEMETRY=0 make build-pytorch` skips the telemetry wrapper.

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
| `pytorch-base` | ROCm dev base with Python/toolchain | `rocm-pytorch/base:10.1.0-full-3.12` |
| `pytorch` | Full PyTorch build with deps | `rocm-pytorch/pytorch:2.14.1-10.1.0-full-gfx950` |
| `pytorch-run` | Minimal runtime image | `rocm-pytorch/runtime:2.14.1-10.1.0-full` |
| `pytorch-test` | Build + verify test | `rocm-pytorch/pytorch:…-gfx950-test` |
| `default` / `all` | Every target | - |

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
`docker buildx rm <name>` then `make builder-<builder>`; editing the toml
does nothing to an existing builder. Inspect with
`docker buildx inspect <name>`. If pushes get 401, `docker login
snoc-strix.fold-leaffish.ts.net:8080 -u ci`.

### Buildx builder not available

```bash
# List builders
docker buildx ls

# Create builder if missing (--config and network=host are both required)
make builder-snoc-strix
```

### Insufficient disk space

```bash
# Check Docker disk usage
docker system df

# Clean up unused resources
docker system prune -a
```

### sccache not caching

The build refuses to start when the store is unreachable, so a silent
no-cache build should not happen. If it does:

```bash
# Is the shared store up and reachable from this node?
printf 'stats\r\nquit\r\n' | nc snoc-strix.fold-leaffish.ts.net 11211 \
  | grep -E 'get_hits|get_misses|evictions|extstore_pages_used'

# Is it filling? bytes_written climbing means objects are landing
systemctl status memcached        # on Strix
```

Three failure modes have distinct signatures:

| Symptom in the build log | Cause |
| --- | --- |
| `No such file or directory` on a source path | The client reached a server outside the container — `SCCACHE_SERVER_PORT` collided with the node's own 4226 daemon |
| `cache storage failed to read ... I/O error` | The store's hostname did not resolve; check `[dns]` in `.builders/buildkitd-strix.toml` |
| `Cache write errors` climbing | The store is full — extstore exhausted, and evictions are disabled by design |

Builder settings are fixed at create time, so after changing the
buildkitd config: `docker buildx rm snoc-strix && make builder-snoc-strix`.

### Telemetry not collecting

```bash
# Run a build through the wrapper directly and watch what it records
./telemetry/build.sh --builder snoc-strix pytorch

# Is there any build history to read?
docker buildx history ls --builder snoc-strix
```

Metrics land in `telemetry/out/` instead of the node_exporter directory
when that directory is not writable — the wrapper says so when it falls
back. sccache counters are absent when a target was fully layer-cached:
the build step never ran, so it printed no stats.

## License

MIT
