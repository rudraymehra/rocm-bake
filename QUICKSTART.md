# Quick Start — ROCm PyTorch Build Lab

Get a working build environment on SNOC Strix (primary), with
snoc-thinkstation and snoc-gaming as extra build nodes, in under 15
minutes.

## Prerequisites

- All nodes on the same Tailscale network
- Strix: AMD gfx950 GPU, 30 GB RAM, Docker 27+ — runs Zot, the shared
  compiler cache, and the GPU tests
- snoc-thinkstation, snoc-gaming: Docker 27+ and SSH from Strix. Both are
  gfx1201 (RDNA4): they cross-compile for gfx950 but cannot run the test
  stage

Verify Docker is ready:

```bash
docker --version
docker buildx version
```

## Step 1 — Clone the repo

```bash
cd ~/Projects
git clone <your-repo-url> rocm-pytorch-build
cd rocm-pytorch-build
```

## Step 2 — Check Zot (Strix only)

Zot is the local OCI registry that caches images and holds the BuildKit
layer cache. It already runs on Strix as a bare-metal systemd service
(`zot.service`, config in `/etc/zot/config.json`), deployed and owned
outside this repo. **Do not start a second one** — this repo consumes the
existing service and never manages its lifecycle.

```bash
make zot-check
```

Expected: `zot.service: active` and `Zot registry is ready at
snoc-strix.fold-leaffish.ts.net:8080`. To see what it holds:

```bash
make zot-catalog
```

Anonymous read is open — every pull, pull-through and cache read works
unauthenticated. Only pushing needs the `ci` account from
`/etc/zot/htpasswd`.

Store the credential with `pass`, which is GPG-encrypted at rest and
works over SSH. The `secretservice` helper does not: it fails with
`Cannot create an item in a locked collection` whenever the gnome-keyring
login collection has not been unlocked by a graphical session.

```bash
sudo apt-get install -y pass golang-docker-credential-helpers
pass init <your-gpg-key-id>          # gpg --list-secret-keys --keyid-format=long
# set "credsStore": "pass" in ~/.docker/config.json
docker login snoc-strix.fold-leaffish.ts.net:8080 -u ci
```

Verify it landed:

```bash
docker-credential-pass list
```

Zot also needs a raised HTTP read timeout, or pushing the ROCm base
fails: its largest layer is 8.67GB and cannot cross a 1Gb/s link within
Zot's 60-second default. In `/etc/zot/config.json`:

```json
"http": {
  "readTimeout": "30m",
  "writeTimeout": "30m"
}
```

followed by `sudo systemctl restart zot`. Check with `make zot-check`.

One login on Strix is enough for the whole fleet. buildx sends registry
auth from your local Docker config to the builder as a session
attachment, so builds pushing from think or gaming use it too — those
nodes never need their own credential.

The registry serves plain HTTP over the tailnet, so the Docker daemon
needs it in `/etc/docker/daemon.json` (already set on Strix):

```json
{
  "insecure-registries": ["snoc-strix.fold-leaffish.ts.net:8080"],
  "registry-mirrors": ["http://snoc-strix.fold-leaffish.ts.net:8080"]
}
```

## Step 3 — Create the buildx builder (Strix)

```bash
make builder-snoc-strix
```

