#!/bin/bash
# deploy-memcached.sh - Install and configure the shared sccache object
# store on SNOC Strix. Run on Strix only; think and gaming are clients.
#
# Usage: sudo ./deploy-memcached.sh [ram_mb] [disk_size]
#
#   ram_mb      RAM ceiling in MB   (default 8192)
#   disk_size   extstore file size  (default 200G)
#
# This is the single cache all three build nodes share. Each node runs
# its own sccache server — the client/server protocol needs the server
# to see the source tree, so a shared *server* is impossible — and they
# all read and write objects here. An object compiled on Strix is a hit
# on thinkstation and gaming.
#
# memcached is chosen for extstore: above the RAM ceiling item data goes
# to a file on disk, with only keys and pointers kept in memory. That
# tiering is the whole point — a PyTorch object cache outgrows any
# sensible RAM budget, and the alternative stores sccache supports
# either cap hard at memory size or need a separate object server.

set -euo pipefail

RAM_MB="${1:-8192}"
DISK_SIZE="${2:-200G}"
EXT_PATH="/var/lib/memcached/extstore"
DROPIN_DIR="/etc/systemd/system/memcached.service.d"

echo "=== memcached sccache store deployer ==="
echo "RAM ceiling: ${RAM_MB}MB"
echo "Disk tier:   ${EXT_PATH} (${DISK_SIZE})"

if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (sudo)"
   exit 1
fi

echo "📦 Installing memcached..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq memcached > /dev/null

if ! memcached --help 2>&1 | grep -q ext_path; then
    echo "❌ This memcached has no extstore support; the disk tier needs it."
    exit 1
fi

TAILNET_IP=$(tailscale ip -4 2>/dev/null | head -1)
if [ -z "${TAILNET_IP}" ]; then
    echo "❌ No tailnet address; the other build nodes could not reach this."
    exit 1
fi
echo "🔗 Binding to 127.0.0.1 and ${TAILNET_IP}"

install -d -o memcache -g memcache -m 755 "$(dirname "${EXT_PATH}")"

echo "🔧 Writing systemd drop-in..."
mkdir -p "${DROPIN_DIR}"
# Override ExecStart outright rather than going through
# /etc/memcached.conf: the packaged perl wrapper parses that file a line
# at a time and mangles `-o key=value,key=value`.
cat > "${DROPIN_DIR}/override.conf" << EOF
# Managed by .builders/deploy-memcached.sh — edits here are overwritten.
#
# extstore refuses to start unless max-item-size <= ext_wbuf_size, so
# those two move together. 64m covers any object file a compiler
# produces; raising it buys nothing but write-buffer RAM.
[Service]
ExecStart=
ExecStart=/usr/bin/memcached \\
    --memory-limit=${RAM_MB} \\
    --listen=127.0.0.1,${TAILNET_IP} \\
    --port=11211 \\
    --user=memcache \\
    --max-item-size=64m \\
    --disable-evictions \\
    --conn-limit=2048 \\
    --threads=8 \\
    -U 0 \\
    -o ext_path=${EXT_PATH}:${DISK_SIZE} \\
    -o ext_threads=4 \\
    -o ext_wbuf_size=64

# extstore writes through this file; it is the cache, so losing it costs
# a rebuild, not data.
ReadWritePaths=$(dirname "${EXT_PATH}")
EOF

echo "🚀 Restarting memcached..."
systemctl daemon-reload
systemctl enable memcached > /dev/null 2>&1
systemctl restart memcached

sleep 2
if ! systemctl is-active --quiet memcached; then
    echo "❌ memcached failed to start:"
    echo "   journalctl -u memcached -n 50"
    exit 1
fi

echo "✅ memcached is running"
echo "📊 Store in effect:"
printf 'stats settings\r\nquit\r\n' | timeout 5 nc 127.0.0.1 11211 \
    | grep -E 'maxbytes|ext_path|item_size_max|evictions' | sed 's/^/   /'

echo ""
echo "=== Deployment Complete ==="
echo "Store:     memcached://${TAILNET_IP}:11211"
echo "RAM tier:  ${RAM_MB}MB   Disk tier: ${EXT_PATH} (${DISK_SIZE})"
echo ""
echo "Builds use it by default (SCCACHE_MEMCACHED in bake.hcl). Check it"
echo "is being filled with:"
echo "  printf 'stats\\r\\nquit\\r\\n' | nc ${TAILNET_IP} 11211 | grep -E 'get_hits|get_misses|extstore_pages_used'"
