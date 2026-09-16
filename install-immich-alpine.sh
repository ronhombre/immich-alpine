#!/bin/bash
set -euo pipefail

# --- Configuration ---
RELEASE_TAG="${1:-}"
GITHUB_REPO="${2:-ronhombre/immich-alpine}"
ASSET_NAME="immich-alpine-3.24.tar.gz"
IMMICH_PATH=/var/lib/immich
IMMICH_LOG_PATH=/var/log/immich

if [[ -z "$RELEASE_TAG" ]]; then
    echo "Usage: $0 <release-tag> [owner/repo]"
    echo "Example: $0 v3.2.0 ronhombre/immich-alpine"
    exit 1
fi

# --- Install runtime dependencies ---
echo "Installing runtime dependencies..."
apk update
apk add --no-cache \
    perl perl-compress-raw-zlib perl-compress-raw-bzip2 \
    nodejs \
    ffmpeg7 \
    abseil-cpp abseil-cpp-flags-marshalling \
    vips vips-cpp vips-jxl \
    libraw \
    python3 py3-opencv py3-onnxruntime py3-yaml py3-shapely \
    postgresql-client \
    util-linux \
    lcms2 \
    mesa-gl \
    geos \
    bash \
    curl

# --- Create immich user and directories ---
mkdir -p "$IMMICH_PATH" "$IMMICH_LOG_PATH"
if ! getent group immich >/dev/null 2>&1; then
    addgroup -S immich
fi
if ! id immich &>/dev/null; then
    adduser -S -h "$IMMICH_PATH/home" -s /sbin/nologin -D immich
fi
chown immich:immich "$IMMICH_PATH" "$IMMICH_LOG_PATH"
chmod 700 "$IMMICH_PATH"

# --- Download and extract the release asset ---
ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
echo "Downloading ${ASSET_URL} ..."
TMP_TAR=$(mktemp)
curl -L -o "$TMP_TAR" "$ASSET_URL"

echo "Extracting..."
tar -xzf "$TMP_TAR" -C /
rm -f "$TMP_TAR"

chown -R immich:immich "$IMMICH_PATH" "$IMMICH_LOG_PATH"

# --- Create env file if it does not exist ---
if [[ ! -f $IMMICH_PATH/env ]]; then
    cat > "$IMMICH_PATH/env" <<EOF
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
MACHINE_LEARNING_CACHE_FOLDER=$IMMICH_PATH/cache
TRANSFORMERS_CACHE=$IMMICH_PATH/cache
HF_HOME=$IMMICH_PATH/cache/hf-cache

# I suggest getting an HF_TOKEN to improve the speed it downloads the ML models.

# --- Node.js memory tuning for low-memory target ---
NODE_OPTIONS="--max-old-space-size=512"
EOF
    chown immich:immich "$IMMICH_PATH/env"
    chmod 600 "$IMMICH_PATH/env"
    echo "Created $IMMICH_PATH/env — edit it with your external DB/Redis credentials."
fi

# --- Install OpenRC services ---
cat > /etc/init.d/immich <<EOF
#!/sbin/openrc-run

name="immich"
description="Immich Server"

command="$IMMICH_PATH/app/start.sh"
command_user="immich"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

output_log="$IMMICH_LOG_PATH/immich.log"
error_log="$IMMICH_LOG_PATH/immich.err"

depend() {
    need localmount
    need immich-ml
    after firewall
}
EOF

cat > /etc/init.d/immich-ml <<EOF
#!/sbin/openrc-run

name="immich-ml"
description="Immich Machine Learning"

command="$IMMICH_PATH/app/machine-learning/start.sh"
command_user="immich"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

output_log="$IMMICH_LOG_PATH/immich-ml.log"
error_log="$IMMICH_LOG_PATH/immich-ml.err"

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
echo "Edit $IMMICH_PATH/env with your external PostgreSQL and Redis credentials."
echo "Then start the services:"
echo "  rc-service immich-ml start"
echo "  rc-service immich start"