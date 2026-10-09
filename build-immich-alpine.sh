#!/usr/bin/env bash
# Build Immich for Alpine 3.24, then create a verified GitHub Release asset.
#
# Usage (inside the Alpine builder, usually from GitHub Actions):
#   IMMICH_REV=v2.2.0 EXTISM_JS_TAG=v1.6.0 ./build-immich-alpine-improved.sh
#   IMMICH_REV=<upstream-tag> ARTIFACT_DIR=/path/to/shared/dist ./build-immich-alpine-improved.sh
#   ./build-immich-alpine-improved.sh --verify-archive /path/to/immich-alpine-3.24.tar.gz
#
# The upstream tag and the Alpine release tag are DIFFERENT concepts. Set
# IMMICH_REV explicitly in the workflow; do not quietly build a stale default.
# The installer expects var/lib/immich/app inside the tarball.
set -Eeuo pipefail
umask 022

IMMICH_PATH=/var/lib/immich
APP="$IMMICH_PATH/app"
HOME_DIR="$IMMICH_PATH/home"
ASSET_NAME=immich-alpine-3.24.tar.gz
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/immich-alpine-dist}"
IMMICH_REV="${IMMICH_REV:-}"
EXTISM_JS_TAG="${EXTISM_JS_TAG:-}"
IMMICH_EXPECTED_COMMIT="${IMMICH_EXPECTED_COMMIT:-}"
IMMICH_ALPINE_RELEASE="${IMMICH_ALPINE_RELEASE:-}"
SOURCE_REPO="${IMMICH_SOURCE_REPO:-https://github.com/immich-app/immich.git}"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}"

usage() {
  cat <<'HELP'
Usage:
  IMMICH_REV=<upstream-git-tag> [EXTISM_JS_TAG=<extism-tag>] \
    [ARTIFACT_DIR=<writable-path>] bash build-immich-alpine-improved.sh

  bash build-immich-alpine-improved.sh --verify-archive /path/to/immich-alpine-3.24.tar.gz

Outputs:
  $ARTIFACT_DIR/immich-alpine-3.24.tar.gz
  $ARTIFACT_DIR/immich-alpine-3.24.tar.gz.sha256

Requires an Alpine 3.24 builder with the same Node, pnpm, Python, uv, native
libraries, and build dependencies. As root, this script additionally installs
Alpine's binaryen package and extism-js. IMPORTANT: Run on a dedicated build
runner/container, NOT an Immich server.
HELP
}

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[build] %s\n' "$*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "Missing command: $1"; }
valid_ref() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/+\-]*$ && "$1" != *..* ]]
}

