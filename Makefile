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
PYTORCH_ROCM_ARCH ?= gfx950
BUILDER ?= snoc-strix
REPO ?= $(REGISTRY_NAME)/base

# Remote build nodes. SSH endpoints, so these must be reachable as
# `ssh <host>` from here (tailnet names work on the host; only builder
# *containers* lack MagicDNS). Note the builder is named snoc-think but
# the machine is snoc-thinkstation — there is no snoc-think on the
# tailnet, so this variable keeps the real hostname.
# (THINK_HOST and GAMING_HOST are defined below.)

# The tailnet must never go through the corporate proxy. HTTP_PROXY and
# HTTPS_PROXY are set in this environment but no_proxy is not, so every
# proxy-aware tool (curl in some modes, python urllib, Go binaries like
# zli and docker) tries to reach snoc-* through ZScaler and fails. Set
# it here so make targets are correct regardless of the user's shell;
# add the same to your profile for interactive use.
NO_PROXY_LIST := localhost,127.0.0.1,::1,.ts.net,.local,10.0.0.0/8,100.64.0.0/10
export no_proxy := $(NO_PROXY_LIST)
export NO_PROXY := $(NO_PROXY_LIST)

# help lives at the bottom of this file, in its own section, so it is
# no longer the first target. Without this, `make` with no arguments
# would run whatever target happens to come first.
.DEFAULT_GOAL := help

# Aliased so the recipe text does not contain the literal $(MAKE):
# make executes any line referencing $(MAKE) even under -n, which made
# `make -n watch` launch a full-screen watch instead of printing it.
MAKE_BIN := $(MAKE)

# Shared compiler-cache store on Strix: nginx WebDAV over a directory
# tree, so it survives a reboot. Replaced memcached, which did not.
WEBDAV_HOST ?= snoc-strix.fold-leaffish.ts.net
WEBDAV_PORT ?= 8081
WEBDAV_URL  ?= http://$(WEBDAV_HOST):$(WEBDAV_PORT)

# Build containers address the store by IP, resolved here once, not by
# name. buildkitd is configured with MagicDNS plus two public
# resolvers; when MagicDNS is slow under load a tailnet lookup falls
# through to a public resolver, which answers NXDOMAIN, after which the
# search domain is appended and the query becomes nonsense:
#
#   DNS error: no records found for Query { name:
#     Name("snoc-strix.fold-leaffish.ts.net.fold-leaffish.ts.net.") }
#
# That hit both reads and writes — 79 of 361 compiles in one triton
# build — so objects were recompiled and then thrown away. The name
# stays the configuration surface; only the containers see an address.
WEBDAV_IP   ?= $(shell getent hosts $(WEBDAV_HOST) 2>/dev/null | awk '{print $$1; exit}')
SCCACHE_WEBDAV_ENDPOINT ?= http://$(or $(WEBDAV_IP),$(WEBDAV_HOST)):$(WEBDAV_PORT)
export SCCACHE_WEBDAV_ENDPOINT
WEBDAV_DIR  ?= /var/cache/sccache-webdav

# A sentinel, not a builder. BUILDER=snoc-pool means "let the balancer
# choose"; requests for it are routed through .builders/balance.sh,
# which runs each target against a concrete node. Nothing is ever built
# against a buildx pool now, so the pool builder need not exist — and if
# it does, its records never update, which is why watch skips it.
# Reclaim its containers with: docker buildx rm snoc-pool
POOL_BUILDER ?= snoc-pool

THINK_HOST ?= snoc-thinkstation
GAMING_HOST ?= snoc-gaming

