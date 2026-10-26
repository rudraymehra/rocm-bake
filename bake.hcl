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
variable "AITER_REF" {
  default = "main"
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
OCI_LABELS = {
  "org.opencontainers.image.source"   = SOURCE_URL
  "org.opencontainers.image.revision" = VCS_REF
  "org.opencontainers.image.created"  = BUILD_DATE
}

# Shared compiler cache on Strix, reachable from every build node. The
# name resolves inside a build only because the buildkitd config sets
# [dns] for the build sandbox; see .builders/buildkitd-strix.toml.
variable "SCCACHE_MEMCACHED" {
  default = "tcp://snoc-strix.fold-leaffish.ts.net:11211"
}

# Port for the sccache server started inside the build container. Must
# not collide with the node's own sccache.service (4226), because
# builders run with --driver-opt network=host.
variable "SCCACHE_SERVER_PORT" {
  default = "4250"
}

# 1 = refuse to start a PyTorch compile with no sccache server, rather
# than spending an hour rebuilding everything uncached.
variable "SCCACHE_RECACHE" {
  default = "false"
}

variable "REQUIRE_SCCACHE" {
  default = "1"
}

# ─── Shared build attributes ─────────────────────────────────────
group "default" {
  targets = ["pytorch-base", "pytorch", "pytorch-run", "pytorch-test"]
}

group "all" {
  targets = ["pytorch-base", "pytorch", "pytorch-run", "pytorch-test"]
}

# Shared cache config for all targets
attrs = {
  "cache-from" = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cache:main,mode=max,registry.insecure=true"],
  "cache-to"   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cache:main,mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true"],
}

# ─── Base ROCm image with dev toolchain ──────────────────────────
target "pytorch-base" {
  dockerfile = "Dockerfile.base"
  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}",
    "${REGISTRY}/${REGISTRY_NAME}/base:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}-g${VCS_REF}" : "",
  ])
  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "rocm-pytorch base"
    "org.opencontainers.image.description" = "ROCm ${ROCM_VERSION} dev base with Python ${PYTHON_VERSION}"
    "org.opencontainers.image.version"     = "${ROCM_VERSION}-${PYTHON_VERSION}"
  })
  platforms  = ["linux/amd64"]

  # Cache for base layer (apt + common deps)
  cache-from = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,registry.insecure=true"]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true"]

  args = {
    ROCM_VERSION   = ROCM_VERSION
    PYTHON_VERSION = PYTHON_VERSION
  }

  output = ["type=image,compression=zstd"]
}

# ─── Full PyTorch build ──────────────────────────────────────────
target "pytorch" {
  inherits = ["pytorch-base"]
  dockerfile = "Dockerfile.pytorch"
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
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,registry.insecure=true",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true"]

  args = {
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
    SCCACHE_MEMCACHED    = SCCACHE_MEMCACHED
    SCCACHE_SERVER_PORT  = SCCACHE_SERVER_PORT
    SCCACHE_RECACHE      = SCCACHE_RECACHE
    REQUIRE_SCCACHE      = REQUIRE_SCCACHE
  }

  output = ["type=image,compression=zstd"]
}

# ─── AITER wheel ─────────────────────────────────────────────────
# Not part of the default group: it builds FROM the pytorch image, so it
# only makes sense once that has been pushed. Build it explicitly, and
# on whichever node is free — it is independent of the runtime image.
target "aiter" {
  dockerfile = "Dockerfile.aiter"
  platforms  = ["linux/amd64"]

  tags = compact([
    "${REGISTRY}/${REGISTRY_NAME}/aiter:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}",
    "${REGISTRY}/${REGISTRY_NAME}/aiter:latest",
    VCS_REF != "" ? "${REGISTRY}/${REGISTRY_NAME}/aiter:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-g${VCS_REF}" : "",
  ])

  labels = merge(OCI_LABELS, {
    "org.opencontainers.image.title"       = "aiter wheel"
    "org.opencontainers.image.description" = "AITER wheel built against PyTorch ${PYTORCH_VERSION}, ${PYTORCH_ROCM_ARCH}"
    "org.opencontainers.image.version"     = "${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
  })

  cache-from = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-cache:latest,mode=max,registry.insecure=true"]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/aiter-cache:latest,mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true"]

  args = {
    PYTORCH_IMAGE       = "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}"
    AITER_REF           = AITER_REF
    PYTORCH_ROCM_ARCH   = PYTORCH_ROCM_ARCH
    SCCACHE_MEMCACHED   = SCCACHE_MEMCACHED
    SCCACHE_SERVER_PORT = SCCACHE_SERVER_PORT
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
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,registry.insecure=true",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest,mode=max,image-manifest=true,oci-mediatypes=true,registry.insecure=true"]

  args = {
    PYTHON_VERSION = PYTHON_VERSION
  }

  contexts = {
    pytorch = "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-gfx950"
  }

  output = ["type=image,compression=zstd"]
}

# ─── Build + Test target ─────────────────────────────────────────
target "pytorch-test" {
  inherits = ["pytorch"]
  tags     = ["${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-${ARCH_TAG}-test"]

  # Run the test stage in Dockerfile.pytorch
  run-target = "test"
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
