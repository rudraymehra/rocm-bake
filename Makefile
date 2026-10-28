# Makefile - convenience wrapper for rocm-pytorch builds

# Bare-metal zot on Strix (zot.service, /etc/zot/config.json). The
# MagicDNS name only resolves inside a builder because every builder-*
# target below passes --driver-opt network=host; see the comment in
# .builders/buildkitd-strix.toml.
REGISTRY ?= snoc-strix.fold-leaffish.ts.net:8080
REGISTRY_NAME ?= rocm-pytorch
PYTORCH_VERSION ?= 2.14.1
ROCm_VERSION ?= 10.1.0-full
PYTHON_VERSION ?= 3.12
BUILDER ?= snoc-strix
REPO ?= $(REGISTRY_NAME)/base

# Remote build nodes. SSH endpoints, so these must be reachable as
# `ssh <host>` from here (tailnet names work on the host; only builder
# *containers* lack MagicDNS). Note the builder is named snoc-think but
# the machine is snoc-thinkstation — there is no snoc-think on the
# tailnet, so this variable keeps the real hostname.
THINK_HOST ?= snoc-thinkstation
GAMING_HOST ?= snoc-gaming

# Every build goes through the telemetry wrapper: it runs the bake, then
# records duration, layer-cache hit ratio and sccache counters, and exits
# with the bake's own status. TELEMETRY=0 for a bare bake.
TELEMETRY ?= 1
ifeq ($(TELEMETRY),0)
BAKE = docker buildx bake -f bake.hcl
else
BAKE = ./telemetry/build.sh
endif

.PHONY: help zot-check zot-catalog zot-tags zot-logs \
        builder-setup builder-snoc-strix builder-snoc-think builder-snoc-gaming \
        builder-snoc-pool builder-status builder-ensure \
        build-base build-pytorch build-runtime build-all \
        push-base push-pytorch push-runtime push-all \
        clean clean-cache test \
        validate bake-plan setup

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ─── Zot Registry ────────────────────────────────────────────────
# zot runs as a bare-metal systemd service on Strix, deployed and owned
# outside this repo. These targets inspect it; they never start or stop
# it, because other services on the fleet pull through the same registry.
zot-check: ## Verify the Zot registry is reachable
	@systemctl is-active --quiet zot \
		&& echo "zot.service: active" \
		|| echo "zot.service: NOT active (remote node, or not running here)"
	@curl -sf http://$(REGISTRY)/v2/_catalog > /dev/null \
		&& echo "Zot registry is ready at $(REGISTRY)" \
		|| { echo "Zot registry unreachable at $(REGISTRY)"; exit 1; }

zot-catalog: ## List repositories in the Zot registry
	@curl -sf http://$(REGISTRY)/v2/_catalog | python3 -m json.tool

# curl, not docker: the Docker CLI cannot enumerate tags in a registry.
# `docker search` only queries Docker Hub, and `docker manifest inspect`
# needs a tag you already know. Listing them is a registry API call.
zot-tags: ## List tags for a repo (REPO=rocm-pytorch/base)
	@curl -sf http://$(REGISTRY)/v2/$(REPO)/tags/list 2>/dev/null | python3 -m json.tool 2>/dev/null \
		|| echo "No such repository in $(REGISTRY): $(REPO)"

zot-logs: ## Follow Zot registry logs
	@sudo journalctl -u zot -f

# ─── Buildx Builder Setup ────────────────────────────────────────
builder-setup: builder-snoc-strix builder-snoc-think builder-snoc-gaming ## Setup all builders

builder-snoc-strix: ## Setup the snoc-strix builder (local docker-container)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-strix'; then \
		echo "snoc-strix builder already exists"; \
	else \
		echo "Creating snoc-strix builder..."; \
		docker buildx create \
			--name snoc-strix \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64; \
	fi
	@docker buildx use snoc-strix
	@echo "snoc-strix builder active"

# snoc-thinkstation and snoc-gaming join over SSH to their Docker
# daemons, not the remote/TLS driver: buildx creates and owns a buildkit
# container on each, so neither node needs buildkitd, TLS certs, or the
# buildx plugin installed. Both are gfx1201 (RDNA4), so they can
# cross-compile for gfx950 but cannot run the GPU test stage.
builder-snoc-think: ## Setup the snoc-think builder (over SSH to snoc-thinkstation)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-think'; then \
		echo "snoc-think builder already exists"; \
	else \
		echo "Creating snoc-think builder..."; \
		docker buildx create \
			--name snoc-think \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64 \
			ssh://$(THINK_HOST); \
	fi

