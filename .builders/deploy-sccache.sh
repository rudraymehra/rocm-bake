#!/bin/bash
# deploy-sccache.sh - Deploy sccache server on SNOC Strix or Think build machines
# Usage: ./deploy-sccache.sh [strix|think] [version]
#
# This script:
#   1. Downloads the sccache binary from Mozilla releases
#   2. Installs it to /usr/local/bin/sccache
#   3. Creates a systemd service to run the server
#   4. Configures the cache directory with appropriate size
#   5. Starts the sccache server
#
# Examples:
#   ./deploy-sccache.sh strix          # Deploy on Strix (default, 200G cache)
#   ./deploy-sccache.sh think 0.7.7   # Deploy on Think with specific version
#   ./deploy-sccache.sh strix 200     # Deploy on Strix with custom cache size

set -euo pipefail

MACHINE="${1:-strix}"
VERSION="${2:-0.7.7}"
CACHE_SIZE="${3:-200G}"
TARGET_DIR="/usr/local/bin"

echo "=== sccache Deployer for ${MACHINE^^} ==="
echo "Version: ${VERSION}"
echo "Cache Size: ${CACHE_SIZE}"
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
Type=forking
User=root
Group=root

# Start the server
ExecStartPre=-${TARGET_DIR}/sccache --stop-server
ExecStart=${TARGET_DIR}/sccache --start-server \
    --cache-size=${CACHE_SIZE}

# Restart on failure
Restart=on-failure
RestartSec=5

# sccache doesn't fork in 0.7.7+
Type=simple
NotifyAccess=main

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
    ${TARGET_DIR}/sccache --show-stats
else
    echo "❌ sccache failed to start. Check logs:"
    echo "   journalctl -u sccache.service -n 50"
    echo "   cat /var/log/sccache/sccache.log"
    exit 1
fi

echo ""
echo "=== Deployment Complete ==="
echo "Server is running on port 9000"
echo "Cache directory: /var/cache/sccache (${CACHE_SIZE})"
echo "Logs: /var/log/sccache/sccache.log"
echo ""
echo "To verify from a build machine:"
echo "  SCCACHE_ADDR=localhost:9000 sccache --show-stats"
echo ""
echo "To deploy from remote:"
echo "  ssh root@${MACHINE} './deploy-sccache.sh ${MACHINE} ${VERSION} ${CACHE_SIZE}'"
