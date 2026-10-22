#!/bin/bash
set -Eeuo pipefail
umask 077

# Usage: install-immich-alpine.sh [--allow-untrusted] [--repository URL] [release-tag|latest] [owner/repo]
# No release argument means the latest published stable GitHub release.
ALLOW_UNTRUSTED="${IMMICH_ALLOW_UNTRUSTED:-0}"
APK_REPOSITORY_ARGS=()
add_runtime_repository() {
    [[ -n "$1" && "$1" != -* && "$1" != *$'\n'* && "$1" != *$'\r'* ]] || {
        echo 'ERROR: --repository requires a nonempty repository URL that does not start with a dash.' >&2
        exit 1
    }
    APK_REPOSITORY_ARGS+=(--repository "$1")
}
if [[ -n "${IMMICH_APK_REPOSITORY:-}" ]]; then
    add_runtime_repository "$IMMICH_APK_REPOSITORY"
fi
positionals=()
while (( $# )); do
    case "$1" in
        --help|-h)
            printf 'Usage: %s [--allow-untrusted] [--repository URL] [release-tag|latest] [owner/repo]\n' "$0"
            printf 'Installs the native Alpine 3.24 package for this machine.\n'
            printf 'Default: latest stable release from ronhombre/immich-alpine.\n'
            printf 'Trust the publisher public key in /etc/apk/keys before installing.\n'
            printf 'Unsigned packages require --allow-untrusted or IMMICH_ALLOW_UNTRUSTED=1.\n'
            printf 'Runtime APKs are contained inside the Immich APK and checked against Alpine signatures.\n'
            printf '%s\n' '--repository is repeatable and adds repositories only for this package transaction.'
            printf 'IMMICH_APK_REPOSITORY supplies one additional runtime repository.\n'
            printf 'For an older build or one made without bundled Edge runtime libraries:\n'
            printf '  %s --repository https://dl-cdn.alpinelinux.org/alpine/edge/community\n' "$0"
            exit 0 ;;
        --allow-untrusted) ALLOW_UNTRUSTED=1 ;;
        --repository)
            (( $# >= 2 )) || { echo 'ERROR: --repository requires a URL.' >&2; exit 1; }
            add_runtime_repository "$2"
            shift ;;
        --*) printf 'ERROR: Unknown option: %s\n' "$1" >&2; exit 1 ;;
        *) positionals+=("$1") ;;
    esac
    shift
