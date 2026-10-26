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
#   docker buildx bake -f bake.hcl --builder strix pytorch
#   docker buildx bake -f bake.hcl --builder think pytorch
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

variable "PYTHON_VERSION" {
  default = "3.12"
}

variable "GIT_REF" {
  default = ""
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
  "cache-from" = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cache:main,mode=max"],
  "cache-to"   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/cache:main,mode=max,image-manifest=true,oci-mediatypes=true"],
}

# ─── Base ROCm image with dev toolchain ──────────────────────────
target "pytorch-base" {
  dockerfile = "Dockerfile.base"
  tags       = ["${REGISTRY}/${REGISTRY_NAME}/base:${ROCM_VERSION}-${PYTHON_VERSION}"]
  platforms  = ["linux/amd64"]

  # Cache for base layer (apt + common deps)
  cache-from = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max"]
  cache-to   = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max,image-manifest=true,oci-mediatypes=true"]

  args = {
    ROCM_VERSION   = ROCM_VERSION
    PYTHON_VERSION = PYTHON_VERSION
  }

  output = ["type=image", "compression=zstd"]
}

# ─── Full PyTorch build ──────────────────────────────────────────
target "pytorch" {
  inherits = ["pytorch-base"]
  dockerfile = "Dockerfile.pytorch"
  tags       = ["${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-gfx950"]
  platforms  = ["linux/amd64"]

  # Inherit base cache + pytorch-specific cache
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/base-cache:latest,mode=max",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max,image-manifest=true,oci-mediatypes=true"]

  args = {
    ROCM_VERSION         = ROCM_VERSION
    PYTORCH_VERSION      = PYTORCH_VERSION
    PYTHON_VERSION       = PYTHON_VERSION
    PYTORCH_ROCM_ARCH    = PYTORCH_ROCM_ARCH
    USE_AITER            = USE_AITER
    USE_FLYDSL           = USE_FLYDSL
    USE_FLASH_ATTENTION  = USE_FLASH_ATTENTION
    GIT_REF              = GIT_REF
  }

  env = [
    "SCCACHE_ADDR=localhost:9000",
    "CMAKE_C_COMPILER_LAUNCHER=sccache",
    "CMAKE_CXX_COMPILER_LAUNCHER=sccache",
    "CMAKE_HIP_COMPILER_LAUNCHER=sccache",
  ]

  output = ["type=image", "compression=zstd"]
}

# ─── Minimal runtime image ───────────────────────────────────────
target "pytorch-run" {
  dockerfile = "Dockerfile.runtime"
  tags       = ["${REGISTRY}/${REGISTRY_NAME}/runtime:${PYTORCH_VERSION}-${ROCM_VERSION}"]
  platforms  = ["linux/amd64"]

  # Inherit pytorch build cache
  cache-from = [
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest,mode=max",
    "type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/pytorch-cache:latest,mode=max",
  ]
  cache-to = ["type=registry,ref=${REGISTRY}/${REGISTRY_NAME}/runtime-cache:latest,mode=max,image-manifest=true,oci-mediatypes=true"]

  args = {
    PYTHON_VERSION = PYTHON_VERSION
  }

  contexts = {
    pytorch = "${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-gfx950"
  }

  output = ["type=image", "compression=zstd"]
}

# ─── Build + Test target ─────────────────────────────────────────
target "pytorch-test" {
  inherits = ["pytorch"]
  tags     = ["${REGISTRY}/${REGISTRY_NAME}/pytorch:${PYTORCH_VERSION}-${ROCM_VERSION}-gfx950-test"]

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
#   make builder-strix    # local, gfx950, runs the GPU test stage
#   make builder-think    # snoc-thinkstation over SSH, gfx1201
#   make builder-gaming   # snoc-gaming over SSH, gfx1201
#   make builder-pool     # all three as one builder
#
# Select one per invocation with --builder:
#   docker buildx bake -f bake.hcl --builder pool pytorch
