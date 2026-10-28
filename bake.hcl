# PyTorch ROCm gfx950 Build - Buildx Bake Definition
# Uses the bare-metal Zot registry on Strix for cache storage; build
# nodes are Strix, snoc-thinkstation and snoc-gaming (see the Makefile)
#
# Targets:
#   pytorch-base  - ROCm base with dev tools
#   pytorch       - Full PyTorch build with deps
#   pytorch-run   - Minimal runtime image
#   pytorch-test  - Build + test in one pass
#   all           - All targets (default)
#
# Usage:
#   docker buildx bake -f bake.hcl                     # build all (local)
#   docker buildx bake -f bake.hcl --push              # build + push to Zot
#   docker buildx bake -f bake.hcl pytorch             # build just pytorch
#   docker buildx bake -f bake.hcl --builder snoc-strix pytorch
#   docker buildx bake -f bake.hcl --builder snoc-think pytorch
#
# Override variables at build time:
#   docker buildx bake -f bake.hcl --set 'target.pytorch.args.PYTORCH_VERSION=2.14.1'
#   docker buildx bake -f bake.hcl --set 'target.pytorch.args.ROCM_VERSION=7.14'

# Bare-metal zot on Strix (zot.service, /etc/zot/config.json), plain HTTP
# on the tailnet. Resolving this name inside a build requires the builder
# to have been created with --driver-opt network=host, which the
# Makefile's builder-* targets do.
variable "REGISTRY" {
  default = "snoc-strix.fold-leaffish.ts.net:8080"
}

variable "REGISTRY_NAME" {
  default = "rocm-pytorch"
}

variable "PYTORCH_VERSION" {
  default = "2.14.1"
}

variable "ROCM_VERSION" {
  default = "10.1.0-full"
}

variable "PYTORCH_ROCM_ARCH" {
  default = "gfx950"
}

variable "USE_AITER" {
  default = "ON"
}

variable "USE_FLYDSL" {
  default = "ON"
}

variable "USE_FLASH_ATTENTION" {
  default = "ON"
}

# Ubuntu 26.04 ships only 3.14 — 3.12 and 3.13 are absent from the
# archive, so an older pin cannot be apt-installed on this base.
variable "PYTHON_VERSION" {
  default = "3.14"
}

variable "GIT_REF" {
  default = ""
}

# Short commit of THIS repo, for an immutable tag alongside the moving
# one. Two builds of the same PyTorch version from different repo states
# otherwise produce identical tags and silently overwrite each other.
# The Makefile passes it; empty means "no repo tag", not "unknown".
# PyTorch v2.14.1's own pins: .ci/docker/triton_version.txt (3.8.0) and
# .ci/docker/ci_commit_pins/triton.txt. Building this commit gives the
# triton PyTorch expects, for ROCm 10.1 instead of AMD's newest
# published channel (7.2.0).
variable "TRITON_REF" {
  default = "675c59878aa2280b31f722aaf42b825fcee21de8"
}

# Per-image build timestamps, supplied by the Makefile from the last
# commit that touched each Dockerfile. Empty when bake is driven
# directly; the arg is then omitted and BuildKit falls back to the
# environment, or to wall-clock if that is unset too.
variable "SDE_BASE"    { default = "" }
variable "SDE_PYTORCH" { default = "" }
variable "SDE_TRITON"  { default = "" }
variable "SDE_AITER"   { default = "" }
variable "SDE_RUNTIME" { default = "" }

# Empty means each build derives its own job count from the node it
# lands on, sized by memory rather than cores. Set it to pin one.
variable "MAX_JOBS" {
  default = ""
}

# Compile AITER's kernel modules at build time rather than leaving them
# to JIT on first use. See Dockerfile.aiter for what each level excludes.
variable "PREBUILD_KERNELS" {
  default = "2"
}

