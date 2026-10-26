# Makefile - convenience wrapper for rocm-pytorch builds

# Bare-metal zot on Strix (zot.service, /etc/zot/config.json). Tailnet IP
# rather than the MagicDNS name on purpose: buildkit builder containers
# get Docker's default resolver, not the tailnet one, so
# snoc-strix.fold-leaffish.ts.net does not resolve inside a build.
REGISTRY ?= 100.91.58.37:8080
REGISTRY_NAME ?= rocm-pytorch
PYTORCH_VERSION ?= 2.14.1
ROCm_VERSION ?= 10.1.0-full
PYTHON_VERSION ?= 3.12
BUILDER ?= strix

# Remote build nodes. SSH endpoints, so these must be reachable as
# `ssh <host>` from here (tailnet names work on the host; only builder
# *containers* lack MagicDNS). There is no `snoc-think` on the tailnet —
# the Thinkstation is snoc-thinkstation.
THINK_HOST ?= snoc-thinkstation
GAMING_HOST ?= snoc-gaming

.PHONY: help zot-check zot-catalog zot-logs \
        builder-setup builder-strix builder-think builder-gaming \
        builder-pool builder-status \
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

zot-logs: ## Follow Zot registry logs
	@sudo journalctl -u zot -f

# ─── Buildx Builder Setup ────────────────────────────────────────
builder-setup: builder-strix builder-think builder-gaming ## Setup all builders

builder-strix: ## Setup Strix builder (docker-container driver)
	@if docker buildx ls | grep -q 'strix'; then \
		echo "Strix builder already exists"; \
	else \
		echo "Creating Strix builder..."; \
		docker buildx create \
			--name strix \
			--driver docker-container \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64; \
	fi
	@docker buildx use strix
	@echo "Strix builder active"

# snoc-thinkstation and snoc-gaming join over SSH to their Docker
# daemons, not the remote/TLS driver: buildx creates and owns a buildkit
# container on each, so neither node needs buildkitd, TLS certs, or the
# buildx plugin installed. Both are gfx1201 (RDNA4), so they can
# cross-compile for gfx950 but cannot run the GPU test stage.
builder-think: ## Setup Thinkstation builder (docker-container over SSH)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'think'; then \
		echo "Think builder already exists"; \
	else \
		echo "Creating Think builder..."; \
		docker buildx create \
			--name think \
			--driver docker-container \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64 \
			ssh://$(THINK_HOST); \
	fi

builder-gaming: ## Setup Gaming builder (docker-container over SSH)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'gaming'; then \
		echo "Gaming builder already exists"; \
	else \
		echo "Creating Gaming builder..."; \
		docker buildx create \
			--name gaming \
			--driver docker-container \
			--config .builders/buildkitd-strix.toml \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64 \
			ssh://$(GAMING_HOST); \
	fi

# One builder with all three nodes. buildx spreads independent targets
# across nodes, so `make build-all BUILDER=pool` uses the whole fleet.
# A single target still builds on one node — this is fan-out, not a
# distributed compile of one image.
builder-pool: ## Setup a 3-node pool (strix + think + gaming)
	@if docker buildx ls --format '{{.Name}}' | grep -qx 'pool'; then \
		echo "Pool builder already exists"; \
	else \
		echo "Creating pool builder..."; \
		docker buildx create --name pool --node pool-strix \
			--driver docker-container \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64; \
		docker buildx create --name pool --append --node pool-think \
			--driver docker-container \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64 \
			ssh://$(THINK_HOST); \
		docker buildx create --name pool --append --node pool-gaming \
			--driver docker-container \
			--config .builders/buildkitd-strix.toml \
			--platform linux/amd64 \
			ssh://$(GAMING_HOST); \
	fi
	@docker buildx inspect pool --bootstrap

builder-status: ## Show all builders and their nodes
	@docker buildx ls

# ─── Build Targets ───────────────────────────────────────────────
build-base: builder-strix ## Build ROCm base image
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-base

build-pytorch: builder-strix ## Build PyTorch (depends on base)
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch

build-runtime: builder-strix ## Build runtime image (depends on pytorch)
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-run

build-all: builder-strix ## Build all targets
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)"

# ─── Push Targets ────────────────────────────────────────────────
push-base: builder-strix ## Build and push base image
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-base
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--push

push-pytorch: builder-strix ## Build and push PyTorch
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--push

push-runtime: builder-strix ## Build and push runtime image
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
		pytorch-run
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--push

push-all: builder-strix ## Build and push all targets
	@docker buildx bake -f bake.hcl \
		--builder $(BUILDER) \
		--set "*.args.REGISTRY=$(REGISTRY)" \
		--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
		--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
		--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
		--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)"

# ─── Test ─────────────────────────────────────────────────────────
test: builder-strix ## Run test target
	@docker buildx bake -f bake.hcl \
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