The builder needs `.builders/buildkitd-strix.toml` — `make builder-snoc-strix`
passes it. That config carries three things builds cannot work without:
plain HTTP to Zot, the Zot pull-through mirrors, and a `[dns]` block so
RUN steps can resolve tailnet names (they get their own resolv.conf, not
the node's). Creating the builder by hand needs both flags: `--config`,
and `network=host` so the builder itself resolves the registry.

Both settings are baked in at create time. After editing the toml,
`docker buildx rm snoc-strix && make builder-snoc-strix` — an existing builder
does not pick up changes.

```bash
docker buildx create --name snoc-strix --driver docker-container \
  --driver-opt network=host \
  --config .builders/buildkitd-strix.toml
docker buildx use snoc-strix
```

(Optional) Add the other two nodes. They join over SSH to their Docker
daemons, so nothing needs installing on them — no buildkitd, no TLS
certs, not even the buildx plugin:

```bash
make builder-snoc-think     # snoc-think (runs on snoc-thinkstation)
make builder-snoc-gaming    # snoc-gaming
make builder-snoc-pool      # all three as one builder named "snoc-pool"
make builder-status    # docker buildx ls
```

Then target the whole fleet:

```bash
make build-all BUILDER=snoc-pool
```

The pool fans *targets* out across nodes; it does not split one image
across them. Both remote nodes are gfx1201 (RDNA4), so they can
cross-compile for gfx950 but cannot run the GPU test stage — keep
`make test` on Strix.

## Step 4 — Deploy the shared compiler cache (Strix only)

Every build node compiles against one shared sccache store, so an object
compiled on any node is a cache hit on the others. The store is
memcached on Strix: 8GB in RAM, then spilling to a 200GB file on disk.

```bash
sudo ./.builders/deploy-memcached.sh
```

Verify it is up and reachable from the other nodes:

```bash
printf 'stats\r\nquit\r\n' | nc snoc-strix.fold-leaffish.ts.net 11211 \
  | grep -E 'curr_items|get_hits|get_misses|extstore_pages_free'
```

There is nothing to install on thinkstation or gaming: each build
container runs its own sccache client and server, pointed at this store.

> `.builders/deploy-sccache.sh` installs a *node-level* sccache daemon on
> port 4226. Builds do not use it — it is only for compiling on the host
> directly. Leave it alone unless you need that; it must never move to
> port 4250, which the in-container servers use.

## Step 5 — Build

```bash
make build-all              # every target
make build-pytorch          # just PyTorch (~30-60 min cold)
make build-all BUILDER=snoc-pool # fan targets across all three nodes
```

To measure true build cost, `make cold-build` disables both caches —
no layer reuse and no sccache hits, so every object really compiles:

```bash
make cold-build BUILDER=snoc-think
make cold-build COLD_TARGET=pytorch-base
```

`--no-cache` on its own is not cold: sccache would still serve every
object from the shared store and the build would finish in minutes
while measuring nothing.

Each `make build-*` runs through `telemetry/build.sh`, which records
duration, layer-cache hit ratio and sccache counters, then exits with
the build's own status. `TELEMETRY=0 make build-pytorch` skips it.

The build refuses to start if the shared compiler cache is unreachable,
rather than silently recompiling everything cold. To override:

```bash
docker buildx bake -f bake.hcl --set '*.args.REQUIRE_SCCACHE=0' pytorch
```

Push to Zot (needs the `ci` login from Step 2):

```bash
make push-all
```

After a build, the metrics are in
`/var/lib/node_exporter/textfile_collector/rocm_pytorch_build.prom`, or
`telemetry/out/` when that directory is not writable.

Watch a build from a second terminal — this covers every builder, with a
live tail of each running build:

```bash
make watch
make watch WATCH_BUILDERS=snoc-think WATCH_LINES=40
```

Or look at one thing at a time:

```bash
make build-status     # records on $(BUILDER): running, completed, errored
make build-logs       # step output, BUILD=<id> for a specific record
make build-inspect    # duration, steps, cached steps, VCS revision
make builder-logs     # buildkitd's own log: registry, DNS, cache failures
make builder-restart  # clear a wedged build on $(BUILDER)
```

`build-logs` is what the build's steps printed; `builder-logs` is the
daemon underneath, which is where a registry or DNS fault shows up while
the build itself merely looks slow.

## Step 6 — Verify the build

```bash
docker run --rm -it --device /dev/kfd --device /dev/dri \
  snoc-strix.fold-leaffish.ts.net:8080/rocm-pytorch/pytorch:2.14.1-10.1.0-full-gfx950
```

Then in the container:

```python
import torch
print(torch.__version__)       # 2.14.1+rocm10.1
print(torch.cuda.is_available())  # True
print(torch.cuda.get_device_name(0))
```

## Custom versions

Change defaults at build time:

```bash
# Use ROCm 7.14 instead of 10.1
docker buildx bake -f bake.hcl \
  --set "target.pytorch.args.ROCM_VERSION=7.14" pytorch

# Build for multiple arches
docker buildx bake -f bake.hcl \
  --set "target.pytorch.args.PYTORCH_ROCM_ARCH='gfx90a;gfx942;gfx950'" pytorch

# Disable optional libraries
docker buildx bake -f bake.hcl \
  --set "target.pytorch.args.USE_AITER=OFF" \
  --set "target.pytorch.args.USE_FLASH_ATTENTION=OFF" pytorch
```

## Clean up

```bash
make clean         # remove built images locally
make clean-cache   # drop the registry cache images
```

## What next?

- [README.md](README.md) is the reference: architecture, how the three
  caches fit together, every bake variable, and troubleshooting
- `.github/workflows/` contains CI, build, and version-check workflows
- `.builders/` holds the node setup: buildkitd config, the memcached
  store deployer, and the optional host-level sccache service
- Zot is not managed here: `systemctl status zot`, `make zot-logs`
