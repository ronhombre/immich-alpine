#!/bin/bash
set -euo pipefail

# --- Configuration ---
RELEASE_TAG="${1:-}"
GITHUB_REPO="${2:-ronhombre/immich-alpine}"
ASSET_NAME="immich-alpine-3.24.tar.gz"
IMMICH_PATH=/var/lib/immich
IMMICH_LOG_PATH=/var/log/immich
VERSION_FILE="$IMMICH_PATH/.immich-version"

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

# --- Detect existing install ---
IS_UPGRADE=0
if [[ -d "$IMMICH_PATH/app" ]]; then
    IS_UPGRADE=1
fi

# --- Download release to staging ---
ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
echo "Downloading ${ASSET_URL} ..."
TMP_TAR=$(mktemp)
curl -L -o "$TMP_TAR" "$ASSET_URL"

echo "Extracting to staging..."
STAGING_DIR=$(mktemp -d)
tar -xzf "$TMP_TAR" -C "$STAGING_DIR"
rm -f "$TMP_TAR"

STAGING_APP="$STAGING_DIR/var/lib/immich/app"
if [[ ! -d "$STAGING_APP" ]]; then
    echo "ERROR: Release archive does not contain var/lib/immich/app" >&2
    rm -rf "$STAGING_DIR"
    exit 1
fi

# --- Stop services and backup on upgrade ---
if [[ "$IS_UPGRADE" -eq 1 ]]; then
    echo "Existing installation detected. Preparing upgrade..."
    rc-service immich stop 2>/dev/null || true
    rc-service immich-ml stop 2>/dev/null || true

    BACKUP_DIR="$IMMICH_PATH/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    if [[ -f "$IMMICH_PATH/env" ]]; then
        cp -a "$IMMICH_PATH/env" "$BACKUP_DIR/env"
    fi
    if [[ -d "$IMMICH_PATH/app" ]]; then
        cp -a "$IMMICH_PATH/app" "$BACKUP_DIR/app"
    fi
    echo "Backup created at $BACKUP_DIR"
fi

# --- Install new app ---
echo "Installing Immich $RELEASE_TAG ..."
rm -rf "$IMMICH_PATH/app"
cp -a "$STAGING_APP" "$IMMICH_PATH/app"
rm -rf "$STAGING_DIR"

chown -R immich:immich "$IMMICH_PATH" "$IMMICH_LOG_PATH"

# --- Create env file if it does not exist ---
if [[ ! -f "$IMMICH_PATH/env" ]]; then
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

# --- Record installed version ---
echo "$RELEASE_TAG" > "$VERSION_FILE"
chown immich:immich "$VERSION_FILE"

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

stop() {
    ebegin "Stopping ${RC_SVCNAME}"

    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile")

        # Signal the ENTIRE process group, not just the leader.
        kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null

        local i=0
        while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            i=$((i + 1))
        done

        kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null

        rm -f "$pidfile"
    fi

    pkill -u immich -f 'immich-api' 2>/dev/null || true

    eend 0
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

# --- Start services ---
if [[ "$IS_UPGRADE" -eq 1 ]]; then
    echo "Starting upgraded Immich services..."
    rc-service immich-ml restart
    rc-service immich restart
else
    echo "Installation complete."
    echo "Edit $IMMICH_PATH/env with your external PostgreSQL and Redis credentials."
    echo "Then start the services:"
    echo "  rc-service immich-ml start"
    echo "  rc-service immich start"
fi