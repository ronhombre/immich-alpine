#!/bin/bash
# install-immich-alpine.sh
set -euo pipefail

# --- Configuration ---
RELEASE_TAG="${1:-}"
GITHUB_REPO="${2:-ronhombre/immich-alpine}"
ASSET_NAME="immich-alpine-3.24.tar.gz"
IMMICH_PATH=/var/lib/immich

if [[ -z "$RELEASE_TAG" ]]; then
    echo "Usage: $0 <release-tag> [owner/repo]"
    echo "Example: $0 v3.2.0 ronhombre/immich-alpine"
    exit 1
fi

# --- Install runtime dependencies ---
echo "Installing runtime dependencies..."
apk update
apk add --no-cache \
    nodejs \
    ffmpeg7 \
    abseil-cpp abseil-cpp-flags-marshalling \
    vips vips-cpp vips-jxl \
    libraw \
    python3 py3-opencv py3-onnxruntime \
    py3-yaml py3-shapely \
    postgresql-client \
    util-linux \
    lcms2 \
    mesa-gl \
    geos \
    bash \
    curl

# --- Create immich user and directories ---
mkdir -p /var/lib/immich /var/log/immich
if ! getent group immich >/dev/null 2>&1; then
    addgroup -S immich
fi
if ! id immich &>/dev/null; then
    adduser -S -h /var/lib/immich/home -s /sbin/nologin -D immich
fi
chown immich:immich /var/lib/immich /var/log/immich
chmod 700 /var/lib/immich

# --- Download and extract the release asset ---
ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
echo "Downloading ${ASSET_URL} ..."
TMP_TAR=$(mktemp)
curl -L -o "$TMP_TAR" "$ASSET_URL"

echo "Extracting..."
tar -xzf "$TMP_TAR" -C /
rm -f "$TMP_TAR"

chown -R immich:immich /var/lib/immich /var/log/immich

# --- Create env file if it does not exist ---
if [[ ! -f /var/lib/immich/env ]]; then
    cat > /var/lib/immich/env <<'EOF'
# --- Immich server ---
IMMICH_HOST=127.0.0.1
IMMICH_PORT=2283

# --- Database (external) ---
DB_HOSTNAME=your-postgres-host
DB_PORT=5432
DB_USERNAME=immich
DB_PASSWORD=YOUR_STRONG_RANDOM_PW
DB_DATABASE_NAME=immich

# --- Redis (external) ---
REDIS_HOSTNAME=your-redis-host
REDIS_PORT=6379
REDIS_PASSWORD=your-redis-password

# --- Machine learning ---
MACHINE_LEARNING_HOST=127.0.0.1
MACHINE_LEARNING_PORT=3003
MACHINE_LEARNING_WORKERS=1
MACHINE_LEARNING_WORKER_TIMEOUT=300
MACHINE_LEARNING_CACHE_FOLDER=/var/lib/immich/cache
TRANSFORMERS_CACHE=/var/lib/immich/cache
HF_HOME=/var/lib/immich/cache/hf-cache

# --- Node.js memory tuning for low‑memory target ---
NODE_OPTIONS=--max-old-space-size=512
EOF
    chown immich:immich /var/lib/immich/env
    chmod 600 /var/lib/immich/env
    echo "Created /var/lib/immich/env — edit it with your external DB/Redis credentials."
fi

# --- Install OpenRC services (same as before) ---
cat > /etc/init.d/immich <<'EOF'
#!/sbin/openrc-run

name="immich"
description="Immich Server"

command="/var/lib/immich/app/start.sh"
command_user="immich"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

output_log="/var/log/immich/immich.log"
error_log="/var/log/immich/immich.err"

depend() {
    need localmount
    after firewall
}
EOF

cat > /etc/init.d/immich-ml <<'EOF'
#!/sbin/openrc-run

name="immich-ml"
description="Immich Machine Learning"

command="/var/lib/immich/app/machine-learning/start.sh"
command_user="immich"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

output_log="/var/log/immich/immich-ml.log"
error_log="/var/log/immich/immich-ml.err"

depend() {
    need localmount
    after firewall
}
EOF

chmod +x /etc/init.d/immich /etc/init.d/immich-ml
rc-update add immich default
rc-update add immich-ml default

echo
echo "Installation complete."
echo "Edit /var/lib/immich/env with your external PostgreSQL and Redis credentials."
echo "Then start the services:"
echo "  rc-service immich-ml start"
echo "  rc-service immich start"