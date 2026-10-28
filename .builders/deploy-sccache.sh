#!/bin/bash
# deploy-sccache.sh - Deploy sccache server on SNOC Strix or Think build machines
# Usage: ./deploy-sccache.sh [strix|think] [version] [cache-size] [port]
#
# This script:
#   1. Downloads the sccache binary from Mozilla releases
#   2. Installs it to /usr/local/bin/sccache
#   3. Creates a systemd service to run the server
#   4. Configures the cache directory with appropriate size
#   5. Starts the sccache server
#
# Examples:
#   ./deploy-sccache.sh strix                   # Strix, defaults (0.19.0, 200G, port 4226)
#   ./deploy-sccache.sh think 0.19.0            # a specific version
#   ./deploy-sccache.sh strix 0.19.0 500G 4226  # custom cache size and port

set -euo pipefail

MACHINE="${1:-strix}"
VERSION="${2:-0.19.0}"
CACHE_SIZE="${3:-200G}"   # retained for the usage string; unused with WebDAV
SCCACHE_WEBDAV_ENDPOINT="${SCCACHE_WEBDAV_ENDPOINT:-http://snoc-strix.fold-leaffish.ts.net:8081}"
# sccache's own default. Port 9000 is taken by lemond/tailscaled on Strix.
SERVER_PORT="${4:-4226}"
TARGET_DIR="/usr/local/bin"

echo "=== sccache Deployer for ${MACHINE^^} ==="
echo "Version: ${VERSION}"
echo "Backend:    ${SCCACHE_WEBDAV_ENDPOINT}"
echo "Port: ${SERVER_PORT}"
echo "Machine: ${MACHINE}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (sudo)"
   exit 1
fi

# Create cache directory
echo "📁 Creating sccache cache directory..."
mkdir -p /var/cache/sccache
chmod 1777 /var/cache/sccache

# Create log directory
echo "📝 Creating sccache log directory..."
mkdir -p /var/log/sccache
touch /var/log/sccache/sccache.log
chmod 644 /var/log/sccache/sccache.log

# Download sccache binary
echo "⬇️  Downloading sccache v${VERSION}..."
ARCH=$(dpkg --print-architecture)
curl -fsSL "https://github.com/mozilla/sccache/releases/download/v${VERSION}/sccache-v${VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    -o "/tmp/sccache-${VERSION}.tar.gz"

echo "📦 Installing sccache to ${TARGET_DIR}..."
mkdir -p "${TARGET_DIR}"
tar xzf "/tmp/sccache-${VERSION}.tar.gz" -C "${TARGET_DIR}" --strip-components=1 "sccache-v${VERSION}-x86_64-unknown-linux-musl/sccache"
rm "/tmp/sccache-${VERSION}.tar.gz"
chmod +x "${TARGET_DIR}/sccache"

echo "✅ sccache installed: $(${TARGET_DIR}/sccache --version)"

# Create systemd service
echo "🔧 Creating systemd service..."
cat > /etc/systemd/system/sccache.service << EOF
[Unit]
Description=sccache compiler cache server for ROCm/PyTorch builds
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root

# sccache has no CLI flags for the backend or logging — all
# configuration is via the environment.
#
# The shared WebDAV store, not SCCACHE_DIR. A local disk cache here
# would be a second, disconnected store: anything compiled on this host
# would miss everything the build containers have produced, and vice
# versa. Pointing at the same endpoint the containers use makes
# host-side compiles share one cache with the whole fleet.
Environment=SCCACHE_WEBDAV_ENDPOINT=${SCCACHE_WEBDAV_ENDPOINT}
Environment=SCCACHE_SERVER_PORT=${SERVER_PORT}
Environment=SCCACHE_ERROR_LOG=/var/log/sccache/sccache.log
Environment=SCCACHE_LOG=info
# Without this the server exits after 10 minutes idle and systemd restarts it
Environment=SCCACHE_IDLE_TIMEOUT=0
# Run the server in the foreground so systemd can supervise it. These two
# reject any other sccache subcommand, so there can be no ExecStartPre
# --stop-server here; systemd owns the process lifecycle instead.
Environment=SCCACHE_START_SERVER=1
Environment=SCCACHE_NO_DAEMON=1

ExecStart=${TARGET_DIR}/sccache

# Restart on failure
Restart=on-failure
RestartSec=5

# Resource limits
MemoryMax=4G
CPUQuota=200%

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/cache/sccache /var/log/sccache /tmp
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
echo "🚀 Enabling and starting sccache service..."
systemctl daemon-reload
systemctl enable sccache
systemctl restart sccache

# Verify the service is running
echo "⏳ Waiting for sccache server to start..."
sleep 3

if systemctl is-active --quiet sccache; then
    echo "✅ sccache server is running on ${MACHINE}"
    echo "📊 Cache stats:"
    SCCACHE_SERVER_PORT="${SERVER_PORT}" ${TARGET_DIR}/sccache --show-stats
else
    echo "❌ sccache failed to start. Check logs:"
    echo "   journalctl -u sccache.service -n 50"
    echo "   cat /var/log/sccache/sccache.log"
    exit 1
fi

echo ""
echo "=== Deployment Complete ==="
echo "Server is running on port ${SERVER_PORT}"
echo "Backend:   ${SCCACHE_WEBDAV_ENDPOINT} (shared with every build container)"
echo "Logs: /var/log/sccache/sccache.log"
echo ""
echo "To verify from a build machine:"
echo "  SCCACHE_SERVER_PORT=${SERVER_PORT} sccache --show-stats"
echo ""
echo "To deploy from remote:"
echo "  ssh root@${MACHINE} './deploy-sccache.sh ${MACHINE} ${VERSION} ${CACHE_SIZE} ${SERVER_PORT}'"
