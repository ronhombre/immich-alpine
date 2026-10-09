#!/bin/bash
set -Eeuo pipefail
umask 077

# Usage: install-immich-alpine-improved.sh <release-tag> [owner/repo]
RELEASE_TAG="${1:-}"
GITHUB_REPO="${2:-ronhombre/immich-alpine}"
ASSET_NAME="immich-alpine-3.24.tar.gz"
IMMICH_PATH="/var/lib/immich"
IMMICH_LOG_PATH="/var/log/immich"
VERSION_FILE="$IMMICH_PATH/.immich-version"
BACKUP_ROOT="$IMMICH_PATH/backups"
PENDING_FILE="$IMMICH_PATH/.upgrade-pending"
HEALTH_URL="${IMMICH_HEALTH_URL:-http://127.0.0.1:2283/api/server/ping}"
HEALTH_RETRIES="${IMMICH_HEALTH_RETRIES:-30}"

[[ $EUID -eq 0 ]] || { echo 'ERROR: Run as root.' >&2; exit 1; }
[[ -n "$RELEASE_TAG" ]] || { echo "Usage: $0 <release-tag> [owner/repo]" >&2; exit 1; }
[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { echo 'ERROR: Unsafe release tag.' >&2; exit 1; }
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'ERROR: Expected owner/repo.' >&2; exit 1; }
[[ "$HEALTH_RETRIES" =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: HEALTH_RETRIES must be positive.' >&2; exit 1; }

TMP_DIR=""
NEXT_APP=""
BACKUP_DIR=""
ATTEMPT_ACTIVE=0
UPGRADE_COMPLETE=0

utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log_attempt() {
    local result="$1"
    [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/backup.complete" ]] || return 0
    printf '%s\tfrom=%s\tto=%s\tresult=%s\n' \
        "$(utc_now)" "$SOURCE_VERSION" "$RELEASE_TAG" "$result" >> "$BACKUP_DIR/attempts.log"
}
cleanup() {
    local status=$?
    trap - EXIT
    if (( status != 0 && ATTEMPT_ACTIVE && ! UPGRADE_COMPLETE )); then
        log_attempt failed || true
        echo "ERROR: Upgrade to $RELEASE_TAG failed. The completed backup was kept at: $BACKUP_DIR" >&2
        echo "ERROR: Pending-upgrade state was kept so the next attempt can reuse it." >&2
    fi
    [[ -z "$NEXT_APP" ]] || rm -rf -- "$NEXT_APP"
    [[ -z "$TMP_DIR" ]] || rm -rf -- "$TMP_DIR"
    exit "$status"
}
trap cleanup EXIT

# Only backups with an explicit completion marker are reusable. Legacy and
# incomplete backups will not be selected or removed automatically.
valid_backup() {
    local dir="$1" expected="$2" saved=""
    [[ -d "$dir/app" && -f "$dir/backup.complete" && -f "$dir/source.version" ]] || return 1
    IFS= read -r saved < "$dir/source.version" || [[ -n "$saved" ]]
    [[ "$saved" == "$expected" ]]
}

find_backup() {
    local expected="$1" dir
    local selected=""
    for dir in "$BACKUP_ROOT"/*; do
        [[ -d "$dir" ]] || continue
        if valid_backup "$dir" "$expected"; then
            # Timestamp-prefixed backup names sort in chronological order.
            [[ -z "$selected" || "$dir" > "$selected" ]] && selected="$dir"
        fi
    done
    printf '%s' "$selected"
}

# Keep just the backup used to upgrade the previous version successfully.
# NEVER remove unmarked/legacy/incomplete backup directories.
prune_backups() {
    local dir
    for dir in "$BACKUP_ROOT"/*; do
        [[ -d "$dir" && "$dir" != "$BACKUP_DIR" ]] || continue
        [[ -f "$dir/backup.complete" && -f "$dir/source.version" && -d "$dir/app" ]] || continue
        echo "Pruning superseded completed backup: $dir"
        rm -rf -- "$dir" || echo "WARNING: Could not remove $dir" >&2
    done
}

# --- Install runtime dependencies ---
echo 'Installing runtime dependencies...'
apk update
apk add --no-cache \
    perl perl-compress-raw-zlib perl-compress-raw-bzip2 \
    nodejs ffmpeg7 abseil-cpp abseil-cpp-flags-marshalling \
    vips vips-cpp vips-jxl libraw \
    python3 py3-opencv py3-onnxruntime py3-yaml py3-shapely \
    postgresql-client util-linux lcms2 mesa-gl geos bash curl

# Prevent two installers from replacing the same application at once.
exec 9> /run/immich-alpine-install.lock
flock -n 9 || { echo 'ERROR: Another Immich installer is already running.' >&2; exit 1; }

mkdir -p "$IMMICH_PATH" "$IMMICH_LOG_PATH" "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
if ! getent group immich >/dev/null 2>&1; then addgroup -S immich; fi
if ! id immich >/dev/null 2>&1; then
    adduser -S -h "$IMMICH_PATH/home" -s /sbin/nologin -D -G immich immich
fi
chown immich:immich "$IMMICH_PATH"
chown -R immich:immich "$IMMICH_LOG_PATH"
chmod 700 "$IMMICH_PATH"

IS_UPGRADE=0
[[ -d "$IMMICH_PATH/app" ]] && IS_UPGRADE=1
SOURCE_VERSION=""
if [[ -f "$VERSION_FILE" ]]; then
    IFS= read -r SOURCE_VERSION < "$VERSION_FILE" || [[ -n "$SOURCE_VERSION" ]]
fi
if (( IS_UPGRADE )) && [[ -z "$SOURCE_VERSION" && ! -f "$PENDING_FILE" ]]; then
    echo "ERROR: Existing app has no $VERSION_FILE; cannot safely deduplicate backups." >&2
    echo 'Identify its source version first; do not guess.' >&2
    exit 1
fi

# If a prior attempt was interrupted after replacing app/, use the original
# source version and its backup rather than making a new backup of the new files.
if [[ -f "$PENDING_FILE" ]]; then
    mapfile -t pending < "$PENDING_FILE"
    (( ${#pending[@]} == 4 )) || { echo 'ERROR: Invalid pending-upgrade record.' >&2; exit 1; }
    pending_from="${pending[0]}"
    pending_backup="${pending[1]}"
    pending_to="${pending[2]}"
    pending_attempt="${pending[3]}"
    case "$pending_backup" in
        "$BACKUP_ROOT"/*) ;;
        *) echo 'ERROR: Pending backup is outside the backup directory.' >&2; exit 1 ;;
    esac
    valid_backup "$pending_backup" "$pending_from" || {
        echo 'ERROR: Pending source backup missing/incomplete. Refusing to overwrite anything.' >&2
        exit 1
    }
    # A crash may have occurred AFTER committing the version and success marker.
    if [[ "$SOURCE_VERSION" == "$pending_to" && -f "$pending_backup/upgrade.success" ]] && \
       grep -Fq "$(printf '%s\t%s\t' "$pending_to" "$pending_attempt")" "$pending_backup/upgrade.success"; then
        echo 'Finishing metadata cleanup from the previous successful run.'
        BACKUP_DIR="$pending_backup"
        rm -rf -- "$IMMICH_PATH/.app-previous"
        prune_backups
        rm -f "$PENDING_FILE"
        BACKUP_DIR=""
    else
        # A crash between renaming the old app and installing the new app
        # can temporarily leave app/ absent. The completed backup is authoritative.
        IS_UPGRADE=1
        SOURCE_VERSION="$pending_from"
        BACKUP_DIR="$pending_backup"
        echo "Unfinished upgrade detected: original $SOURCE_VERSION (backup: $BACKUP_DIR)"
    fi
fi

# An already committed version needs no upgrade. This is deliberately not a
# repair mode: treating it as an upgrade could prune the previous backup.
if (( IS_UPGRADE )) && [[ -z "$BACKUP_DIR" && "$SOURCE_VERSION" == "$RELEASE_TAG" ]]; then
    echo "$RELEASE_TAG is already recorded as installed; no changes made."
    exit 0
fi

# --- Fetch and validate release BEFORE stopping the running services ---
TMP_DIR=$(mktemp -d)
mkdir -p "$TMP_DIR/staging"
ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
echo "Downloading $ASSET_URL ..."
curl --fail --location --retry 3 --output "$TMP_DIR/release.tar.gz" "$ASSET_URL"
tar -xzf "$TMP_DIR/release.tar.gz" -C "$TMP_DIR/staging"
STAGING_APP="$TMP_DIR/staging/var/lib/immich/app"
[[ -d "$STAGING_APP" && -f "$STAGING_APP/start.sh" && -f "$STAGING_APP/machine-learning/start.sh" ]] || {
    echo 'ERROR: Release archive is missing expected app/start.sh files.' >&2
    exit 1
}

# Prepare replacement app fully before switching directories.
NEXT_APP="$IMMICH_PATH/.app-next-$$"
cp -a "$STAGING_APP" "$NEXT_APP"
chown -R immich:immich "$NEXT_APP"

if (( IS_UPGRADE )); then
    echo "Upgrading $SOURCE_VERSION -> $RELEASE_TAG"
    # Stop before taking the first copy to avoid backing up changing files.
    rc-service immich stop 2>/dev/null || true
    rc-service immich-ml stop 2>/dev/null || true
    if rc-service immich status >/dev/null 2>&1 || rc-service immich-ml status >/dev/null 2>&1; then
        echo 'ERROR: An Immich service is still running; refusing to replace files.' >&2
        exit 1
    fi

    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR=$(find_backup "$SOURCE_VERSION")
        if [[ -n "$BACKUP_DIR" ]]; then
            echo "Reusing completed $SOURCE_VERSION backup: $BACKUP_DIR"
        else
            BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
            mkdir -m 700 -- "$BACKUP_DIR"
            printf '%s\n' "$SOURCE_VERSION" > "$BACKUP_DIR/source.version"
            printf '%s\n' "$RELEASE_TAG" > "$BACKUP_DIR/first-target.version"
            cp -a "$IMMICH_PATH/app" "$BACKUP_DIR/app"
            if [[ -f "$IMMICH_PATH/env" ]]; then cp -a "$IMMICH_PATH/env" "$BACKUP_DIR/env"; fi
            [[ -d "$BACKUP_DIR/app" && -f "$BACKUP_DIR/app/start.sh" ]] || {
                echo 'ERROR: App backup is incomplete.' >&2; exit 1;
            }
            # Atomic sentinel: only published AFTER every copy succeeds.
            printf 'completed_at=%s\n' "$(utc_now)" > "$BACKUP_DIR/.backup.complete.tmp"
            mv "$BACKUP_DIR/.backup.complete.tmp" "$BACKUP_DIR/backup.complete"
            echo "Completed $SOURCE_VERSION backup: $BACKUP_DIR"
        fi
    else
        echo "Reusing pending source backup: $BACKUP_DIR"
    fi

    # Record the next attempt before touching app/. The version file will not
    # advance until BOTH OpenRC and the HTTP check succeed.
    ATTEMPT_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    printf '%s\n%s\n%s\n%s\n' "$SOURCE_VERSION" "$BACKUP_DIR" "$RELEASE_TAG" "$ATTEMPT_ID" > "$PENDING_FILE.tmp.$$"
    mv "$PENDING_FILE.tmp.$$" "$PENDING_FILE"
    log_attempt started
    ATTEMPT_ACTIVE=1
fi

# Keep one local previous-app directory across retries. The durable rollback
# copy is in backups/, and a failed retry must not overwrite that snapshot.
PREVIOUS_APP="$IMMICH_PATH/.app-previous"
if (( IS_UPGRADE )); then
    if [[ -e "$PREVIOUS_APP" ]]; then
        # Only an interrupted, tracked upgrade may have left this directory.
        [[ -f "$PENDING_FILE" ]] || {
            echo "ERROR: $PREVIOUS_APP exists but no upgrade is pending." >&2
            exit 1
        }
        [[ -d "$IMMICH_PATH/app" ]] && rm -rf -- "$IMMICH_PATH/app"
    else
        [[ -d "$IMMICH_PATH/app" ]] || {
            echo 'ERROR: No app to replace and no previous-app directory.' >&2
            exit 1
        }
        mv "$IMMICH_PATH/app" "$PREVIOUS_APP"
    fi
elif [[ -e "$PREVIOUS_APP" ]]; then
    echo "ERROR: Stale $PREVIOUS_APP exists. Resolve it before a fresh install." >&2
    exit 1
fi
mv "$NEXT_APP" "$IMMICH_PATH/app"
NEXT_APP=""

# --- Create env only when absent; preserve existing credentials ---
if [[ ! -f "$IMMICH_PATH/env" ]]; then
    cat > "$IMMICH_PATH/env" <<'ENV'
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

NODE_OPTIONS="--max-old-space-size=512"
ENV
    chown immich:immich "$IMMICH_PATH/env"
    chmod 600 "$IMMICH_PATH/env"
    echo "Created $IMMICH_PATH/env; Please edit DB/Redis credentials before starting."
fi

# --- Install OpenRC scripts atomically ---
cat > "/etc/init.d/.immich.new.$$" <<'OPENRC'
#!/sbin/openrc-run
name="immich"
description="Immich Server"
command="/var/lib/immich/app/start.sh"
command_user="immich:immich"
command_background="yes"
stopgroup="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/immich/immich.log"
error_log="/var/log/immich/immich.err"
depend() {
    need localmount
    need immich-ml
    after firewall
}
OPENRC
cat > "/etc/init.d/.immich-ml.new.$$" <<'OPENRC'
#!/sbin/openrc-run
name="immich-ml"
description="Immich Machine Learning"
command="/var/lib/immich/app/machine-learning/start.sh"
command_user="immich:immich"
command_background="yes"
stopgroup="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/immich/immich-ml.log"
error_log="/var/log/immich/immich-ml.err"
depend() {
    need localmount
    after firewall
}
OPENRC
chmod 755 "/etc/init.d/.immich.new.$$" "/etc/init.d/.immich-ml.new.$$"
mv "/etc/init.d/.immich.new.$$" /etc/init.d/immich
mv "/etc/init.d/.immich-ml.new.$$" /etc/init.d/immich-ml
rc-update add immich default
rc-update add immich-ml default

if (( IS_UPGRADE )); then
    echo 'Starting upgraded Immich services...'
    # Do not let daemon processes inherit the installer lock file descriptor.
    rc-service immich-ml start 9>&-
    rc-service immich start 9>&-
    echo "Waiting for $HEALTH_URL to respond..."
    healthy=0
    for (( i=0; i<HEALTH_RETRIES; i++ )); do
        if rc-service immich-ml status >/dev/null 2>&1 && \
           rc-service immich status >/dev/null 2>&1 && \
           curl --silent --show-error --fail --max-time 3 --output /dev/null "$HEALTH_URL" 2>/dev/null; then
            healthy=1
            break
        fi
        sleep 2
    done
    (( healthy )) || { echo 'ERROR: Health check failed. Backup and pending state preserved. Please try again.' >&2; exit 1; }

    # Commit the new version ONLY after verifying the upgraded services.
    printf '%s\n' "$RELEASE_TAG" > "$VERSION_FILE.tmp.$$"
    chown immich:immich "$VERSION_FILE.tmp.$$"
    mv "$VERSION_FILE.tmp.$$" "$VERSION_FILE"
    printf '%s\t%s\t%s\n' "$RELEASE_TAG" "$ATTEMPT_ID" "$(utc_now)" >> "$BACKUP_DIR/upgrade.success"
    log_attempt succeeded
    UPGRADE_COMPLETE=1
    ATTEMPT_ACTIVE=0
    rm -rf -- "$PREVIOUS_APP"
    rm -f "$PENDING_FILE"
    prune_backups
    echo "Upgrade complete: $SOURCE_VERSION -> $RELEASE_TAG"
    echo "Retained source backup: $BACKUP_DIR"
else
    printf '%s\n' "$RELEASE_TAG" > "$VERSION_FILE"
    chown immich:immich "$VERSION_FILE"
    echo 'Installation complete. Configure /var/lib/immich/env, then run:'
    echo '  rc-service immich-ml start'
    echo '  rc-service immich start'
fi