# Standalone verification can run on the GitHub Actions host as well as Alpine.
verify_archive() {
  local archive="$1" entry manifest
  [[ -f "$archive" ]] || fatal "Archive missing: $archive"
  require_cmd tar
  manifest="$(mktemp)"
  if ! tar -tzf "$archive" > "$manifest"; then
    rm -f -- "$manifest"
    fatal 'Archive failed tar/gzip integrity check'
  fi
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$manifest"; then
    rm -f -- "$manifest"
    fatal 'Archive contains unsafe member paths'
  fi
  for entry in \
    var/lib/immich/app/start.sh \
    var/lib/immich/app/dist/main.js \
    var/lib/immich/app/www \
    var/lib/immich/app/i18n \
    var/lib/immich/app/machine-learning/start.sh \
    var/lib/immich/app/machine-learning/immich_ml \
    var/lib/immich/app/machine-learning/venv \
    var/lib/immich/app/plugins/immich-plugin-core/manifest.json \
    var/lib/immich/app/geodata/cities500.txt \
    var/lib/immich/app/.build-info \
    var/lib/immich/app/.build-complete; do
    # Directory names in GNU tar listings normally end with '/'.
    if [[ "$entry" == */www || "$entry" == */i18n || "$entry" == */immich_ml || "$entry" == */venv ]]; then
      grep -Fqx -- "${entry}/" "$manifest" || fatal "Missing directory: $entry"
    else
      grep -Fqx -- "$entry" "$manifest" || fatal "Missing file: $entry"
    fi
  done
  # Secrets / mutable host data must never be included in a release artifact.
  if grep -Eq \
      '(^|/)\.env(/|$)|^var/lib/immich/(env|\.immich-version|\.upgrade-pending|backups|cache|home|upload)(/|$)|^var/lib/immich/app/(env|backups)(/|$)' "$manifest"; then
    fatal 'Archive includes a forbidden runtime data path'
  fi
  rm -f -- "$manifest"
  log "Archive validated: $archive"
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --verify-archive)
    [[ $# -eq 2 ]] || fatal '--verify-archive requires exactly one path'
    verify_archive "$2"
    exit 0 ;;
  --build) [[ $# -eq 1 ]] || fatal 'Unexpected arguments after --build' ;;
  '') ;;
  *) fatal "Unexpected argument '$1' (pass IMMICH_REV as an environment variable)" ;;
esac

[[ -n "$IMMICH_REV" ]] || fatal 'Set IMMICH_REV to the upstream Immich tag/ref.'
valid_ref "$IMMICH_REV" || fatal 'Unsafe IMMICH_REV.'
[[ -z "$EXTISM_JS_TAG" ]] || valid_ref "$EXTISM_JS_TAG" || fatal 'Unsafe EXTISM_JS_TAG.'
[[ -z "$IMMICH_EXPECTED_COMMIT" || "$IMMICH_EXPECTED_COMMIT" =~ ^[a-fA-F0-9]{40}$ ]] || fatal 'IMMICH_EXPECTED_COMMIT must be a full 40-digit SHA.'
[[ -z "$IMMICH_ALPINE_RELEASE" ]] || valid_ref "$IMMICH_ALPINE_RELEASE" || fatal 'Unsafe IMMICH_ALPINE_RELEASE.'
[[ "$ARTIFACT_DIR" = /* ]] || fatal 'ARTIFACT_DIR must be an absolute path.'
[[ "$ARTIFACT_DIR" != "$IMMICH_PATH" && "$ARTIFACT_DIR" != "$IMMICH_PATH/"* ]] || fatal 'ARTIFACT_DIR must be outside /var/lib/immich.'

[[ ! -L "$IMMICH_PATH" && ! -L "$HOME_DIR" ]] || fatal 'Refusing symlinked build root/home path.'
[[ -f /etc/alpine-release ]] || fatal 'Builder must run on Alpine Linux.'
read -r alpine_version </etc/alpine-release
[[ "$alpine_version" == 3.24.* ]] || fatal "Expected Alpine 3.24, found $alpine_version."

# Never run this build process against an actual installation.
for marker in "$IMMICH_PATH/env" "$IMMICH_PATH/.immich-version" "$IMMICH_PATH/backups" "$IMMICH_PATH/.upgrade-pending"; do
  [[ ! -e "$marker" ]] || fatal "Detected runtime state at $marker; run only in a disposable builder."
done

# Root stage prepares system-level tools, then hands off work without a shell
# string containing arbitrary upstream refs or writable paths.
if [[ "$(id -un)" == root ]]; then
  require_cmd apk
  require_cmd curl
  require_cmd python3
  require_cmd su
  require_cmd readlink
  log 'Installing Binaryen from Alpine 3.24 community repository...'
  apk add --no-cache binaryen
  for tool in wasm-merge wasm-opt; do require_cmd "$tool"; done

  if [[ -z "$EXTISM_JS_TAG" ]]; then
    log 'EXTISM_JS_TAG unset; resolving latest Extism release (pin it for reproducibility).'
    EXTISM_JS_TAG="$(curl -fsSL --retry 3 https://api.github.com/repos/extism/js-pdk/releases/latest | \
      python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    valid_ref "$EXTISM_JS_TAG" || fatal 'Invalid Extism release tag from GitHub.'
  fi

  case "$(uname -m)" in
    x86_64|aarch64) arch="$(uname -m)" ;;
    *) fatal "Unsupported extism-js architecture: $(uname -m)" ;;
  esac
  extism_url="https://github.com/extism/js-pdk/releases/download/${EXTISM_JS_TAG}/extism-js-${arch}-linux-${EXTISM_JS_TAG}.gz"
  tmp_extism="$(mktemp -d)"
  trap 'rm -rf -- "${tmp_extism:-}"' EXIT
  log "Installing extism-js ${EXTISM_JS_TAG} (${arch})..."
  curl -fL --retry 3 --retry-delay 2 -o "$tmp_extism/extism-js.gz" "$extism_url"
  gzip -t "$tmp_extism/extism-js.gz"
  gzip -dc "$tmp_extism/extism-js.gz" > "$tmp_extism/extism-js"
  install -m 0755 "$tmp_extism/extism-js" /usr/local/bin/extism-js
  if ! /usr/local/bin/extism-js --help >/dev/null 2>&1; then
    log 'extism-js cannot execute. Check architecture and ELF loader compatibility.'
    command -v file >/dev/null && file /usr/local/bin/extism-js >&2 || true
    command -v ldd >/dev/null && ldd /usr/local/bin/extism-js >&2 || true
    fatal 'extism-js executable check failed.'
  fi
  rm -rf -- "$tmp_extism"
  trap - EXIT

  if ! id immich >/dev/null 2>&1; then
    getent group immich >/dev/null 2>&1 || addgroup -S immich
    adduser -S -D -h "$HOME_DIR" -s /sbin/nologin -G immich immich
  fi
  mkdir -p "$IMMICH_PATH" "$HOME_DIR" "$ARTIFACT_DIR"
  chown immich:immich "$IMMICH_PATH" "$HOME_DIR" "$ARTIFACT_DIR"
  # Fail on unsafe service/server installations before any root chown above.
  SCRIPT_PATH="$(readlink -f -- "$0")"
  [[ -f "$SCRIPT_PATH" ]] || fatal "Cannot resolve script path: $0"
  log "Starting unprivileged build as immich (source $IMMICH_REV)..."
  # Each variable is shell-escaped; do not interpolate raw Git refs in su -c.
  printf -v cmd 'exec env IMMICH_REV=%q EXTISM_JS_TAG=%q IMMICH_EXPECTED_COMMIT=%q IMMICH_ALPINE_RELEASE=%q IMMICH_SOURCE_REPO=%q ARTIFACT_DIR=%q NODE_OPTIONS=%q bash %q --build' \
    "$IMMICH_REV" "$EXTISM_JS_TAG" "$IMMICH_EXPECTED_COMMIT" "$IMMICH_ALPINE_RELEASE" "$SOURCE_REPO" "$ARTIFACT_DIR" "$NODE_OPTIONS" "$SCRIPT_PATH"
  exec su -s /bin/bash immich -c "$cmd"
fi

[[ "$(id -un)" == immich ]] || fatal 'Run as root or the immich builder account.'
for tool in git curl python3 uv pnpm node npm tar gzip unzip wget sha256sum wasm-merge wasm-opt extism-js; do
  require_cmd "$tool"
done
extism-js --help >/dev/null 2>&1 || fatal 'extism-js fails under immich user.'
[[ -d "$HOME_DIR" && -w "$HOME_DIR" && -w "$IMMICH_PATH" ]] || fatal 'Builder home/target not writable by immich.'
mkdir -p -- "$ARTIFACT_DIR"
[[ -d "$ARTIFACT_DIR" && -w "$ARTIFACT_DIR" ]] || fatal 'Artifact directory not writable by immich.'
export HOME="$HOME_DIR"
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
export SHARP_FORCE_GLOBAL_LIBVIPS=true
export SHARP_USE_GLOBAL_LIBVIPS=true
export UV_PYTHON_PREFERENCE=only-system
umask 022

[[ ! -L "$APP" ]] || fatal "Refusing to replace symlinked app path: $APP"
[[ ! -L "$IMMICH_PATH/i18n" ]] || fatal 'Refusing to replace symlinked i18n path.'

# Remove stale *publish* outputs before starting. If a build fails, the
# release-upload step cannot accidentally upload an older successful tarball.
rm -f -- "$ARTIFACT_DIR/$ASSET_NAME" "$ARTIFACT_DIR/$ASSET_NAME.sha256"
WORK="$(mktemp -d /tmp/immich-src.XXXXXXXX)"
SERVER_PRUNED="$(mktemp -d /tmp/immich-prod.XXXXXXXX)"
PARTIAL_ARCHIVE=""
SUCCESS=0
STEP='initialization'
cleanup() {
  local status=$?
  trap - EXIT
  [[ -z "$PARTIAL_ARCHIVE" ]] || rm -f -- "$PARTIAL_ARCHIVE"
  rm -rf -- "$WORK" "$SERVER_PRUNED"
  if (( status != 0 )) && (( ! SUCCESS )); then
    rm -f -- "$ARTIFACT_DIR/$ASSET_NAME" "$ARTIFACT_DIR/$ASSET_NAME.sha256"
    rm -f -- "$APP/.build-complete"
    log "FAILED at: $STEP (exit $status); no release asset was published."
  fi
  exit "$status"
}
trap cleanup EXIT

STEP='checkout'
log "Cloning Immich $IMMICH_REV..."
git clone --depth 1 --branch "$IMMICH_REV" "$SOURCE_REPO" "$WORK/source"
cd "$WORK/source"
SOURCE_SHA="$(git rev-parse --verify HEAD^{commit})"
if [[ -n "$IMMICH_EXPECTED_COMMIT" && "${SOURCE_SHA,,}" != "${IMMICH_EXPECTED_COMMIT,,}" ]]; then
  fatal "Upstream commit mismatch: expected $IMMICH_EXPECTED_COMMIT got $SOURCE_SHA"
fi
log "Resolved source commit: $SOURCE_SHA"

STEP='system Python constraints'
# Alpine 3.24's native extensions must match the Python interpreter exactly.
python3 - <<'PY'
import sys
if sys.version_info[:2] != (3, 14):
    raise SystemExit(f'Expected Python 3.14 for Alpine 3.24 native modules; found {sys.version}')
PY
[[ -f machine-learning/pyproject.toml && -f machine-learning/uv.lock ]] || \
  fatal 'Upstream ML metadata missing: pyproject.toml or uv.lock.'

# Allow Alpine 3.24 Python 3.14 without installing incompatible managed CPython.
python3 - <<'PY'
from pathlib import Path
p = Path('machine-learning/pyproject.toml')
s = p.read_text()
for source in ('>=3.12,<3.14', '>=3.13,<3.14', '~=3.13'):
    s = s.replace(f'requires-python = "{source}"', 'requires-python = ">=3.13,<3.15"')
# Preserve other requirements; uv's frozen lock remains pinned to upstream.
p.write_text(s)
for name in ('machine-learning/.python-version', 'machine-learning/uv.toml'):
    p = Path(name)
    if p.exists():
        s = p.read_text().replace('3.13', '3.14')
        p.write_text(s)
# Only adjust explicit tool.uv python-version, not arbitrary version strings.
p = Path('machine-learning/pyproject.toml')
s = p.read_text()
import re
s = re.sub(r'(python-version\s*=\s*\")3\.13(\")', r'\g<1>3.14\2', s)
p.write_text(s)
PY

STEP='portability patches'
# Preserve the original path substitutions, but avoid grep|xargs and filenames
# with whitespace, and skip symlinks, binary content, and .git data.
python3 - "$IMMICH_PATH" "$APP" <<'PY'
from pathlib import Path
import os, sys
root = Path('.')
immich_path, app = [s.encode() for s in sys.argv[1:]]
replacements = ((b'/usr/src', immich_path), (b'"/build"', b'"'+app+b'"'), (b"'/build'", b"'"+app+b"'"))
for base, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in ('.git', 'node_modules', '.venv')]
    for filename in files:
        p = Path(base, filename)
        if p.is_symlink() or p.stat().st_size > 8*1024*1024:
            continue
        content = p.read_bytes()
        if b'\0' in content:
            continue
        updated = content
        for before, after in replacements:
            updated = updated.replace(before, after)
        if updated != content:
            p.write_bytes(updated)
PY

# Keep the plugin tool's absolute path to avoid pnpm lifecycle PATH issues.
if [[ -f packages/plugin-core/package.json ]]; then
  python3 - <<'PY'
from pathlib import Path
p = Path('packages/plugin-core/package.json')
s = p.read_text()
s = s.replace('"extism-js dist/', '"/usr/local/bin/extism-js dist/')
p.write_text(s)
PY
fi

STEP='build JavaScript'
log 'Installing/building server, web, SDK, and plugin-core...'
pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core \
  --filter immich --filter immich-web install --frozen-lockfile --force
pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter immich build
pnpm --filter @immich/sdk --filter immich-web build
pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core build

STEP='deploy production server'
pnpm --filter immich --prod --no-optional deploy "$SERVER_PRUNED"
[[ -d "$SERVER_PRUNED/node_modules/sharp" ]] || fatal 'Deployed Sharp package missing.'
CFLAGS='-fno-lto' CXXFLAGS='-fno-lto' LDFLAGS='-fno-lto' \
  pnpm --config.verify-deps-before-run=false \
  --dir "$SERVER_PRUNED/node_modules/sharp" exec npm run build

# Build in the FINAL /var/lib/immich/app location: Python venv shebangs are
# absolute, so building under a temporary prefix and moving later breaks them.
STEP='assemble application'
rm -rf -- "$APP" "$IMMICH_PATH/i18n"
mkdir -p "$APP/plugins/immich-plugin-core" "$APP/machine-learning"
cp -a "$SERVER_PRUNED/." "$APP/"
cp -a web/build "$APP/www"
cp -a packages/plugin-core/dist "$APP/plugins/immich-plugin-core/"
cp -a packages/plugin-core/manifest.json "$APP/plugins/immich-plugin-core/"
cp -a pnpm-lock.yaml LICENSE "$APP/"
cp -a i18n "$APP/i18n"
ln -s app/i18n "$IMMICH_PATH/i18n"

STEP='build machine learning'
python3 -m venv "$APP/machine-learning/venv"
(
  set -Eeuo pipefail
  # shellcheck disable=SC1091
  source "$APP/machine-learning/venv/bin/activate"
  cd machine-learning
  uv sync --frozen --extra cpu --no-dev --no-editable \
    --no-install-project --no-install-workspace \
    --no-install-package opencv-python-headless \
    --no-install-package opencv-python \
    --no-install-package onnxruntime \
    --no-install-package shapely \
    --no-install-package pyyaml \
    --compile-bytecode --no-progress --no-cache --active --link-mode=copy

  # Locate Alpine site-packages explicitly, not the activated venv.
  sys_site="$(/usr/bin/python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  venv_site="$(python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
  [[ -d "$sys_site" && -d "$venv_site" ]] || fatal 'System or venv site-packages missing.'
  for mod in cv2 onnxruntime shapely yaml; do
    if [[ -d "$sys_site/$mod" ]]; then
      ln -sfn "$sys_site/$mod" "$venv_site/$mod"
    fi
    for so in "$sys_site/${mod}"*.so; do
      [[ -f "$so" ]] || continue
      ln -sfn "$so" "$venv_site/$(basename "$so")"
    done
  done
  python - <<'PY'
import cv2, onnxruntime, shapely, yaml
print('Alpine native imports verified:', cv2.__version__, onnxruntime.__version__)
PY
)
cp -a machine-learning/immich_ml "$APP/machine-learning/"
# The launcher uses log_conf.json from its working directory.
if [[ -f machine-learning/log_conf.json ]]; then
  cp -a machine-learning/log_conf.json "$APP/machine-learning/log_conf.json"
elif [[ -f machine-learning/immich_ml/log_conf.json ]]; then
  cp -a machine-learning/immich_ml/log_conf.json "$APP/machine-learning/log_conf.json"
else
  # Gunicorn accepts standard Python logging.config JSON format.
  cat > "$APP/machine-learning/log_conf.json" <<'LOG_JSON'
{
  "version": 1,
  "disable_existing_loggers": false,
  "formatters": {"standard": {"format": "%(asctime)s %(levelname)s %(name)s: %(message)s"}},
  "handlers": {"console": {"class": "logging.StreamHandler", "formatter": "standard", "stream": "ext://sys.stdout"}},
  "root": {"level": "INFO", "handlers": ["console"]}
}
LOG_JSON
fi
# Keep any configuration files that the upstream ML app expects at runtime.
[[ -f machine-learning/immich_ml/gunicorn_conf.py ]] || fatal 'Missing gunicorn_conf.py in upstream machine learning source.'

STEP='download geodata'
log 'Downloading GeoNames/Natural Earth datasets...'
mkdir -p "$APP/geodata"
cd "$APP/geodata"
geo_pids=()
fetch_geo() {
  local url="$1" filename="$2"
  curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 180 \
    --output "${filename}.part" "$url" && mv -- "${filename}.part" "$filename"
}
fetch_geo https://download.geonames.org/export/dump/admin1CodesASCII.txt admin1CodesASCII.txt & geo_pids+=("$!")
fetch_geo https://download.geonames.org/export/dump/admin2Codes.txt admin2Codes.txt & geo_pids+=("$!")
fetch_geo https://download.geonames.org/export/dump/countryInfo.txt countryInfo.txt & geo_pids+=("$!")
fetch_geo https://download.geonames.org/export/dump/cities500.zip cities500.zip & geo_pids+=("$!")
fetch_geo https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson ne_10m_admin_0_countries.geojson & geo_pids+=("$!")
geo_failed=0
for pid in "${geo_pids[@]}"; do
  wait "$pid" || geo_failed=1
done
(( geo_failed == 0 )) || fatal 'One or more GeoNames downloads failed.'
for dataset in admin1CodesASCII.txt admin2Codes.txt countryInfo.txt cities500.zip ne_10m_admin_0_countries.geojson; do
  [[ -s "$dataset" ]] || fatal "Empty GeoNames file: $dataset"
done
unzip -tqq cities500.zip || fatal 'GeoNames ZIP failed verification.'
unzip -q cities500.zip
[[ -s cities500.txt ]] || fatal 'GeoNames cities500.txt is missing.'
date -u '+%Y-%m-%dT%H:%M:%SZ' > geodata-date.txt
rm -- cities500.zip
cd "$WORK/source"

STEP='runtime launchers'
mkdir -p "$IMMICH_PATH/upload" "$IMMICH_PATH/cache"
ln -sfn "$IMMICH_PATH/upload" "$APP/upload"
ln -sfn "$IMMICH_PATH/upload" "$APP/machine-learning/upload"

# Quoted heredocs prevent unintended build-time expansion of runtime values.
# These files must work when the app has been extracted onto a new server.
cat > "$APP/start.sh" <<'SERVER_START'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a
# shellcheck disable=SC1091
source /var/lib/immich/env
set +a
# The installer currently copies app/ only. Recreate stable external paths
# so the original upstream translation path and upload symlinks remain usable.
mkdir -p /var/lib/immich/upload /var/lib/immich/cache
if [[ ! -e /var/lib/immich/i18n && ! -L /var/lib/immich/i18n ]]; then
  ln -s /var/lib/immich/app/i18n /var/lib/immich/i18n
fi
cd /var/lib/immich/app
exec node /var/lib/immich/app/dist/main "$@"
SERVER_START
cat > "$APP/machine-learning/start.sh" <<'ML_START'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a
# shellcheck disable=SC1091
source /var/lib/immich/env
set +a
mkdir -p /var/lib/immich/upload /var/lib/immich/cache
cd /var/lib/immich/app/machine-learning
# shellcheck disable=SC1091
source venv/bin/activate
: "${MACHINE_LEARNING_HOST:=127.0.0.1}"
: "${MACHINE_LEARNING_PORT:=3003}"
: "${MACHINE_LEARNING_WORKERS:=1}"
: "${MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S:=2}"
: "${MACHINE_LEARNING_WORKER_TIMEOUT:=300}"
: "${MACHINE_LEARNING_CACHE_FOLDER:=/var/lib/immich/cache}"
: "${TRANSFORMERS_CACHE:=/var/lib/immich/cache}"
: "${HF_HOME:=/var/lib/immich/cache/hf-cache}"
export MACHINE_LEARNING_HOST MACHINE_LEARNING_PORT MACHINE_LEARNING_WORKERS
export MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S MACHINE_LEARNING_WORKER_TIMEOUT
export MACHINE_LEARNING_CACHE_FOLDER TRANSFORMERS_CACHE HF_HOME
exec gunicorn immich_ml.main:app \
  -k immich_ml.config.CustomUvicornWorker \
  -c immich_ml/gunicorn_conf.py \
  -b "${MACHINE_LEARNING_HOST}:${MACHINE_LEARNING_PORT}" \
  -w "$MACHINE_LEARNING_WORKERS" \
  -t "$MACHINE_LEARNING_WORKER_TIMEOUT" \
  --log-config-json log_conf.json \
  --keep-alive "$MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S" \
  --graceful-timeout 10 \
  --no-control-socket
ML_START
chmod 0755 "$APP/start.sh" "$APP/machine-learning/start.sh"

STEP='validate application'
for required in \
  "$APP/start.sh" "$APP/dist/main.js" "$APP/plugins/immich-plugin-core/manifest.json" \
  "$APP/machine-learning/start.sh" "$APP/machine-learning/venv/bin/python" \
  "$APP/machine-learning/venv/bin/gunicorn" \
  "$APP/geodata/cities500.txt" "$APP/www" "$APP/i18n" \
  "$APP/machine-learning/log_conf.json"; do
  [[ -e "$required" ]] || fatal "Missing required artifact path: $required"
done
# A GitHub Release must never contain credentials. The build tree must be clean.
[[ ! -e "$APP/env" && ! -e "$APP/.env" ]] || fatal 'Build tree contains environment credentials.'
NODE_VERSION="$(node --version)"
PYTHON_VERSION="$(/usr/bin/python3 --version 2>&1)"
PNPM_VERSION="$(pnpm --version)"
UV_VERSION="$(uv --version)"
BINARYEN_VERSION="$(wasm-opt --version 2>&1 | head -n1)"
BUILT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$APP/.build-info" <<EOF
format=immich-alpine-build-v1
alpine=$alpine_version
immich_ref=$IMMICH_REV
immich_commit=$SOURCE_SHA
alpine_release_tag=$IMMICH_ALPINE_RELEASE
source_repo=$SOURCE_REPO
extism_js_tag=$EXTISM_JS_TAG
node=$NODE_VERSION
python=$PYTHON_VERSION
pnpm=$PNPM_VERSION
uv=$UV_VERSION
binaryen=$BINARYEN_VERSION
built_at=$BUILT_AT
EOF
# Complete means application paths validated, NOT that services were run.
printf '%s\n' "$BUILT_AT" > "$APP/.build-complete"

STEP='create and verify release asset'
log 'Creating allowlisted installer-compatible archive...'
PARTIAL_ARCHIVE="$ARTIFACT_DIR/.${ASSET_NAME}.partial.$$"
# Only application and translations go into the archive, never runtime
# credentials, the build user home, database/media, cache or backups.
tar -C / -czf "$PARTIAL_ARCHIVE" var/lib/immich/app var/lib/immich/i18n
verify_archive "$PARTIAL_ARCHIVE"
mv -- "$PARTIAL_ARCHIVE" "$ARTIFACT_DIR/$ASSET_NAME"
PARTIAL_ARCHIVE=""
(
  cd "$ARTIFACT_DIR"
  sha256sum "$ASSET_NAME" > "$ASSET_NAME.sha256"
  sha256sum -c "$ASSET_NAME.sha256"
)
SUCCESS=1
log "Build successful: $IMMICH_REV ($SOURCE_SHA)"
log "Release asset: $ARTIFACT_DIR/$ASSET_NAME"
log "Checksum: $ARTIFACT_DIR/$ASSET_NAME.sha256"