done
(( ${#positionals[@]} <= 2 )) || { echo 'ERROR: Expected at most a release tag and owner/repo.' >&2; exit 1; }
RELEASE_TAG="${positionals[0]:-latest}"
GITHUB_REPO="${positionals[1]:-ronhombre/immich-alpine}"
IMMICH_PATH="/var/lib/immich"
IMMICH_LOG_PATH="/var/log/immich"
VERSION_FILE="$IMMICH_PATH/.immich-version"
BACKUP_ROOT="$IMMICH_PATH/backups"
PENDING_FILE="$IMMICH_PATH/.upgrade-pending"
HEALTH_URL="${IMMICH_HEALTH_URL:-http://127.0.0.1:2283/api/server/ping}"
HEALTH_RETRIES="${IMMICH_HEALTH_RETRIES:-30}"

[[ $EUID -eq 0 ]] || { echo 'ERROR: Run as root.' >&2; exit 1; }
[[ -f /etc/alpine-release ]] || { echo 'ERROR: This installer requires Alpine Linux 3.24.' >&2; exit 1; }
read -r alpine_version < /etc/alpine-release
[[ "$alpine_version" == 3.24.* ]] || { echo "ERROR: Expected Alpine 3.24, found $alpine_version." >&2; exit 1; }
command -v apk >/dev/null || { echo 'ERROR: apk is required.' >&2; exit 1; }
[[ "$(apk --version)" == 'apk-tools 3.'* ]] || {
    echo 'ERROR: This APKv3 installer requires apk-tools 3.x.' >&2; exit 1;
}
APK_ARCH="$(apk --print-arch)"
case "$APK_ARCH" in
    x86_64|aarch64) ;;
    *) echo "ERROR: Unsupported package architecture: $APK_ARCH" >&2; exit 1 ;;
esac
ASSET_NAME="immich-alpine-3.24-${APK_ARCH}.apk"
[[ "$ALLOW_UNTRUSTED" == 0 || "$ALLOW_UNTRUSTED" == 1 ]] || {
    echo 'ERROR: IMMICH_ALLOW_UNTRUSTED must be 0 or 1.' >&2; exit 1;
}
APK_TRUST_ARGS=()
if [[ "$ALLOW_UNTRUSTED" == 1 ]]; then
    APK_TRUST_ARGS+=(--allow-untrusted)
    echo 'WARNING: Package signature trust checking is explicitly disabled for this installation.' >&2
fi
[[ "$RELEASE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { echo 'ERROR: Unsafe release tag.' >&2; exit 1; }
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'ERROR: Expected owner/repo.' >&2; exit 1; }
[[ "$HEALTH_RETRIES" =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: HEALTH_RETRIES must be positive.' >&2; exit 1; }

TMP_DIR=""
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

# The package declares application dependencies. Bootstrap only installer tools.
apk add --no-cache bash curl util-linux

# Resolve latest via GitHub's stable-release redirect, not the rate-limited API.
# Resolve before touching services; a lookup failure leaves Immich running.
if [[ "$RELEASE_TAG" == "latest" ]]; then
    echo "Checking latest published release of $GITHUB_REPO ..."
    latest_url="$(curl --fail --silent --show-error --location --retry 3 \
        --connect-timeout 15 --max-time 60 --output /dev/null \
        --write-out '%{url_effective}' \
        "https://github.com/${GITHUB_REPO}/releases/latest")" || {
        echo 'ERROR: Failed to resolve the latest GitHub release.' >&2
        exit 1
    }
    latest_prefix="https://github.com/${GITHUB_REPO}/releases/tag/"
    case "$latest_url" in
        "$latest_prefix"*) RELEASE_TAG="${latest_url#"$latest_prefix"}" ;;
        *) echo "ERROR: Unexpected latest-release redirect: $latest_url" >&2; exit 1 ;;
    esac
    [[ "$RELEASE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
        echo "ERROR: Invalid release tag returned by GitHub: $RELEASE_TAG" >&2
        exit 1
    }
    echo "Latest stable release: $RELEASE_TAG"
fi

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
APK_MANAGED=0
apk info --installed immich >/dev/null 2>&1 && APK_MANAGED=1
SOURCE_VERSION=""
if [[ -f "$VERSION_FILE" ]]; then
    IFS= read -r SOURCE_VERSION < "$VERSION_FILE" || [[ -n "$SOURCE_VERSION" ]]
fi
# Direct `apk add` installations have no GitHub release marker yet. Use their
# actual installed package version as the backup label instead of guessing a tag.
if (( APK_MANAGED )) && [[ -z "$SOURCE_VERSION" ]]; then
    installed_version="$(apk query --installed --fields version immich | sed -n 's/^Version: //p')"
    [[ "$installed_version" =~ ^[0-9][0-9a-z._]*-r[0-9]+$ ]] || {
        echo 'ERROR: Could not identify the installed Immich package version.' >&2; exit 1;
    }
    SOURCE_VERSION="apk-${installed_version}"
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
if (( IS_UPGRADE && APK_MANAGED )) && [[ -z "$BACKUP_DIR" && "$SOURCE_VERSION" == "$RELEASE_TAG" ]]; then
    echo "$RELEASE_TAG is already recorded as installed; no changes made."
    exit 0
fi

# --- Fetch and validate release BEFORE stopping the running services ---
TMP_DIR=$(mktemp -d)
mkdir -p "$TMP_DIR/cache"
ASSET_URL="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"
PACKAGE_FILE="$TMP_DIR/$ASSET_NAME"
echo "Downloading $ASSET_URL ..."
curl --fail --location --retry 3 --output "$PACKAGE_FILE" "$ASSET_URL"
curl --fail --location --retry 3 --output "$PACKAGE_FILE.sha256" "$ASSET_URL.sha256"
# A release checksum detects transfer damage; the trusted APK signature is the
# authenticity check. Never execute a checksum file's arbitrary path names.
mapfile -t checksum_lines < "$PACKAGE_FILE.sha256"
[[ ${#checksum_lines[@]} -eq 1 && "${checksum_lines[0]}" =~ ^([a-fA-F0-9]{64})[[:space:]]{2}([^[:space:]]+)$ ]] || {
    echo 'ERROR: Invalid release checksum file.' >&2; exit 1;
}
expected_hash="${BASH_REMATCH[1]}"
[[ "${BASH_REMATCH[2]}" == "$ASSET_NAME" ]] || {
    echo 'ERROR: Release checksum names an unexpected file.' >&2; exit 1;
}
actual_hash="$(sha256sum "$PACKAGE_FILE")"
actual_hash="${actual_hash%% *}"
[[ "${actual_hash,,}" == "${expected_hash,,}" ]] || { echo 'ERROR: Package checksum mismatch.' >&2; exit 1; }
apk "${APK_TRUST_ARGS[@]}" verify "$PACKAGE_FILE" || {
    echo 'ERROR: APK verification failed. Install the trusted publisher public key in /etc/apk/keys.' >&2
    echo 'For a deliberately unsigned build, explicitly pass --allow-untrusted.' >&2
    exit 1
}

# Read only the APKv3 info fields; do not evaluate package metadata as shell.
# Consume the entire dump so pipefail also catches a malformed package.
apk "${APK_TRUST_ARGS[@]}" adbdump "$PACKAGE_FILE" | awk '
    /^info:$/ { in_info=1; next }
    in_info && /^[^ ]/ { in_info=0 }
    in_info && /^  (name|version|arch|hashes): / { print }
' > "$TMP_DIR/package-info"
PACKAGE_NAME="$(sed -n 's/^  name: //p' "$TMP_DIR/package-info")"
PACKAGE_VERSION="$(sed -n 's/^  version: //p' "$TMP_DIR/package-info")"
PACKAGE_ARCH="$(sed -n 's/^  arch: //p' "$TMP_DIR/package-info")"
PACKAGE_ID="$(sed -n 's/^  hashes: //p' "$TMP_DIR/package-info")"
[[ "$PACKAGE_NAME" == immich && "$PACKAGE_ARCH" == "$APK_ARCH" && \
   "$PACKAGE_VERSION" =~ ^[0-9][0-9a-z._]*-r[0-9]+$ && "$PACKAGE_ID" =~ ^[a-fA-F0-9]{40}$ ]] || {
    echo 'ERROR: Release must be an Immich APKv3 package for this architecture with valid metadata.' >&2; exit 1;
}
apk version --check "$PACKAGE_VERSION" >/dev/null || { echo 'ERROR: Invalid APK version.' >&2; exit 1; }

# The main APK contains both the runtime manifest and the original Alpine APKs.
# Its signature authenticates their bytes; the Alpine signatures below are
# checked independently. Older releases may not contain a runtime manifest.
INSTALL_APKS=("$PACKAGE_FILE")
runtime_manifest_hash="$(apk "${APK_TRUST_ARGS[@]}" manifest "$PACKAGE_FILE" | \
    awk '$2 == "usr/share/immich/runtime-apks.sha256" && NF == 2 { print $1 }')"
if [[ -n "$runtime_manifest_hash" ]]; then
    [[ "$runtime_manifest_hash" =~ ^sha256:([a-fA-F0-9]{64})$ ]] || {
        echo 'ERROR: Invalid or duplicate embedded runtime manifest checksum.' >&2; exit 1;
    }
    expected_runtime_manifest_hash="${BASH_REMATCH[1]}"
    runtime_manifest="$TMP_DIR/runtime-apks.sha256"
    if [[ "${expected_runtime_manifest_hash,,}" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]]; then
        # The signed checksum identifies an empty manifest; there is no bundle
        # to extract in builds that use only the configured repositories.
        : > "$runtime_manifest"
        mkdir -p "$TMP_DIR/runtime-apks"
    else
        # apk-tools 3 cannot extract selected paths. Extract natively into a
        # private directory, retain only the bundle, and immediately discard
        # the staged application before the real package transaction.
        extracted_package="$TMP_DIR/extracted-package"
        mkdir -p "$extracted_package"
        echo 'Extracting embedded Alpine runtime packages ...'
        apk "${APK_TRUST_ARGS[@]}" extract --destination "$extracted_package" "$PACKAGE_FILE" || {
            echo 'ERROR: Could not extract the verified Immich package.' >&2; exit 1;
        }
        for runtime_parent in usr usr/share usr/share/immich; do
            [[ -d "$extracted_package/$runtime_parent" && ! -L "$extracted_package/$runtime_parent" ]] || {
                echo 'ERROR: Invalid embedded runtime bundle directory.' >&2; exit 1;
            }
        done
        embedded_manifest="$extracted_package/usr/share/immich/runtime-apks.sha256"
        embedded_runtime_dir="$extracted_package/usr/share/immich/runtime-apks"
        [[ -f "$embedded_manifest" && ! -L "$embedded_manifest" ]] || {
            echo 'ERROR: The embedded runtime manifest is missing or is not a regular file.' >&2; exit 1;
        }
        [[ -d "$embedded_runtime_dir" && ! -L "$embedded_runtime_dir" ]] || {
            echo 'ERROR: Runtime APKs are missing from the Immich package. Rebuild this release with its runtime APKs embedded.' >&2
            exit 1
        }
        mv -- "$embedded_manifest" "$runtime_manifest"
        mv -- "$embedded_runtime_dir" "$TMP_DIR/runtime-apks"
        rm -rf -- "$extracted_package"
    fi
    actual_runtime_manifest_hash="$(sha256sum "$runtime_manifest")"
    actual_runtime_manifest_hash="${actual_runtime_manifest_hash%% *}"
    [[ "${actual_runtime_manifest_hash,,}" == "${expected_runtime_manifest_hash,,}" ]] || {
        echo 'ERROR: Runtime manifest does not match the verified Immich package.' >&2; exit 1;
    }

    declare -A seen_runtime_apks=()
    runtime_checksum_re='^([a-fA-F0-9]{64})  ([^[:space:]]+)$'
    while IFS= read -r runtime_line || [[ -n "$runtime_line" ]]; do
        [[ "$runtime_line" =~ $runtime_checksum_re ]] || {
            echo 'ERROR: Invalid runtime package manifest line.' >&2; exit 1;
        }
        runtime_hash="${BASH_REMATCH[1]}"
        runtime_name="${BASH_REMATCH[2]}"
        [[ "$runtime_name" =~ ^[a-z0-9][a-z0-9+_.-]*-[0-9][0-9a-z._]*-r[0-9]+\.(x86_64|aarch64|noarch)\.apk$ ]] || {
            echo "ERROR: Unsafe runtime APK filename: $runtime_name" >&2; exit 1;
        }
        [[ "${BASH_REMATCH[1]}" == "$APK_ARCH" || "${BASH_REMATCH[1]}" == noarch ]] || {
            echo "ERROR: Runtime APK has the wrong architecture: $runtime_name" >&2; exit 1;
        }
        [[ -z "${seen_runtime_apks[$runtime_name]+x}" ]] || {
            echo "ERROR: Duplicate runtime APK filename: $runtime_name" >&2; exit 1;
        }
        seen_runtime_apks["$runtime_name"]=1
        runtime_file="$TMP_DIR/runtime-apks/$runtime_name"
        [[ -f "$runtime_file" && ! -L "$runtime_file" ]] || {
            echo "ERROR: Embedded runtime APK is missing or is not a regular file: $runtime_name" >&2
            echo 'Rebuild this release with all runtime APKs contained inside the Immich package.' >&2
            exit 1
        }
        echo "Verifying embedded runtime package $runtime_name ..."
        actual_runtime_hash="$(sha256sum "$runtime_file")"
        actual_runtime_hash="${actual_runtime_hash%% *}"
        [[ "${actual_runtime_hash,,}" == "${runtime_hash,,}" ]] || {
            echo "ERROR: Runtime APK checksum mismatch: $runtime_name" >&2; exit 1;
        }
        # These are original Alpine packages. Their signatures must be trusted
        # even when the user has explicitly allowed an unsigned main package.
        apk verify "$runtime_file" || {
            echo "ERROR: Bundled runtime APK is not trusted by Alpine's installed keys: $runtime_name" >&2
            exit 1
        }
        INSTALL_APKS+=("$runtime_file")
    done < "$runtime_manifest"
else
    echo 'This older package has no bundled runtime manifest; using configured repositories.'
fi

# Seed a private cache explicitly. A same-version `apk add` is a no-op and does
# not cache the file; `apk fix` otherwise skips unavailable local packages.
# apk-tools 3 uses ${name}-${version}.${hash:8}.apk (src/context.c).
CACHED_PACKAGE="$TMP_DIR/cache/immich-${PACKAGE_VERSION}.${PACKAGE_ID:0:8}.apk"
cp -- "$PACKAGE_FILE" "$CACHED_PACKAGE"
REINSTALL_SAME_VERSION=0
apk info --installed "immich=$PACKAGE_VERSION" >/dev/null 2>&1 && REINSTALL_SAME_VERSION=1
# Resolve dependencies before service downtime. Actual installation rechecks
# signatures and dependencies; this does not execute package lifecycle hooks.
# Simulation does not auto-refresh indexes, and this private cache starts empty.
# Repository signatures remain mandatory even for an unsigned local main APK.
apk "${APK_REPOSITORY_ARGS[@]}" --cache-dir "$TMP_DIR/cache" update || {
    echo 'ERROR: Could not refresh runtime repository indexes; services have not been stopped.' >&2
    exit 1
}
apk "${APK_TRUST_ARGS[@]}" "${APK_REPOSITORY_ARGS[@]}" --cache-dir "$TMP_DIR/cache" add --simulate "${INSTALL_APKS[@]}" || {
    echo 'ERROR: Package dependencies could not be resolved; services have not been stopped.' >&2
    echo 'If this build used newer native libraries, pass --repository URL for the matching runtime repository.' >&2
    exit 1
}

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

# Move a legacy tar-installed app aside once, so obsolete unowned files cannot
# survive migration. Once APK manages immich, only APK replaces its files.
# A prior migration attempt may have left .app-previous and a pending record.
PREVIOUS_APP="$IMMICH_PATH/.app-previous"
if (( ! IS_UPGRADE )) && [[ -e "$PREVIOUS_APP" || -L "$PREVIOUS_APP" ]]; then
    echo "ERROR: Stale $PREVIOUS_APP exists. Resolve it before a fresh install." >&2
    exit 1
fi
if (( IS_UPGRADE && ! APK_MANAGED )); then
    [[ ! -L "$IMMICH_PATH/app" && ! -L "$PREVIOUS_APP" ]] || {
        echo 'ERROR: Refusing to migrate a symlinked application directory.' >&2; exit 1;
    }
    if [[ -d "$IMMICH_PATH/app" ]]; then
        if [[ -d "$PREVIOUS_APP" ]]; then
            # The completed backup and pending record were validated above.
            rm -rf -- "$IMMICH_PATH/app"
        else
            mv "$IMMICH_PATH/app" "$PREVIOUS_APP"
        fi
    fi
fi

echo "Installing Immich package $PACKAGE_VERSION ..."
apk "${APK_TRUST_ARGS[@]}" "${APK_REPOSITORY_ARGS[@]}" --cache-dir "$TMP_DIR/cache" add "${INSTALL_APKS[@]}"
if (( REINSTALL_SAME_VERSION )); then
    # A retry must restore files even when the previous transaction already
    # committed this version. fix takes a package NAME, not a local file path.
    apk "${APK_TRUST_ARGS[@]}" "${APK_REPOSITORY_ARGS[@]}" --cache-dir "$TMP_DIR/cache" fix --reinstall immich
fi
[[ -f "$IMMICH_PATH/app/start.sh" && -f "$IMMICH_PATH/app/dist/main.js" && \
   -f "$IMMICH_PATH/app/machine-learning/start.sh" && -f "$IMMICH_PATH/env" && \
   -x /etc/init.d/immich && -x /etc/init.d/immich-ml ]] || {
    echo 'ERROR: Installed package or runtime setup is incomplete.' >&2; exit 1;
}
# The package owns OpenRC scripts and creates env only if absent. Enable its
# services here; a fresh installation stays stopped until credentials are set.
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
