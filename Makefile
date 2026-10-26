# Makefile - convenience wrapper for rocm-pytorch builds

# Bare-metal zot on Strix (zot.service, /etc/zot/config.json). The
# MagicDNS name only resolves inside a builder because every builder-*
# target below passes --driver-opt network=host; see the comment in
# .builders/buildkitd-strix.toml.
REGISTRY ?= snoc-strix.fold-leaffish.ts.net:8080
REGISTRY_NAME ?= rocm-pytorch
PYTORCH_VERSION ?= 2.14.1
ROCM_VERSION ?= 10.1.0-full
PYTHON_VERSION ?= 3.14
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
# Provenance for the image tags and OCI labels. VCS_REF gets a -dirty
# suffix when the tree has uncommitted changes, so an image built from
# edited sources can never be mistaken for the commit it came from.
VCS_REF ?= $(shell git rev-parse --short HEAD 2>/dev/null)$(shell git diff --quiet 2>/dev/null || echo -dirty)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
export VCS_REF
export BUILD_DATE

TELEMETRY ?= 1
ifeq ($(TELEMETRY),0)
BAKE = docker buildx bake -f bake.hcl
else
BAKE = ./telemetry/build.sh
endif

.PHONY: help zot-check zot-catalog zot-tags zot-logs \
        builder-setup builder-snoc-strix builder-snoc-think builder-snoc-gaming \
        builder-snoc-pool builder-status builder-logs builder-restart \
        build-status build-logs build-inspect builder-ensure watch \
        cold-build build-aiter push-aiter aiter-wheel \
        build-base build-pytorch build-runtime build-all \
        push-base push-pytorch push-runtime push-all \
        clean clean-cache test \
        validate bake-plan setup

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
		/^[a-zA-Z_-]+:.*?## / { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' \
		$(MAKEFILE_LIST)
	@printf '\nCommon variables: BUILDER (default %s), REGISTRY, PYTORCH_VERSION,\n' "$(BUILDER)"
	@printf 'ROCM_VERSION, PYTHON_VERSION, TELEMETRY=0 to skip metrics.\n'

# ─── Zot Registry ────────────────────────────────────────────────
# zot runs as a bare-metal systemd service on Strix, deployed and owned
# outside this repo. These targets inspect it; they never start or stop
# it, because other services on the fleet pull through the same registry.
##@ Registry (Zot)

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
##@ Builders

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

##@ Monitoring

builder-status: ## Show all builders and their nodes
	@docker buildx ls

# The buildkitd *daemon* log, which is a different thing from a build
# log: scheduling, cache GC, registry auth and connection failures. Use
# `make watch` or `docker buildx history logs` for the steps of a build.
# The container lives on whichever node the endpoint points at, so a
# remote node's log has to be fetched over SSH.
builder-logs: ## Tail buildkitd's own log for each node of $(BUILDER)
	@docker buildx inspect $(BUILDER) 2>/dev/null \
		| awk '/^Name:[[:space:]]+[^[:space:]]/ {n=$$2} /^Endpoint:/ {print n, $$2}' \
		| while read node endpoint; do \
			echo "══ $$node ($$endpoint)"; \
			case "$$endpoint" in \
				ssh://*) ssh "$${endpoint#ssh://}" \
					"docker logs --tail $(WATCH_LINES) buildx_buildkit_$$node 2>&1" ;; \
				*) docker logs --tail $(WATCH_LINES) "buildx_buildkit_$$node" 2>&1 ;; \
			esac; \
		done

# `history logs` streams and never returns while a build is in flight, so
# it is bounded by timeout(1). Killing the stream makes the client print
# "rpc error: code = Canceled", once per refresh, which reads like a
# build failure and is not one — hence the grep. Buffer through a file
# rather than piping
# straight to tail: when timeout kills docker mid-pipe the buffered
# output is lost and the shell prints "Terminated" into the display.
WATCH_INTERVAL ?= 5
WATCH_LINES ?= 20
WATCH_TMP := /tmp/.rocm-build-watch.log
# Every snoc-* builder, so a build started on any node shows up. The pool
# keeps its own buildkit instances separate from the single-node
# builders, so it has its own history and is listed in its own right.
# Override to narrow: make watch WATCH_BUILDERS=snoc-think
# Parse the table, not --format '{{.Name}}': that prints node names too,
# so the pool's nodes come back as duplicate builder names.
WATCH_BUILDERS ?= $(shell docker buildx ls 2>/dev/null | awk 'NR>1 && /^[^ ]/ {gsub(/\*$$/,"",$$1); print $$1}' | grep -E '^snoc-' | tr '\n' ' ')

watch: ## Live build history across all snoc-* builders (WATCH_BUILDERS=, WATCH_LINES=)
	@command -v watch > /dev/null || { echo "watch(1) not found: apt-get install procps"; exit 1; }
	@watch -n $(WATCH_INTERVAL) -t --color ' \
		for b in $(WATCH_BUILDERS); do \
			out=$$(docker buildx history ls --builder $$b 2>/dev/null | tail -n +2); \
			[ -n "$$out" ] || continue; \
			echo "══ $$b"; \
			echo "$$out"; \
			for id in $$(docker buildx history ls --builder $$b \
					--filter status=running --format "{{.Ref}}" 2>/dev/null); do \
				echo; echo "──── $$b / $$id ────"; \
				timeout 3 docker buildx history logs "$$id" --builder $$b \
					> $(WATCH_TMP) 2>&1 || true; \
				grep -v "^$$" $(WATCH_TMP) \
					| grep -v "rpc error: code = Canceled" \
					| tail -$(WATCH_LINES); \
			done; \
			echo; \
		done'



