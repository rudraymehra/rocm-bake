#!/bin/bash
# deploy-webdav.sh - Durable sccache object store on SNOC Strix.
#
# Replaces the memcached store. memcached holds everything in RAM and
# has no persistence: a power cycle on Strix wiped the compiler cache
# for the whole fleet. extstore did not help — it is an overflow tier,
# not durable storage, and memcached never reads it back at startup.
#
# WebDAV rather than S3/MinIO: dl.min.io is blocked by the corporate
# proxy and MinIO is not packaged, whereas nginx with the dav modules
# is a normal apt install. sccache speaks WebDAV natively via
# SCCACHE_WEBDAV_ENDPOINT.
#
# Usage: sudo ./deploy-webdav.sh [port]
#
# Storage is a plain directory tree, so it survives reboots, can be
# backed up with rsync, and is bounded only by the filesystem.

set -euo pipefail

PORT="${1:-8081}"
DATA_DIR=/var/cache/sccache-webdav
SITE=/etc/nginx/sites-available/sccache-webdav

echo "=== sccache WebDAV store deployer ==="
echo "Port:    ${PORT}"
echo "Storage: ${DATA_DIR}"

if [[ $EUID -ne 0 ]]; then
   echo "❌ This script must be run as root (sudo)"
   exit 1
fi

echo "📦 Installing nginx with the DAV modules..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq nginx-extras > /dev/null

TAILNET_IP=$(tailscale ip -4 2>/dev/null | head -1)
if [ -z "${TAILNET_IP}" ]; then
    echo "❌ No tailnet address; the other build nodes could not reach this."
    exit 1
fi
echo "🔗 Binding to 127.0.0.1 and ${TAILNET_IP}"

install -d -o www-data -g www-data -m 755 "${DATA_DIR}"

# nginx binds the tailnet address explicitly, to keep the store off the
# public interface. But at boot nginx starts before tailscaled has
# assigned that address, and bind() fails with EADDRNOTAVAIL — the
# service then stays down until someone restarts it by hand, which is
# how a reboot took the fleet's cache offline while the data itself was
# perfectly intact. Two independent guards, because either alone has a
# race: allow binding an address that does not exist yet, and order the
# unit after tailscaled so it usually does.
echo "🔧 Making the tailnet bind survive a reboot..."
cat > /etc/sysctl.d/99-sccache-webdav.conf << 'EOF'
# Lets nginx bind the tailnet address before tailscaled brings it up.
net.ipv4.ip_nonlocal_bind = 1
EOF
sysctl -q -p /etc/sysctl.d/99-sccache-webdav.conf

install -d -m 755 /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/10-tailscale.conf << 'EOF'
# Managed by .builders/deploy-webdav.sh
[Unit]
After=tailscaled.service network-online.target
Wants=network-online.target
EOF
systemctl daemon-reload

cat > "${SITE}" << EOF
# Managed by .builders/deploy-webdav.sh — edits here are overwritten.
#
# sccache PUTs objects under a key prefix and GETs them back. It does
# not need the full DAV verb set, but create_full_put_path is essential:
# keys are nested (ab/cd/<hash>) and sccache does not MKCOL first.
server {
    listen ${TAILNET_IP}:${PORT};
    listen 127.0.0.1:${PORT};
    server_name _;

    root ${DATA_DIR};

    # Compiler objects are large and sccache streams them in one PUT.
    client_max_body_size 0;
    client_body_timeout 300s;
    send_timeout 300s;

    dav_methods PUT DELETE MKCOL COPY MOVE;
    dav_ext_methods PROPFIND OPTIONS;
    create_full_put_path on;
    dav_access user:rw group:rw all:r;

    # Access control is the tailnet, as with Zot and the old memcached.
    # Do not add a public interface to the listen lines above.
    autoindex on;
}
EOF

ln -sf "${SITE}" /etc/nginx/sites-enabled/sccache-webdav
rm -f /etc/nginx/sites-enabled/default

echo "🔧 Checking nginx config..."
nginx -t

echo "🚀 Restarting nginx..."
systemctl enable nginx > /dev/null 2>&1
systemctl restart nginx

sleep 2
if ! systemctl is-active --quiet nginx; then
    echo "❌ nginx failed to start: journalctl -u nginx -n 50"
    exit 1
fi

echo "🧪 Round-tripping a test object..."
probe="http://${TAILNET_IP}:${PORT}/.probe/test"
if curl -fsS -T /etc/hostname "${probe}" > /dev/null 2>&1 \
   && curl -fsS "${probe}" > /dev/null 2>&1; then
    curl -fsS -X DELETE "${probe}" > /dev/null 2>&1 || true
    echo "✅ PUT and GET both work"
else
    echo "❌ WebDAV round-trip failed; check nginx error log"
    exit 1
fi

echo ""
echo "=== Deployment Complete ==="
echo "Store:   http://${TAILNET_IP}:${PORT}"
echo "Data:    ${DATA_DIR} (durable; survives reboot)"
echo ""
echo "Builds use it via SCCACHE_WEBDAV_ENDPOINT, already the default in"
echo "bake.hcl. Inspect it with: make cache-stats"