# Two-tier layer cache. Reads always consult both the rolling tag and a
# frozen "-ref" baseline; writes go to the rolling tag unless this is
# set to "-ref", which is how the baseline is deliberately refreshed.
# Without it one bad build overwrites the only cache everyone reads.
variable "CACHE_TAG_SUFFIX" {
  default = ""
}

# Stamped into every BuildKit history record name, so records from one
# run can be told apart later. The prefix is this repo's name, not the
# shorter "rpb": the sibling vllm-lmcache project builds on the same
# nodes, uses the same convention, and builds images with the same
# names (pytorch, triton, aiter), so a shared prefix made its builds
# indistinguishable from ours in `make watch`.
#
# Without the run id a cross-run comparison needs the log files, and
# the balancer overwrites /tmp/balance-<target>.log on each run — which
# already cost one measurement.
variable "RUN_ID" {
  default = "dev"
}

variable "AITER_REF" {
  default = "v0.1.27"
}

variable "VCS_REF" {
  default = ""
}

# RFC3339 build time for the OCI created label. Same source.
variable "BUILD_DATE" {
  default = ""
}

variable "SOURCE_URL" {
  default = "https://github.com/sbates130272/rocm-pytorch-build"
}

# gfx950 used to be hardcoded into the tags, so a gfx942 build produced
# an image tagged gfx950. Derive it instead: PYTORCH_ROCM_ARCH is a
# semicolon-separated list, which is not legal in a tag.
ARCH_TAG = replace(PYTORCH_ROCM_ARCH, ";", "_")

# Shared OCI provenance. Without revision and created there is no way to
# work back from a running container to the commit that built it.
#
# Deliberately NOT applied to pytorch-base. Labels live in the image
# config, so a changing revision or created gives the base a new digest
# even when its content is identical — and every downstream FROM then
# invalidates, re-cloning PyTorch's submodule tree and re-running pip on
# every commit. Provenance belongs on the artifacts we ship; the base is
# an intermediate and should stay content-addressed.
OCI_LABELS = {
  "org.opencontainers.image.source"   = SOURCE_URL
  "org.opencontainers.image.revision" = VCS_REF
  "org.opencontainers.image.created"  = BUILD_DATE
}

# What the base gets instead: identity, nothing that varies per build.
BASE_LABELS = {
  "org.opencontainers.image.source" = SOURCE_URL
}

# Provenance attestations record build timestamps, so they differ on
# every build even when the image is byte-identical. Because the
# attestation shares an OCI index with the image manifest, that changes
# the digest a downstream FROM pins, and every layer below it misses.
#
# Measured: two identical base builds produced indexes fd260117 and
# 9c5e5112 wrapped around one unchanged image manifest 91db3c2e. A probe
# RUN missed the cache across those two indexes, while the same digest
# under a different tag hit.
#
# Applied to every image that is a parent or a named context — base,
# pytorch, triton-wheel — and inherited by pytorch-wheel from pytorch.
# pytorch-run and aiter-wheel keep their provenance: nothing builds
# FROM them, so their digests may churn freely.
NO_PROVENANCE = ["type=provenance,disabled=true"]

# Shared compiler cache on Strix (nginx WebDAV, durable on disk).
# The Makefile overrides this with the resolved address: in-container
# DNS for tailnet names proved unreliable under load and silently cost
# most of the cache. See the WEBDAV_IP comment in the Makefile.
variable "SCCACHE_WEBDAV_ENDPOINT" {
  default = "http://snoc-strix.fold-leaffish.ts.net:8081"
}

# Key namespace within that store. Overridable so a benchmark can run
# against an isolated prefix and delete it afterwards without touching
# the fleet's objects.
variable "SCCACHE_WEBDAV_KEY_PREFIX" {
  default = "rocm-pytorch"
}

# sccache's stats report a "Cache errors" count but log nothing about
# them at warn, so a run that wants to know what they are has to ask
# for debug. Not the default: debug logs every lookup, and a cold
# triton does 361 of them.
variable "SCCACHE_LOG" {
  default = "warn"
}