# Build targets depend on this, not on builder-snoc-strix: hardcoding one
# builder as the prerequisite meant `make push-base BUILDER=snoc-think`
# created snoc-strix and made it the default, then built somewhere else.
# Restart buildkitd on each node of $(BUILDER). This is how you clear a
# build that is wedged — a stuck upload, or one left retrying after an
# infrastructure fault. It drops that node's in-memory build state; the
# registry layer cache and the shared compiler cache are untouched.
builder-restart: ## Restart buildkitd for $(BUILDER), clearing stuck builds
	@docker buildx inspect $(BUILDER) 2>/dev/null \
		| awk '/^Name:[[:space:]]+[^[:space:]]/ {n=$$2} /^Endpoint:/ {print n, $$2}' \
		| while read node endpoint; do \
			echo "restarting buildkitd on $$node ($$endpoint)"; \
			case "$$endpoint" in \
				ssh://*) ssh "$${endpoint#ssh://}" \
					"docker restart buildx_buildkit_$$node" > /dev/null ;; \
				*) docker restart "buildx_buildkit_$$node" > /dev/null ;; \
			esac; \
		done
	@echo "done"

build-status: ## List build records for $(BUILDER)
	@docker buildx history ls --builder $(BUILDER)

# The steps of a build, as opposed to builder-logs which is the daemon.
# Defaults to the most recent record; pass BUILD=<id> for a specific one.
BUILD ?=
build-logs: ## Show build-step logs (BUILD=<id>, default: most recent)
	@id="$(BUILD)"; \
	[ -n "$$id" ] || id=$$(docker buildx history ls --builder $(BUILDER) \
		--format "{{.Ref}}" 2>/dev/null | head -1); \
	[ -n "$$id" ] || { echo "No build records on $(BUILDER)"; exit 1; }; \
	echo "══ $$id"; \
	timeout 10 docker buildx history logs "$$id" --builder $(BUILDER) 2>&1 \
		| grep -v "rpc error: code = Canceled" || true

build-inspect: ## Duration, steps and cache stats (BUILD=<id>, default: most recent)
	@id="$(BUILD)"; \
	[ -n "$$id" ] || id=$$(docker buildx history ls --builder $(BUILDER) \
		--format "{{.Ref}}" 2>/dev/null | head -1); \
	[ -n "$$id" ] || { echo "No build records on $(BUILDER)"; exit 1; }; \
	docker buildx history inspect "$$id" --builder $(BUILDER)

builder-ensure:
	@docker buildx inspect $(BUILDER) > /dev/null 2>&1 || { \
		echo "Builder '$(BUILDER)' does not exist. Create it with:"; \
		echo "  make builder-$(BUILDER)"; \
		exit 1; \
	}

# ─── Build Targets ───────────────────────────────────────────────
# One canned recipe for every bake invocation. This used to be nine
# copy-pasted blocks, and they had drifted: each push-* target ran the
# build with no --push, then a SECOND bake with --push but no target
# name — which builds and pushes the whole default group. `make
# push-base` would have kicked off the full PyTorch build.
#
#   $(1) bake target ("" = the default group)
#   $(2) extra flags (--push)
define bake
@$(BAKE) \
	--builder $(BUILDER) \
	--set "*.args.REGISTRY=$(REGISTRY)" \
	--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
	--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
	--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
	--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
	$(2) $(1)
endef

##@ Build

build-base: builder-ensure ## Build ROCm base image
	$(call bake,pytorch-base)

build-pytorch: builder-ensure ## Build PyTorch (depends on base)
	$(call bake,pytorch)

build-runtime: builder-ensure ## Build runtime image (depends on pytorch)
	$(call bake,pytorch-run)

build-all: builder-ensure ## Build all targets
	$(call bake,)

# A genuinely cold build: no layer cache AND no compiler-cache hits.
# --no-cache alone is not cold — sccache would still serve every object
# from the shared store, and the build would finish in minutes while
# measuring nothing. SCCACHE_RECACHE=true forces every compile to run and
# repopulate. Use it to measure true build cost, not for routine builds.
COLD_TARGET ?= pytorch

cold-build: builder-ensure ## Fully cold build (no layer or compiler cache). COLD_TARGET=
	@echo "Cold build of $(COLD_TARGET) on $(BUILDER): no layer cache, no sccache hits."
	$(call bake,$(COLD_TARGET),--no-cache --set "*.args.SCCACHE_RECACHE=true")

# ─── Push Targets ────────────────────────────────────────────────
# --push replaces the image output, so these build and push in one pass
# rather than building twice.
##@ Push

push-base: builder-ensure ## Build and push base image
	$(call bake,pytorch-base,--push)

push-pytorch: builder-ensure ## Build and push PyTorch
	$(call bake,pytorch,--push)

push-runtime: builder-ensure ## Build and push runtime image
	$(call bake,pytorch-run,--push)

push-all: builder-ensure ## Build and push all targets
	$(call bake,,--push)

##@ AITER

build-aiter: builder-ensure ## Build the AITER wheel (needs pytorch pushed first)
	$(call bake,aiter)

push-aiter: builder-ensure ## Build and push the AITER wheel image
	$(call bake,aiter,--push)

# The wheel lives in an image; this is how you get it onto local disk.
aiter-wheel: ## Extract the AITER wheel from the registry into ./dist
	@mkdir -p dist
	@docker buildx build --builder $(BUILDER) \
		--output type=local,dest=dist \
		- <<< "FROM $(REGISTRY)/$(REGISTRY_NAME)/aiter:latest"
	@ls -la dist/wheels/

# ─── Test ─────────────────────────────────────────────────────────
##@ Test

test: builder-ensure ## Run test target
	$(call bake,pytorch-test)

# ─── Utilities ────────────────────────────────────────────────────
##@ Utilities

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