# Every build goes through the telemetry wrapper: it runs the bake, then
# records duration, layer-cache hit ratio and sccache counters, and exits
# with the bake's own status. TELEMETRY=0 for a bare bake.
# Provenance for the image tags and OCI labels. VCS_REF gets a -dirty
# suffix when the tree has uncommitted changes, so an image built from
# edited sources can never be mistaken for the commit it came from.
VCS_REF ?= $(shell git rev-parse --short HEAD 2>/dev/null)$(shell git diff --quiet 2>/dev/null || echo -dirty)
# The commit's own timestamp, not "now". OCI's `created` is meant to
# describe the artifact, and wall-clock time made every rebuild of the
# same commit produce a different image config — hence a different
# digest, invalidating every downstream FROM. Falls back to now outside
# a git tree.
BUILD_DATE ?= $(shell git log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
export VCS_REF
export BUILD_DATE

# BUILD_DATE only reaches the `created` LABEL. The image *config* has a
# `created` field of its own, which BuildKit stamps with nanosecond
# wall-clock time regardless — so two builds of identical content got
# different config digests, different manifest digests, and every
# downstream FROM missed. SOURCE_DATE_EPOCH is what pins that field.
#
# Per image, not per repo. Taking it from HEAD meant every commit gave
# the base a new `created`, hence a new digest, hence a full downstream
# rebuild — even for a commit that only touched the Makefile. Measured:
# Dockerfile.base unchanged between cf70d3c and 87f539e, yet the base
# digest moved 91db3c2e -> aa52684f and nothing downstream could hit.
#
# Keying each image to the last commit that touched its own Dockerfile
# means an image's timestamp moves only when its inputs do. These are
# passed as build args rather than exported, because the arg takes
# precedence over the environment and bake builds several images in one
# invocation — one env var cannot describe them all.
SDE_FALLBACK := $(shell git log -1 --format=%ct 2>/dev/null || date -u +%s)
sde = $(or $(shell git log -1 --format=%ct -- $(1) 2>/dev/null),$(SDE_FALLBACK))
SDE_BASE    ?= $(call sde,Dockerfile.base)
SDE_PYTORCH ?= $(call sde,Dockerfile.pytorch)
SDE_TRITON  ?= $(call sde,Dockerfile.triton)
SDE_AITER   ?= $(call sde,Dockerfile.aiter)
SDE_RUNTIME ?= $(call sde,Dockerfile.runtime)
export SDE_BASE SDE_PYTORCH SDE_TRITON SDE_AITER SDE_RUNTIME

TELEMETRY ?= 1
ifeq ($(TELEMETRY),0)
BAKE = docker buildx bake -f bake.hcl
else
BAKE = ./telemetry/build.sh
endif

.PHONY: help zot-check zot-catalog zot-tags zot-wheels zot-wheelhouse zot-logs \
        builder-setup builder-snoc-strix builder-snoc-think builder-snoc-gaming \
        builder-snoc-pool builder-status builder-logs builder-restart \
        build-status build-logs build-inspect builder-ensure watch \
        cold-build push-aiter-wheel fetch-aiter-wheel push-wheels \
        build-torch-wheel build-triton-wheel build-aiter-wheel \
        _build-all _push-all \
        push-torch-wheel fetch-torch-wheel \
        push-triton-wheel fetch-triton-wheel \
        cache-stats cache-summary cache-check cache-logs builder-load \
        list-vars \
        build-base build-pytorch build-runtime build-all \
        push-base push-pytorch push-runtime push-all \
        clean clean-cache test \
        validate bake-plan setup

# ─── Zot Registry ────────────────────────────────────────────────
# zot runs as a bare-metal systemd service on Strix, deployed and owned
# outside this repo. These targets inspect it; they never start or stop
# it, because other services on the fleet pull through the same registry.
##@ OCI Registry (Zot)

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

# Wheel artifacts are plain images whose only payload is /wheels, so
# they show up in the catalog like anything else — this filters to them.
WHEEL_REPOS ?= pytorch-wheel triton-wheel aiter-wheel
zot-wheels: ## List wheel artifacts published to Zot, with sizes
	@python3 .builders/wheelhouse.py --brief "$(REGISTRY)" "$(REGISTRY_NAME)" $(WHEEL_REPOS)

zot-wheelhouse: ## Show published wheel artifacts and their sizes
	@python3 .builders/wheelhouse.py "$(REGISTRY)" "$(REGISTRY_NAME)" $(WHEEL_REPOS)
	@if [ -d dist/wheels ]; then \
		echo "  --- extracted locally (./dist/wheels) ---"; \
		ls -1sh dist/wheels/ | tail -n +2 | sed 's/^/      /'; \
	fi

zot-logs: ## Follow Zot registry logs
	@sudo journalctl -u zot -f

# ─── Buildx Builder Setup ────────────────────────────────────────
##@ Compiler Cache

# The sccache store every node shares: nginx WebDAV over a directory
# tree on Strix. It replaced memcached, which held everything in RAM and
# lost the fleet's cache on every power cycle.
#
# WebDAV has no stats verb, so unlike memcached the store cannot report
# hit rates — only size and object count. Hit rates come from sccache
# itself, which prints --show-stats at the end of each build.
cache-stats: ## Show the shared compiler-cache (WebDAV) state
	@curl -sf -o /dev/null -w "  endpoint            HTTP %{http_code}  $(WEBDAV_URL)\n" "$(WEBDAV_URL)/" \
		|| { echo "  endpoint            UNREACHABLE  $(WEBDAV_URL)"; exit 1; }
	@sudo du -sh $(WEBDAV_DIR) 2>/dev/null | awk '{printf "  size                %s\n", $$1}'
	@sudo find $(WEBDAV_DIR) -type f 2>/dev/null | wc -l | awk '{printf "  objects             %s\n", $$1}'
	@df -h $(WEBDAV_DIR) 2>/dev/null | tail -1 \
		| awk '{printf "  filesystem          %s of %s used, %s free\n", $$3, $$2, $$4}'
	@echo "  hit_rate            see 'sccache --show-stats' in the build log"

CACHE_STATE := /tmp/.rocm-cache-prev

# Totals alone say nothing about the build in front of you, so this
# prints current state plus the delta since the previous call — the
# number that moves while a build runs.
cache-summary: ## One-line cache state plus deltas since the last call
	@objs=$$(sudo find $(WEBDAV_DIR) -type f 2>/dev/null | wc -l); \
	size=$$(sudo du -sb $(WEBDAV_DIR) 2>/dev/null | cut -f1); \
	if [ -z "$$size" ]; then \
		echo "══ sccache store unreachable at $(WEBDAV_DIR)"; \
	else \
		echo "$$objs $$size" > $(CACHE_STATE).now; \
		[ -s $(CACHE_STATE) ] || cp $(CACHE_STATE).now $(CACHE_STATE); \
		paste $(CACHE_STATE).now $(CACHE_STATE) \
		| awk '{ \
			o=$$1; b=$$2; po=$$3; pb=$$4; \
			printf "══ sccache store (WebDAV, durable)\n"; \
			printf "objects=%d  size=%.2fGB\n", o, b/1073741824; \
			if (o - po <= 0) \
				printf "interval  idle (no new objects since last refresh)\n"; \
			else \
				printf "interval  +%d objects  +%.0fMB\n", o-po, (b-pb)/1048576; \
			}'; \
		mv $(CACHE_STATE).now $(CACHE_STATE); \
	fi

cache-check: ## Verify every build node can reach the compiler cache
	@for h in localhost $(THINK_HOST) $(GAMING_HOST); do \
		printf '  %-20s ' "$$h"; \
		if [ "$$h" = localhost ]; then \
			curl -sf -o /dev/null -w 'HTTP %{http_code}' "$(WEBDAV_URL)/" || printf UNREACHABLE; \
		else \
			ssh -n -o BatchMode=yes "$$h" "curl -sf -o /dev/null -w 'HTTP %{http_code}' '$(WEBDAV_URL)/'" 2>/dev/null \
				|| printf UNREACHABLE; \
		fi; \
		echo; \
	done

cache-logs: ## Follow the WebDAV store's access log
	@sudo tail -f /var/log/nginx/access.log

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
				ssh://*) ssh -n "$${endpoint#ssh://}" \
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
# Build records shown per builder. The full list grows without bound and
# pushes the running build off screen.
WATCH_HISTORY ?= 5
WATCH_TMP := /tmp/.rocm-build-watch.log
# Every snoc-* builder, so a build started on any node shows up. The pool
# keeps its own buildkit instances separate from the single-node
# builders, so it has its own history and is listed in its own right.
# Override to narrow: make watch WATCH_BUILDERS=snoc-think
# Parse the table, not --format '{{.Name}}': that prints node names too,
# so the pool's nodes come back as duplicate builder names.
WATCH_BUILDERS ?= $(shell docker buildx ls 2>/dev/null | awk 'NR>1 && /^[^ ]/ {gsub(/\*$$/,"",$$1); print $$1}' | grep -E '^snoc-' | grep -v '^$(POOL_BUILDER)$$' | tr '\n' ' ')

watch: ## Live build history across all snoc-* builders (WATCH_BUILDERS=, WATCH_LINES=)
	@command -v watch > /dev/null || { echo "watch(1) not found: apt-get install procps"; exit 1; }
	@watch -n $(WATCH_INTERVAL) -t --color ' \
		printf "\\033[1mROCm PyTorch Build\\033[0m — watching %s · refresh %ss · %s\\n" \
			"$(strip $(WATCH_BUILDERS))" "$(WATCH_INTERVAL)" "$$(date +%H:%M:%S)"; \
		echo; \
		$(MAKE_BIN) --no-print-directory cache-summary; \
		echo; \
		for b in $(WATCH_BUILDERS); do \
			out=$$(python3 .builders/history.py $$b $(WATCH_HISTORY) 2>/dev/null); \
			[ -n "$$out" ] || continue; \
			echo "══ $$b"; \
			echo "$$out"; \
			run=$$(timeout 8 docker buildx history ls --builder $$b \
				--filter status=running --format "{{.Ref}}" 2>/dev/null); \
			if [ -n "$$run" ] || [ -s $(LOAD_CACHE).busy.$$b ]; then \
				[ -n "$$run" ] && touch $(LOAD_CACHE).busy.$$b || rm -f $(LOAD_CACHE).busy.$$b; \
				$(MAKE_BIN) --no-print-directory builder-load BUILDER=$$b; \
			fi; \
			echo; \
		done; \
		for b in $(WATCH_BUILDERS); do \
			for id in $$(docker buildx history ls --builder $$b \
					--filter status=running --format "{{.Ref}}" 2>/dev/null); do \
				echo "──── $$b / $$id ────"; \
				timeout 3 docker buildx history logs "$$id" --builder $$b \
					> $(WATCH_TMP) 2>&1 || true; \
				grep -v "^$$" $(WATCH_TMP) \
					| grep -v "rpc error: code = Canceled" \
					| tail -$(WATCH_LINES); \
				echo; \
			done; \
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
				ssh://*) ssh -n "$${endpoint#ssh://}" \
					"docker restart buildx_buildkit_$$node" > /dev/null ;; \
				*) docker restart "buildx_buildkit_$$node" > /dev/null ;; \
			esac; \
		done
	@echo "done"

