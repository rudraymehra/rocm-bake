# Makefile - convenience wrapper for rocm-pytorch builds

REGISTRY ?= localhost:5000
REGISTRY_NAME ?= rocm-pytorch
PYTORCH_VERSION ?= 2.14.1
ROCm_VERSION ?= 10.1.0-full
PYTHON_VERSION ?= 3.12
BUILDER ?= strix

.PHONY: help zot-up zot-down zot-logs \
        builder-setup builder-strix builder-think \
        build-base build-pytorch build-runtime build-all \
        push-base push-pytorch push-runtime push-all \
        clean clean-cache test \
        validate bake-plan

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ─── Zot Registry ────────────────────────────────────────────────
zot-up: ## Start Zot registry
	@cd zot && docker compose up -d
	@echo "Waiting for Zot to be ready..."
	@until curl -sf http://$(REGISTRY)/v2/_catalog > /dev/null 2>&1; do sleep 2; done
	@echo "Zot registry is ready at $(REGISTRY)"

zot-down: ## Stop Zot registry
	@cd zot && docker compose down

zot-logs: ## Show Zot registry logs
	@cd zot && docker compose logs -f

# ─── Buildx Builder Setup ────────────────────────────────────────
builder-setup: builder-strix builder-think ## Setup all builders

builder-strix: ## Setup Strix builder (docker-container driver)
	@if docker buildx ls | grep -q 'strix'; then \
		echo "Strix builder already exists"; \
	else \
		echo "Creating Strix builder..."; \
		docker buildx create \
			--name strix \
			--driver docker-container \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=104857600 \
			--driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=10485760 \
			--platform linux/amd64; \
	fi
	@docker buildx use strix
	@echo "Strix builder active"

builder-think: ## Setup Think builder (remote driver)
	@if docker buildx ls | grep -q 'think'; then \
		echo "Think builder already exists"; \
	else \
		echo "Creating Think builder..."; \
		docker buildx create \
			--name think \
			--driver remote \
			--driver-opt cacert=${PWD}/.certs/client/ca.pem \
			--driver-opt cert=${PWD}/.certs/client/cert.pem \
			--driver-opt key=${PWD}/.certs/client/key.pem \
			tcp://snoc-think:1234; \
	fi

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

setup: builder-setup zot-up ## Full setup: builders + Zot
	@echo "Setup complete. Run 'make build-all' to start building."