# 0.8.0 is the floor for caching hipcc -x hip; see Dockerfile.pytorch.
variable "SCCACHE_VERSION" {
  default = "0.19.0"
}

# There is deliberately no SCCACHE_SERVER_PORT here. The build
# containers address their sccache server over a unix socket instead,
# because network=host made one fixed port shared fleet-wide; see
# Dockerfile.pytorch. The host-level daemon in deploy-sccache.sh still
# uses a port, which is fine: it is not in a container.

# 1 = refuse to start a PyTorch compile with no sccache server, rather
# than spending an hour rebuilding everything uncached.
variable "FORCE_RECACHE" {
  default = "false"
}

variable "REQUIRE_SCCACHE" {
  default = "1"
}

# ─── Shared build attributes ─────────────────────────────────────
# pytorch-test is deliberately absent. Its stage exits 1 when
# torch.cuda.is_available() is false, and a buildkit RUN step has no
# /dev/kfd — the same reason the build logs "no ROCm-capable device is
# detected". It is a verification step for a finished image on a real
# GPU (`make test` on snoc-strix), not something that can run inside the
# build graph, and including it here made build-all and push-all fail at
# the last target every time.
# pytorch-run is deliberately absent. The runtime image is only worth
# publishing where it can be exercised, and no node currently has a
# usable GPU; building it every run costs time and a Zot push for an
# artifact nobody can test. `make push-runtime` still builds it, and it
# belongs back in this list once a GPU node is available.
group "default" {
  targets = [
    "pytorch-base", "pytorch",
    "pytorch-wheel", "triton-wheel", "aiter-wheel",
  ]
}

# The wheel artifacts. Separate because each builds FROM an image that
# must already be published, so they cannot run from a cold registry.
group "wheels" {
  targets = ["pytorch-wheel", "triton-wheel", "aiter-wheel"]
}

# There was an `attrs = { cache-from/cache-to }` block here pointing at
# a cache:main tag. `attrs` is not a bake keyword, nothing referenced
# it, and bake ignored it silently — Zot has no rocm-pytorch/cache repo
# at all, so it was never written in the lifetime of this file. Each
# target declares its own cache below.