# Per-node load. Kept as its own target so `watch` can re-enter make
# rather than inlining a second layer of quoting inside its shell string.
LOAD_CACHE := /tmp/.rocm-load
builder-load: ## Show CPU, cores and load for each node of $(BUILDER)
	@timeout 10 docker buildx inspect $(BUILDER) 2>/dev/null \
		| awk '/^Name:[[:space:]]+[^[:space:]]/ {n=$$2} /^Endpoint:/ {print n, $$2}' \
		| while read node endpoint; do \
			case "$$endpoint" in \
				ssh://*) stats=$$(timeout 6 ssh -n -o BatchMode=yes "$${endpoint#ssh://}" \
					"docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' buildx_buildkit_$$node 2>/dev/null; nproc; uptime" 2>/dev/null) ;; \
				*) stats=$$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}' "buildx_buildkit_$$node" 2>/dev/null; nproc; uptime) ;; \
			esac; \
			cpu=$$(echo "$$stats" | sed -n 1p | cut -d'|' -f1); \
			mem=$$(echo "$$stats" | sed -n 1p | cut -d'|' -f2); \
			cores=$$(echo "$$stats" | sed -n 2p); \
			load=$$(echo "$$stats" | sed -n 3p | sed 's/.*load average: //'); \
			line=$$(printf '   %-14s cpu=%-9s of %s cores   mem=%-22s load=%s' \
				"$$node" "$$cpu" "$$cores" "$$mem" "$$load"); \
			if [ -n "$$cpu" ] && [ -n "$$cores" ]; then \
				echo "$$line" | tee "$(LOAD_CACHE).$$node" ; \
			elif [ -s "$(LOAD_CACHE).$$node" ]; then \
				printf '%s  (stale)\n' "$$(cat $(LOAD_CACHE).$$node)"; \
			else \
				printf '   %-14s (load unavailable)\n' "$$node"; \
			fi; \
		done