builder-snoc-gaming: ## Setup the snoc-gaming builder (over SSH)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-gaming'; then \
		echo "snoc-gaming builder already exists"; \
	else \
		echo "Creating snoc-gaming builder..."; \
		docker buildx create \
			--name snoc-gaming \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64 \
			ssh://$(GAMING_HOST); \
	fi

# One builder with all three nodes. buildx spreads independent targets
# across nodes, so `make build-all BUILDER=snoc-pool` uses the whole fleet.
# A single target still builds on one node — this is fan-out, not a
# distributed compile of one image.
builder-snoc-pool: ## Setup a 3-node pool (snoc-strix + snoc-think + snoc-gaming)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'snoc-pool'; then \
		echo "snoc-pool builder already exists"; \
	else \
		echo "Creating snoc-pool builder..."; \
		docker buildx create --name snoc-pool --node snoc-strix \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64; \
		docker buildx create --name snoc-pool --append --node snoc-think \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64 \
			ssh://$(THINK_HOST); \
		docker buildx create --name snoc-pool --append --node snoc-gaming \
			--driver docker-container \
			--driver-opt network=host \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64 \
			ssh://$(GAMING_HOST); \
	fi
	@docker buildx inspect snoc-pool --bootstrap

builder-status: ## Show all builders and their nodes
	@docker buildx ls

# Build targets depend on this, not on builder-snoc-strix: hardcoding one
# builder as the prerequisite meant `make push-base BUILDER=snoc-think`
# created snoc-strix and made it the default, then built somewhere else.
builder-ensure:
	@docker buildx inspect $(BUILDER) > /dev/null 2>&1 || { \
		echo "Builder '$(BUILDER)' does not exist. Create it with:"; \
		echo "  make builder-$(BUILDER)"; \
		exit 1; \
	}

# ─── Build Targets ───────────────────────────────────────────────
build-base: builder-ensure ## Build ROCm base image
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-base

build-pytorch: builder-ensure ## Build PyTorch (depends on base)
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch

build-runtime: builder-ensure ## Build runtime image (depends on pytorch)
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-run

build-all: builder-ensure ## Build all targets
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)"

# ─── Push Targets ────────────────────────────────────────────────
push-base: builder-ensure ## Build and push base image
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-base
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--push

push-pytorch: builder-ensure ## Build and push PyTorch
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--push

push-runtime: builder-ensure ## Build and push runtime image
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-run
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--push

push-all: builder-ensure ## Build and push all targets
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)"

# ─── Test ─────────────────────────────────────────────────────────
test: builder-ensure ## Run test target
	@$(BAKE) \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-test

# ─── Utilities ────────────────────────────────────────────────────
validate: ## Validate bake file
	@docker buildx bake -f bake.hcl --print | jq empty && echo "Bake file is valid" || echo "Bake file has errors"

bake-plan: ## Print build plan
	@docker buildx bake -f bake.hcl --print | jq .

clean: ## Remove built images from local registry
	@docker rmi $(REGISTRY)/$(REGISTRY_NAME)/base:$(ROCM_VERSION)-$(PYTHON_VERSION) 2>/dev/null || true
	@docker rmi $(REGISTRY)/$(REGISTRY_NAME)/pytorch:$(PYTORCH_VERSION)-$(ROCM_VERSION)-gfx950 2>/dev/null || true
	@docker rmi $(REGISTRY)/$(REGISTRY_NAME)/runtime:$(PYTORCH_VERSION)-$(ROCM_VERSION) 2>/dev/null || true
	@echo "Local images cleaned"

clean-cache: ## Remove cache images from Zot
	@echo "Removing cache images..."
	@for tag in base-cache pytorch-cache runtime-cache cache; do \
		docker rmi $(REGISTRY)/$(REGISTRY_NAME)/$$tag 2>/dev/null || true; \
	done
	@echo "Cache images removed (local only; Zot registry must be pruned separately)"

setup: zot-check builder-setup ## Full setup: check Zot, then builders
	@echo "Setup complete. Run 'make build-all' to start building."