# ─── Base ROCm image with dev toolchain ──────────────────────────
target "pytorch-base" {
  dockerfile = "Dockerfile.base"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}",
    "${REGISTRY}/${REGISTRY_NAME}/base:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}-g${VCS_REF}" : "",
  ])
  labels = merge(BASE_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch base"
    "org.opencontainers.image.description" = "ROCm ${ROCM_VERSION} dev base with Python ${PYTHON_VERSION}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${PYTHON_VERSION}"
  })
  platforms  = ["linux/amd64"]

  # Cache for base layer (apt + common deps)
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/base/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = SDE_BASE != "" ? SDE_BASE : null
    ROCM_VERSION   = ROCM_VERSION
    PYTHON_VERSION = PYTHON_VERSION
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── Full PyTorch build ──────────────────────────────────────────
target "pytorch" {
  inherits = ["pytorch-base"]
  dockerfile = "Dockerfile.pytorch"
  # Explicit: without it buildkit builds the LAST stage in the file, so
  # appending the wheel stage silently made this target publish a
  # scratch image with no shell.
  target     = "final"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/pytorch:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])
  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch"
    "org.opencontainers.image.description" = "PyTorch ${PYTORCH_VERSION} for ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })
  platforms  = ["linux/amd64"]

  # Inherit base cache + pytorch-specific cache
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest-ref,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  # Named context, not a registry ref: bake resolves "target:x" by
  # building x first and feeding its result straight in, so pytorch is
  # buildable in one invocation with its inputs. The same pattern as
  # aiter-wheel below.
  contexts = {
    triton-wheels = "target:triton-wheel"
  }

  args = {
    TRITON_WHEEL_IMAGE  = "triton-wheels"
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/pytorch/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = SDE_PYTORCH != "" ? SDE_PYTORCH : null
    ROCM_VERSION         = ROCM_VERSION
    PYTORCH_VERSION      = PYTORCH_VERSION
    PYTHON_VERSION       = PYTHON_VERSION
    PYTORCH_ROCM_ARCH    = PYTORCH_ROCM_ARCH
    USE_AITER            = USE_AITER
    USE_FLYDSL           = USE_FLYDSL
    USE_FLASH_ATTENTION  = USE_FLASH_ATTENTION
    GIT_REF              = GIT_REF

    # The compiler-cache settings are build ARGs, not env. A bake target
    # has no `env` attribute — the block that used to sit here was parsed
    # as nothing, which is why no build was ever compiler-cached. The
    # CMAKE_*_COMPILER_LAUNCHER values live in Dockerfile.pytorch; only
    # the port and the strictness toggle are worth overriding here.
    SCCACHE_WEBDAV_ENDPOINT = SCCACHE_WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    SCCACHE_LOG          = SCCACHE_LOG
    MAX_JOBS            = MAX_JOBS
    SCCACHE_VERSION      = SCCACHE_VERSION
    FORCE_RECACHE        = FORCE_RECACHE
    REQUIRE_SCCACHE      = REQUIRE_SCCACHE
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── PyTorch wheel artifact ──────────────────────────────────────
# Same idea as the aiter target: the wheel as its own image so it can
# live in Zot and be pulled without rebuilding PyTorch.
target "pytorch-wheel" {
  inherits   = ["pytorch"]
  target     = "wheel"
  dockerfile = "Dockerfile.pytorch"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/pytorch-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/pytorch-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/pytorch-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch wheel"
    "org.opencontainers.image.description" = "torch wheel for ${PYTORCH_ROCM_ARCH}, ROCm ${ROCM_VERSION}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })
}

# ─── Triton wheel ────────────────────────────────────────────────
# Builds FROM the ROCm base, not from pytorch: triton needs cmake<4
# while PyTorch pulls cmake 4.x, so they cannot share an environment.
# That also means it can build in parallel with pytorch on another node.
target "triton-wheel" {
  dockerfile = "Dockerfile.triton"
  platforms  = ["linux/amd64"]
  target     = "wheel"

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/triton-wheel:${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "triton wheel"
    "org.opencontainers.image.description" = "Triton 3.8.0 built for ROCm ${ROCM_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/triton-wheel-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/triton-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = SDE_TRITON != "" ? SDE_TRITON : null
    BASE_IMAGE          = "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}"
    TRITON_REF          = TRITON_REF
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    ROCM_VERSION        = ROCM_VERSION
    SCCACHE_VERSION     = SCCACHE_VERSION
    SCCACHE_WEBDAV_ENDPOINT = SCCACHE_WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
    SCCACHE_LOG         = SCCACHE_LOG
    MAX_JOBS            = MAX_JOBS
  }

  attest = NO_PROVENANCE

  output = ["type=image,compression=zstd"]
}

# ─── AITER wheel ─────────────────────────────────────────────────
# Not part of the default group: it builds FROM the pytorch image, so it
# only makes sense once that has been pushed. Build it explicitly, and
# on whichever node is free — it is independent of the runtime image.
target "aiter-wheel" {
  dockerfile = "Dockerfile.aiter"
  # Pinned, not left to the last stage in the file: appending a stage
  # to Dockerfile.aiter would otherwise silently repoint this target,
  # which is what happened to "pytorch" before 680b4cc.
  target     = "wheel"
  platforms  = ["linux/amd64"]

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/aiter-wheel:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "aiter wheel"
    "org.opencontainers.image.description" = "AITER wheel built against PyTorch ${PYTORCH_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-wheel-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  # Named contexts, not registry refs: bake resolves "target:x" by
  # building x first and feeding its result straight in. That makes
  # aiter-wheel buildable in the same invocation as its inputs, instead
  # of requiring them to be pushed in a previous run.
  contexts = {
    pytorch-img   = "target:pytorch"
    triton-wheels = "target:triton-wheel"
  }

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/aiter-wheel/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = SDE_AITER != "" ? SDE_AITER : null
    PYTORCH_IMAGE       = "pytorch-img"
    TRITON_WHEEL_IMAGE  = "triton-wheels"
    AITER_REF           = AITER_REF
    PREBUILD_KERNELS    = PREBUILD_KERNELS
    MAX_JOBS            = MAX_JOBS
    SCCACHE_VERSION     = SCCACHE_VERSION
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    SCCACHE_WEBDAV_ENDPOINT = SCCACHE_WEBDAV_ENDPOINT
    SCCACHE_WEBDAV_KEY_PREFIX = SCCACHE_WEBDAV_KEY_PREFIX
  }

  output = ["type=image,compression=zstd"]
}