build-status: ## List build records for $(BUILDER), with the node each ran on
	@python3 .builders/history.py $(BUILDER) $(WATCH_HISTORY)

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
	@[ "$(BUILDER)" = "$(POOL_BUILDER)" ] && exit 0; \
	docker buildx inspect $(BUILDER) > /dev/null 2>&1 || { \
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
@b="$(BUILDER)"; \
if [ "$$b" = "$(POOL_BUILDER)" ]; then \
	b=$$(.builders/balance.sh --best); \
	echo "balance: $(POOL_BUILDER) -> $$b"; \
fi; \
$(BAKE) \
	--builder "$$b" \
	--set "*.args.REGISTRY=$(REGISTRY)" \
	--set "*.args.REGISTRY_NAME=$(REGISTRY_NAME)" \
	--set "*.args.PYTORCH_VERSION=$(PYTORCH_VERSION)" \
	--set "*.args.ROCM_VERSION=$(ROCM_VERSION)" \
	--set "*.args.PYTHON_VERSION=$(PYTHON_VERSION)" \
	--set "*.args.PYTORCH_ROCM_ARCH=$(PYTORCH_ROCM_ARCH)" \
	$(BAKE_EXTRA) $(2) $(1)
endef

##@ Build

build-base: builder-ensure ## Build ROCm base image
	$(call bake,pytorch-base)

build-pytorch: builder-ensure ## Build PyTorch (depends on base)
	$(call bake,pytorch)

build-runtime: builder-ensure ## Build runtime image (depends on pytorch)
	$(call bake,pytorch-run)

# The wheels had push-only targets. Building one without publishing it
# is wanted when the registry is unavailable or unwritable — and the
# benchmark harness needs exactly that, since the credential helper
# cannot decrypt outside an interactive session.
build-torch-wheel: builder-ensure ## Build the torch wheel image (no push)
	$(call bake,pytorch-wheel)

build-triton-wheel: builder-ensure ## Build the Triton wheel image (no push)
	$(call bake,triton-wheel)

build-aiter-wheel: builder-ensure ## Build the AITER wheel image (no push)
	$(call bake,aiter-wheel)

# Not offered for the pool. Scheduling across nodes makes every target
# its own bake invocation, so they cannot hand results to each other
# through `target:` contexts — stage 2 would build against whatever is
# already in Zot rather than what stage 1 just produced, silently. On a
# single builder the contexts resolve in-process and this is fine.
build-all: ## Build every * target (images and wheels) — single builder only
	@if [ "$(BUILDER)" = "$(POOL_BUILDER)" ]; then \
		echo "build-all cannot use $(POOL_BUILDER): targets are scheduled across"; \
		echo "nodes as separate builds, so they can only exchange results"; \
		echo "through the registry. Use one of:"; \
		echo "  make push-all  BUILDER=$(POOL_BUILDER)   # scheduled, publishes"; \
		echo "  make build-all BUILDER=snoc-think        # single builder, no push"; \
		exit 1; \
	fi
	@$(MAKE_BIN) --no-print-directory _build-all BUILDER=$(BUILDER)

_build-all: builder-ensure
	$(call bake,)

# A genuinely cold build: no layer cache AND no compiler-cache hits.
# --no-cache alone is not cold — sccache would still serve every object
# from the shared store, and the build would finish in minutes while
# measuring nothing. SCCACHE_RECACHE=true forces every compile to run and
# repopulate. Use it to measure true build cost, not for routine builds.
COLD_TARGET ?= pytorch

cold-build: builder-ensure ## Fully cold build (no layer or compiler cache). COLD_TARGET=
	@echo "Cold build of $(COLD_TARGET) on $(BUILDER): no layer cache, no sccache hits."
	$(call bake,$(COLD_TARGET),--no-cache --set "*.args.FORCE_RECACHE=true")

# ─── Push Targets ────────────────────────────────────────────────
# --push replaces the image output, so these build and push in one pass
# rather than building twice.
##@ Push

push-base: builder-ensure ## * Build and push base image
	$(call bake,pytorch-base,--push)

push-pytorch: builder-ensure ## * Build and push PyTorch
	$(call bake,pytorch,--push)

push-runtime: builder-ensure ## * Build and push runtime image
	$(call bake,pytorch-run,--push)

BALANCE_STREAM ?= 1

push-all: ## Build and push everything (* targets) — the usual way to build
	@if [ "$(BUILDER)" = "$(POOL_BUILDER)" ]; then \
		BALANCE_STREAM=$(BALANCE_STREAM) .builders/balance.sh; \
	else \
		$(MAKE_BIN) --no-print-directory _push-all BUILDER=$(BUILDER); \
	fi

_push-all: builder-ensure
	$(call bake,,--push)

push-wheels: builder-ensure ## Push just the three wheel artifacts
	$(call bake,wheels,--push)

##@ Wheels

push-torch-wheel: builder-ensure ## * Build and push the torch wheel image to Zot
	$(call bake,pytorch-wheel,--push)

# The wheel lives in an image; this pulls it back onto local disk.
fetch-torch-wheel: ## Fetch the torch wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/pytorch-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

push-triton-wheel: builder-ensure ## * Build and push the Triton wheel image
	$(call bake,triton-wheel,--push)

fetch-triton-wheel: ## Fetch the Triton wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/triton-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
	@ls -la dist/wheels/

##@ AITER

push-aiter-wheel: builder-ensure ## * Build and push the AITER wheel image to Zot
	$(call bake,aiter-wheel,--push)

# The wheel lives in an image; this is how you get it onto local disk.
fetch-aiter-wheel: ## Fetch the AITER wheel from Zot into ./dist
	@mkdir -p dist
	@printf 'FROM %s/%s/aiter-wheel:latest\n' "$(REGISTRY)" "$(REGISTRY_NAME)" \
		| docker buildx build --builder $(BUILDER) \
			--output type=local,dest=dist -
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

##@ Help

help: ## Show this help
	@printf '\n\033[1mROCm PyTorch Build\033[0m — PyTorch %s on ROCm %s for %s\n' \
		"$(PYTORCH_VERSION)" "$(ROCM_VERSION)" "$(PYTORCH_ROCM_ARCH)"
	@printf 'Registry %s · builder %s\n' "$(REGISTRY)" "$(BUILDER)"
	@printf 'Usage: make <target> [VAR=value]\n'
	@awk 'BEGIN {FS = ":.*?## "; cmd = "sort"} \
		/^##@/ { if (insec) close(cmd); printf "\n\033[1m%s\033[0m\n", substr($$0, 5); insec = 1; next } \
		/^[a-zA-Z_-]+:.*?## / { \
			name = $$1; text = $$2; \
			if (substr(text, 1, 2) == "* ") { name = name " *"; text = substr(text, 3) } \
			line = sprintf("  \033[36m%-20s\033[0m %s", name, text); \
			if (insec) print line | cmd; else print line } \
		END { if (insec) close(cmd) }' \
		$(MAKEFILE_LIST)
	@printf '\n'

list-vars: ## Show the variables these targets read, and their values
	@printf '\n\033[1mBuild\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' PYTORCH_VERSION "$(PYTORCH_VERSION)"
	@printf '  \033[36m%-24s\033[0m %s\n' ROCM_VERSION "$(ROCM_VERSION)"
	@printf '  \033[36m%-24s\033[0m %s\n' PYTHON_VERSION "$(PYTHON_VERSION)"
	@printf '  \033[36m%-24s\033[0m %s\n' PYTORCH_ROCM_ARCH "$(PYTORCH_ROCM_ARCH)"
	@printf '  \033[36m%-24s\033[0m %s\n' MAX_JOBS "$(if $(MAX_JOBS),$(MAX_JOBS),(derived per node from free memory))"
	@printf '\n\033[1mWhere things run\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' BUILDER "$(BUILDER)"
	@printf '  \033[36m%-24s\033[0m %s\n' REGISTRY "$(REGISTRY)"
	@printf '  \033[36m%-24s\033[0m %s\n' REGISTRY_NAME "$(REGISTRY_NAME)"
	@printf '\n\033[1mCompiler cache\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' WEBDAV_HOST "$(WEBDAV_HOST)"
	@printf '  \033[36m%-24s\033[0m %s\n' SCCACHE_WEBDAV_ENDPOINT "$(SCCACHE_WEBDAV_ENDPOINT)"
	@printf '  \033[36m%-24s\033[0m %s\n' WEBDAV_DIR "$(WEBDAV_DIR)"
	@printf '\n\033[1mReproducibility\033[0m  (per image, from its own Dockerfile)\n'
	@printf '  \033[36m%-24s\033[0m %s\n' SDE_BASE "$(SDE_BASE)  ($(shell date -u -d @$(SDE_BASE) '+%Y-%m-%d %H:%M' 2>/dev/null))"
	@printf '  \033[36m%-24s\033[0m %s\n' SDE_PYTORCH "$(SDE_PYTORCH)  ($(shell date -u -d @$(SDE_PYTORCH) '+%Y-%m-%d %H:%M' 2>/dev/null))"
	@printf '  \033[36m%-24s\033[0m %s\n' SDE_TRITON "$(SDE_TRITON)  ($(shell date -u -d @$(SDE_TRITON) '+%Y-%m-%d %H:%M' 2>/dev/null))"
	@printf '  \033[36m%-24s\033[0m %s\n' SDE_AITER "$(SDE_AITER)  ($(shell date -u -d @$(SDE_AITER) '+%Y-%m-%d %H:%M' 2>/dev/null))"
	@printf '  \033[36m%-24s\033[0m %s\n' SDE_RUNTIME "$(SDE_RUNTIME)  ($(shell date -u -d @$(SDE_RUNTIME) '+%Y-%m-%d %H:%M' 2>/dev/null))"
	@printf '\n\033[1mToggles\033[0m\n'
	@printf '  \033[36m%-24s\033[0m %s\n' TELEMETRY "$(TELEMETRY)  (0 skips metrics collection)"
	@printf '  \033[36m%-24s\033[0m %s\n' FORCE_RECACHE "$(if $(FORCE_RECACHE),$(FORCE_RECACHE),false)  (true = recompile everything, ignoring sccache)"
	@printf '  \033[36m%-24s\033[0m %s\n' BAKE_EXTRA "$(if $(BAKE_EXTRA),$(BAKE_EXTRA),(none))"
	@printf '\nOverride any of these on the command line: make <target> VAR=value\n\n'