# ─── Minimal runtime image ───────────────────────────────────────
target "pytorch-run" {
  dockerfile = "Dockerfile.runtime"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/runtime:${PYTORCH_VERSION}-${ROCM_VERSION}",
    "${REGISTRY}/${REGISTRY_NAME}/runtime:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/runtime:${PYTORCH_VERSION}-${ROCM_VERSION}-g${VCS_REF}" : "",
  ])
  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch runtime"
    "org.opencontainers.image.description" = "Minimal PyTorch ${PYTORCH_VERSION} runtime for ROCm ${ROCM_VERSION}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}"
  })
  platforms  = ["linux/amd64"]

  # Inherit pytorch build cache
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest-ref,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,registry.insecure=true",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest-ref,mode=max,registry.insecure=true",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest${CACHE_TAG_SUFFIX},mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true,ignore-error=true"]

  args = {
    BUILDKIT_BUILD_NAME = "rocm-pytorch-build/runtime/${PYTORCH_ROCM_ARCH}/${RUN_ID}"
    SOURCE_DATE_EPOCH   = SDE_RUNTIME != "" ? SDE_RUNTIME : null
    PYTHON_VERSION = PYTHON_VERSION
  }

  # "target:pytorch", not a bare registry ref. A context value with no
  # recognised scheme is treated as a local directory, so this used to
  # fail with "stat <registry>/rocm-pytorch/pytorch:...: no such file or
  # directory" — latent until pytorch-run was first built. Referencing
  # the target also removes the need for pytorch to be pushed first, and
  # fixes the hardcoded gfx950 that ignored PYTORCH_ROCM_ARCH.
  contexts = {
    pytorch = "target:pytorch"
  }

  output = ["type=image,compression=zstd"]
}

# ─── Build + Test target ─────────────────────────────────────────
target "pytorch-test" {
  inherits = ["pytorch"]
  tags     = ["${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-test"]

  # run-target is not a bake attribute; target selects the stage.
  target = "test"
}

# ─── Builders ────────────────────────────────────────────────────
# Builders are NOT defined here. `builder` is not a bake HCL block type —
# the blocks that used to sit here were parsed as nothing and silently
# ignored. Builders are created with `docker buildx create`; see the
# builder-* targets in the Makefile, which also pass the buildkitd config
# that teaches each node to reach Zot over plain HTTP.
#
#   make builder-snoc-strix    # snoc-strix: local, gfx950, runs the GPU tests
#   make builder-snoc-think    # snoc-think: snoc-thinkstation over SSH, gfx1201
#   make builder-snoc-gaming   # snoc-gaming: over SSH, gfx1201
#   make builder-snoc-pool     # snoc-pool: all three as one builder
#
# Select one per invocation with --builder:
#   docker buildx bake -f bake.hcl --builder snoc-pool pytorch
