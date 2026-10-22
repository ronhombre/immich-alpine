#!/usr/bin/env bash
# Build Immich for Alpine 3.24 and publish a native APKv3 package.
# Run as root in a disposable Alpine builder; application compilation runs as immich.
# Optional signing: --signing-key /run/keys/immich.rsa (or APK_SIGNING_KEY).
set -Eeuo pipefail
umask 022

IMMICH_PATH=/var/lib/immich
APP="$IMMICH_PATH/app"
HOME_DIR="$IMMICH_PATH/home"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/immich-alpine-dist}"
IMMICH_REV="${IMMICH_REV:-}"
EXTISM_JS_TAG="${EXTISM_JS_TAG:-}"
IMMICH_EXPECTED_COMMIT="${IMMICH_EXPECTED_COMMIT:-}"
IMMICH_ALPINE_RELEASE="${IMMICH_ALPINE_RELEASE:-}"
SOURCE_REPO="${IMMICH_SOURCE_REPO:-https://github.com/immich-app/immich.git}"
APK_VERSION="${APK_VERSION:-}"
APK_RELEASE="${APK_RELEASE:-0}"
APK_SIGNING_KEY="${APK_SIGNING_KEY:-}"
APK_MAINTAINER="${APK_MAINTAINER:-}"
APK_DESCRIPTION="${APK_DESCRIPTION:-Immich photo and video management for Alpine Linux}"
APK_URL="${APK_URL:-https://immich.app}"
APK_BUNDLE_RUNTIME="${APK_BUNDLE_RUNTIME:-1}"
APK_RUNTIME_REPOSITORY="${APK_RUNTIME_REPOSITORY:-https://dl-cdn.alpinelinux.org/alpine/edge/community}"
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=4096}"

usage() {
  cat <<'HELP'
Usage (root, disposable Alpine 3.24 builder with apk-tools 3.x):
  IMMICH_REV=v3.2.0 bash build-immich-alpine.sh
  IMMICH_REV=v3.2.0 bash build-immich-alpine.sh --signing-key /run/keys/immich.rsa
  IMMICH_REV=v3.2.0 APK_SIGNING_KEY=/run/keys/immich.rsa bash build-immich-alpine.sh
  IMMICH_REV=v3.2.0 bash build-immich-alpine.sh --maintainer 'Your Name <you@example.com>'

  bash build-immich-alpine.sh --verify-apk /path/to/package.apk
  bash build-immich-alpine.sh --verify-apk /path/to/package.apk --keys-dir /path/to/public-keys
  bash build-immich-alpine.sh --verify-apk /path/to/unsigned.apk --allow-untrusted

Options:
  --signing-key PATH    Sign with an existing, unencrypted PEM private key.
                       The key may remain root-owned, mode 0600. It is never
                       copied into the package or passed to the build user.
  --maintainer TEXT     Public package contact, normally 'Name <email>'.
  --description TEXT   Human-readable package description.
  --url URL            Package information/project URL.
  --no-bundle-runtime  Skip embedded runtime APKs; targets must then supply
                       repositories containing the required native libraries.
  --package-only       Package an already completed app in the disposable builder.
                       Requires the same IMMICH_REV/APK_VERSION as that build.
                       Native runtime package versions must also match its metadata.
  --verify-apk PATH    Verify integrity/signature, metadata, and payload paths.
  --keys-dir PATH      Public-key directory for --verify-apk (default: system keys).
  --allow-untrusted    Integrity-only verification, for unsigned packages.

Environment:
  APK_VERSION          Alpine version; default: IMMICH_REV without its leading v.
                       Set explicitly for branches, commits, or prereleases
                       (example: APK_VERSION=3.2.0_rc1 for v3.2.0-rc.1).
  APK_RELEASE          Alpine packaging revision; default: 0. Bump on a rebuild
                       of the same upstream version.
  APK_SIGNING_KEY       Private-key path; --signing-key takes precedence.
  APK_MAINTAINER        Public maintainer contact; omitted when unset.
  APK_DESCRIPTION       Package description; default: Immich for Alpine description.
  APK_URL               Package information URL; default: https://immich.app.
  APK_BUNDLE_RUNTIME    1 (default): embed exact installed runtime APKs that are
                       unavailable in Alpine 3.24 stable. Set 0 to opt out.
  APK_RUNTIME_REPOSITORY Extra build-time source for those packages; default:
                       https://dl-cdn.alpinelinux.org/alpine/edge/community.
  ARTIFACT_DIR          Absolute output directory; default: /tmp/immich-alpine-dist.
  EXTISM_JS_TAG         Optional Extism release pin.
  IMMICH_EXPECTED_COMMIT Optional expected full upstream commit SHA.
  IMMICH_ALPINE_RELEASE Optional GitHub release tag recorded in build metadata.

Outputs (arch is x86_64 or aarch64):
  $ARTIFACT_DIR/immich-alpine-3.24-<arch>.apk
  $ARTIFACT_DIR/immich-alpine-3.24-<arch>.apk.sha256
  $ARTIFACT_DIR/immich-alpine-3.24-<arch>.apk.pub  (only when signed)

Required additional runtime APKs and their checksum manifest are INSIDE the
Immich APK under /usr/share/immich. Its signature protects the whole bundle.
Use the supplied installer: it extracts and verifies these original Alpine
APKs, then installs them with Immich in one APK transaction. There are no
separate dependency release assets. Ordinary dependencies come from stable.

With no key, the package is unsigned; installation requires an explicit
apk add --allow-untrusted. Signed installs require the matching public key
to be trusted in /etc/apk/keys. No private key is generated automatically.

Use the supplied workflow for build dependencies. Do NOT run on an Immich server.
The package contains application files, OpenRC services, and an example config;
credentials, photos, database contents, caches, and backups are never packaged.
HELP
}

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[build] %s\n' "$*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fatal "Missing command: $1"; }
valid_ref() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/+\-]*$ && "$1" != *..* ]]
}
validate_package_options() {
  local field value
  [[ "$APK_BUNDLE_RUNTIME" == 0 || "$APK_BUNDLE_RUNTIME" == 1 ]] || fatal 'APK_BUNDLE_RUNTIME must be 0 or 1.'
  for field in APK_MAINTAINER APK_DESCRIPTION APK_URL; do
    value="${!field}"
    [[ ! "$value" =~ [[:cntrl:]] ]] || fatal "$field must be a single line without control characters."
  done
  [[ -n "$APK_DESCRIPTION" ]] || fatal 'APK_DESCRIPTION must not be empty.'
  [[ "$APK_URL" =~ ^https?://[^[:space:]]+$ ]] || fatal 'APK_URL must be an HTTP(S) project URL.'
  if (( APK_BUNDLE_RUNTIME )); then
    [[ "$APK_RUNTIME_REPOSITORY" =~ ^https://[^[:space:]]+$ ]] || fatal 'APK_RUNTIME_REPOSITORY must be one HTTPS repository URL.'
  fi
}

# Record full Alpine versions, including package revisions, for the native
# runtime roots. --package-only must use the same roots as the application build.
runtime_apk_versions() {
  apk query --from installed --format json --fields name,version \
    vips vips-cpp vips-jxl libraw | python3 -c '
import json, re, sys
rows = json.load(sys.stdin)
roots = {"vips", "vips-cpp", "vips-jxl", "libraw"}
if not isinstance(rows, list) or len(rows) != len(roots):
    raise SystemExit("Cannot identify all four installed native runtime packages")
versions = {row["name"]: row["version"] for row in rows}
if set(versions) != roots:
    raise SystemExit("Unexpected installed native runtime package metadata")
for name in sorted(versions):
    version = versions[name]
    if not re.fullmatch(r"[0-9][0-9a-z._]*-r[0-9]+", version):
        raise SystemExit("Invalid native runtime package version: " + name)
    print("apk_runtime_" + name + "=" + version)
'
}

# Validate staged or extracted bytes without sourcing anything from the package.
validate_payload() {
  python3 - "$1" <<'PY'
from pathlib import Path
import hashlib, os, re, stat, sys
root = Path(sys.argv[1])
app = root / 'var/lib/immich/app'
def fail(message):
    raise SystemExit('Invalid APK payload: ' + message)
files = [
    'start.sh', 'dist/main.js', 'machine-learning/start.sh',
    'machine-learning/log_conf.json', 'machine-learning/immich_ml/gunicorn_conf.py',
    'plugins/immich-plugin-core/manifest.json', 'geodata/cities500.txt',
    '.build-info', '.build-complete',
]
for name in files:
    p = app / name
    if not p.is_file() or p.is_symlink():
        fail('missing regular application file: ' + name)
for name in ('www', 'i18n', 'machine-learning/immich_ml', 'machine-learning/venv'):
    p = app / name
    if not p.is_dir() or p.is_symlink():
        fail('missing application directory: ' + name)
for name in ('machine-learning/venv/bin/python', 'machine-learning/venv/bin/gunicorn'):
    if not os.path.lexists(app / name):
        fail('missing virtualenv executable: ' + name)
for name in ('start.sh', 'machine-learning/start.sh'):
    if not os.stat(app / name).st_mode & 0o111:
        fail('launcher is not executable: ' + name)
for name in ('etc/init.d/immich', 'etc/init.d/immich-ml',
             'usr/share/immich/immich.env.example', 'usr/share/immich/runtime-apks.sha256'):
    p = root / name
    if not p.is_file() or p.is_symlink():
        fail('missing package support file: ' + name)
link = root / 'var/lib/immich/i18n'
if not link.is_symlink() or os.readlink(link) != 'app/i18n':
    fail('i18n must be the relative symlink app/i18n')
for name in ('upload', 'machine-learning/upload'):
    p = app / name
    if not p.is_symlink() or os.readlink(p) != '/var/lib/immich/upload':
        fail(name + ' must link to the external upload directory')
parents = {'etc', 'etc/init.d', 'usr', 'usr/share', 'usr/share/immich',
           'var', 'var/lib', 'var/lib/immich', 'var/lib/immich/app'}
support = {'etc/init.d/immich', 'etc/init.d/immich-ml',
           'usr/share/immich/immich.env.example', 'usr/share/immich/runtime-apks.sha256',
           'var/lib/immich/i18n'}
bundle = root / 'usr/share/immich/runtime-apks'
if not bundle.is_dir() or bundle.is_symlink():
    fail('missing regular embedded runtime directory')
parents.add('usr/share/immich/runtime-apks')
seen = set()
for line in (root / 'usr/share/immich/runtime-apks.sha256').read_text().splitlines():
    match = re.fullmatch(r'([0-9a-f]{64})  ([a-z0-9][a-z0-9+_.-]*-[0-9][0-9a-z._]*-r[0-9]+\.(?:x86_64|aarch64)\.apk)', line)
    if not match:
        fail('invalid embedded runtime manifest entry')
    expected, filename = match.groups()
    if '..' in filename or filename in seen:
        fail('unsafe or duplicate embedded runtime filename: ' + filename)
    seen.add(filename)
    p = bundle / filename
    if not p.is_file() or p.is_symlink():
        fail('missing regular embedded runtime APK: ' + filename)
    with p.open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual != expected:
        fail('embedded runtime APK checksum mismatch: ' + filename)
    support.add('usr/share/immich/runtime-apks/' + filename)
for base, dirs, names in os.walk(root, followlinks=False):
    for name in dirs + names:
        p = Path(base, name)
        rel = p.relative_to(root).as_posix()
        mode = p.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
            fail('unsupported file type: ' + rel)
        if rel not in parents | support and not rel.startswith('var/lib/immich/app/'):
            fail('unexpected path: ' + rel)
        if '.env' in p.relative_to(root).parts:
            fail('environment credentials: ' + rel)
        if rel in {'var/lib/immich/app/env', 'var/lib/immich/app/backups',
                   'var/lib/immich/app/cache', 'var/lib/immich/app/home'}:
            fail('runtime data: ' + rel)
PY
}

# apk extract never runs lifecycle scripts. Trust is checked before extraction.
verify_apk() (
  set -Eeuo pipefail
  local package="$1"; shift
  local check_dir
  [[ -f "$package" ]] || fatal "Package missing: $package"
  require_cmd apk
  require_cmd python3
  apk verify "$@" "$package"
  check_dir="$(mktemp -d)"
  trap 'rm -rf -- "$check_dir"' EXIT
  apk adbdump "$package" > "$check_dir/metadata"
  python3 - "$check_dir/metadata" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
m = re.search(r'^info:\n((?:[ \t].*\n|\n)*)', s, re.M)
if not m or not re.search(r'^  name: immich$', m[1], re.M):
    raise SystemExit('Expected APKv3 package named immich')
if not re.search(r'^  version: [0-9][A-Za-z0-9._]*-r[0-9]+$', m[1], re.M):
    raise SystemExit('Missing or invalid Immich package version')
if not re.search(r'^  arch: (x86_64|aarch64)$', m[1], re.M):
    raise SystemExit('Missing or unsupported Immich package architecture')
PY
  mkdir "$check_dir/root"
  apk extract "$@" --destination "$check_dir/root" "$package"
  validate_payload "$check_dir/root"
  log "APK verified: $package"
)

write_package_support() {
  local root="$1" scripts="$2"
  mkdir -p "$root/etc/init.d" "$root/usr/share/immich" "$scripts"
  cat > "$root/etc/init.d/immich" <<'OPENRC'
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
  cat > "$root/etc/init.d/immich-ml" <<'OPENRC'
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
  chmod 0755 "$root/etc/init.d/immich" "$root/etc/init.d/immich-ml"
  cat > "$root/usr/share/immich/immich.env.example" <<'ENV'
# Configure external PostgreSQL and Redis before starting Immich.
IMMICH_HOST=127.0.0.1
IMMICH_PORT=2283
DB_HOSTNAME=your-postgres-host
DB_PORT=5432
DB_USERNAME=immich
DB_PASSWORD=YOUR_STRONG_RANDOM_PW
DB_DATABASE_NAME=immich
REDIS_HOSTNAME=your-redis-host
REDIS_PORT=6379
REDIS_PASSWORD=your-redis-password
MACHINE_LEARNING_HOST=127.0.0.1
MACHINE_LEARNING_PORT=3003
MACHINE_LEARNING_WORKERS=1
MACHINE_LEARNING_WORKER_TIMEOUT=300
MACHINE_LEARNING_CACHE_FOLDER=/var/lib/immich/cache
TRANSFORMERS_CACHE=/var/lib/immich/cache
HF_HOME=/var/lib/immich/cache/hf-cache
NODE_OPTIONS="--max-old-space-size=512"
ENV
  cat > "$scripts/pre-install" <<'HOOK'
#!/bin/sh
set -eu
getent group immich >/dev/null 2>&1 || addgroup -S immich
if ! id immich >/dev/null 2>&1; then
    adduser -S -D -H -h /var/lib/immich/home -s /sbin/nologin -G immich immich
fi
HOOK
  cat > "$scripts/post-install" <<'HOOK'
#!/bin/sh
set -eu
for path in /var/lib/immich/home /var/lib/immich/upload /var/lib/immich/cache /var/log/immich; do
    install -d -m 0750 -o immich -g immich "$path"
done
if [ ! -e /var/lib/immich/env ]; then
    [ ! -L /var/lib/immich/env ] || { echo 'Dangling env symlink; fix it before starting Immich.' >&2; exit 1; }
    install -m 0600 -o immich -g immich /usr/share/immich/immich.env.example /var/lib/immich/env
fi
echo 'Immich installed. Configure /var/lib/immich/env, then start immich-ml and immich with rc-service.'
echo 'Enable boot startup with: rc-update add immich-ml default; rc-update add immich default'
HOOK
  cat > "$scripts/stop-services" <<'HOOK'
#!/bin/sh
set -eu
for service in immich immich-ml; do
    if [ -x "/etc/init.d/$service" ]; then
        rc-service "$service" stop 2>/dev/null || true
        if rc-service "$service" status >/dev/null 2>&1; then
            echo "ERROR: Could not stop $service. Stop it manually before continuing." >&2
            exit 1
        fi
    fi
done
HOOK
  cat > "$scripts/post-deinstall" <<'HOOK'
#!/bin/sh
for service in immich immich-ml; do
    rc-update del "$service" default >/dev/null 2>&1 || true
done
# Account, credentials, media, caches, and backups deliberately remain.
exit 0
HOOK
  chmod 0755 "$scripts/"*
}

# Redistribute only installed runtime packages absent from Alpine 3.24's current
# stable repositories. Preserve each original APK and Alpine signature unchanged.
# $PKG_WORK is a private temporary directory owned/cleaned by package_app's caller.
bundle_runtime_apks() {
  local bundle_dir="$1" manifest_path="$2" work name version asset
  local -a runtime_roots=(vips vips-cpp vips-jxl libraw)
  local -a closure_names=() constraints=()
  [[ -d "$PKG_WORK" && -n "$APK_ARCH" ]] || fatal 'Runtime bundling requires package staging and architecture.'
  work="$PKG_WORK/runtime-bundle"
  mkdir -m 0700 "$work"
  mkdir -p "$bundle_dir" "$work/fetched"
  : > "$manifest_path"
  printf '%s\n' \
    'https://dl-cdn.alpinelinux.org/alpine/v3.24/main' \
    'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' > "$work/stable.repositories"
  cp "$work/stable.repositories" "$work/fetch.repositories"
  # Treat this value as one repository URL, never as repository-file directives.
  [[ "${APK_RUNTIME_REPOSITORY:-https://dl-cdn.alpinelinux.org/alpine/edge/community}" =~ ^https://[^[:space:]]+$ ]] || \
    fatal 'APK_RUNTIME_REPOSITORY must be one HTTPS repository URL.'
  printf '%s\n' "${APK_RUNTIME_REPOSITORY:-https://dl-cdn.alpinelinux.org/alpine/edge/community}" >> "$work/fetch.repositories"

  log 'Selecting the installed libvips/LibRaw runtime dependency closure...'
  apk query --from installed --recursive --format json --fields name,version \
    "${runtime_roots[@]}" > "$work/installed.json"
  python3 - "$work" <<'PY'
import json, re, sys
from pathlib import Path
work = Path(sys.argv[1])
rows = json.loads((work / 'installed.json').read_text())
if not isinstance(rows, list) or not rows:
    raise SystemExit('Empty installed runtime dependency closure')
packages = {}
for row in rows:
    name, version = row.get('name', ''), row.get('version', '')
    if not re.fullmatch(r'[a-z0-9][a-z0-9+_.-]*', name):
        raise SystemExit('Invalid installed runtime package name')
    if not re.fullmatch(r'[0-9][A-Za-z0-9._+-]*', version):
        raise SystemExit('Invalid installed runtime package version: ' + name)
    if name in packages and packages[name] != version:
        raise SystemExit('Multiple installed versions in runtime closure: ' + name)
    packages[name] = version
if not {'vips', 'vips-cpp', 'vips-jxl', 'libraw'} <= packages.keys():
    raise SystemExit('Missing installed libvips/LibRaw runtime root')
(work / 'names').write_text(''.join(name + '\n' for name in sorted(packages)))
(work / 'constraints').write_text(''.join(name + '=' + packages[name] + '\n' for name in sorted(packages)))
PY
  mapfile -t closure_names < "$work/names"
  mapfile -t constraints < "$work/constraints"
  # query may return success with partial JSON when a repository cannot be
  # opened. Missing package names are silent; repository warnings are not.
  if ! apk query --quiet --no-cache --from repositories \
      --repositories-file "$work/stable.repositories" --all-matches \
      --format json --fields name,version "${closure_names[@]}" \
      > "$work/stable.json" 2> "$work/stable.stderr"; then
    cat "$work/stable.stderr" >&2
    fatal 'Could not read Alpine 3.24 runtime repository metadata.'
  fi
  if [[ -s "$work/stable.stderr" ]]; then
    cat "$work/stable.stderr" >&2
    fatal 'Incomplete Alpine 3.24 repository metadata; refusing runtime selection.'
  fi
  python3 - "$work" <<'PY'
import json, sys
from pathlib import Path
work = Path(sys.argv[1])
installed = json.loads((work / 'installed.json').read_text())
stable = json.loads((work / 'stable.json').read_text())
if not isinstance(stable, list) or not stable:
    raise SystemExit('No stable repository metadata; refusing an unbounded runtime bundle')
available = {(p['name'], p['version']) for p in stable}
selected = sorted({(p['name'], p['version']) for p in installed} - available)
for name, version in selected:
    if any(name == p or name.startswith(p + '-') for p in ('musl', 'apk-tools', 'alpine-baselayout', 'busybox')):
        raise SystemExit('Runtime snapshot would replace core package ' + name +
                         '; rebuild the newer libraries against Alpine 3.24 instead')
(work / 'selected.tsv').write_text(''.join(name + '\t' + version + '\n' for name, version in selected))
PY
  if [[ ! -s "$work/selected.tsv" ]]; then
    log 'All installed runtime packages are available from Alpine 3.24; no embedded runtime APKs required.'
    return 0
  fi

  # Exact constraints keep the download identical to the installed build inputs.
  # --recursive is required for version constraints with apk-tools 3.x. Fetching
  # this closure never includes unrelated builder packages or a home directory.
  apk fetch --no-cache --from repositories --recursive \
    --repositories-file "$work/fetch.repositories" --output "$work/fetched" \
    "${constraints[@]}"
  while IFS=$'\t' read -r name version; do
    [[ -f "$work/fetched/$name-$version.apk" && ! -L "$work/fetched/$name-$version.apk" ]] || \
      fatal "Missing exact runtime APK: $name=$version"
    # No --allow-untrusted: each original runtime APK must pass Alpine key trust.
    apk verify "$work/fetched/$name-$version.apk"
    asset="$name-$version.$APK_ARCH.apk"
    install -m 0644 "$work/fetched/$name-$version.apk" "$bundle_dir/$asset"
    (cd "$bundle_dir"; sha256sum "$asset") >> "$manifest_path"
    log "Embedding runtime APK: $asset"
  done < "$work/selected.tsv"
}

# Called only by the root parent after all upstream build commands have finished.
package_app() {
  local stage scripts runtime_dir runtime_manifest source_sha build_ref
  local node_major vips_version libraw_version dependency_list current_runtime_versions recorded_runtime_versions
  local -a signing_args=() verify_args=(--allow-untrusted) metadata_args=()
  [[ -f "$APP/.build-complete" && -f "$APP/.build-info" ]] || fatal 'No completed app to package.'
  source_sha="$(sed -n 's/^immich_commit=//p' "$APP/.build-info")"
  build_ref="$(sed -n 's/^immich_ref=//p' "$APP/.build-info")"
  [[ "$source_sha" =~ ^[a-fA-F0-9]{40}$ && "$build_ref" == "$IMMICH_REV" ]] || fatal 'Build metadata does not match IMMICH_REV.'
  [[ "$(sed -n 's/^apk_version=//p' "$APP/.build-info")" == "$APK_VERSION-r$APK_RELEASE" ]] || fatal 'APK_VERSION/APK_RELEASE must match the completed build.'
  node_major="$(sed -n 's/^node=//p' "$APP/.build-info")"
  [[ "$node_major" =~ ^v([0-9]+)\. ]] || fatal 'Cannot determine Node major version.'
  node_major="${BASH_REMATCH[1]}"
  vips_version="$(sed -n 's/^vips=//p' "$APP/.build-info")"
  libraw_version="$(sed -n 's/^libraw=//p' "$APP/.build-info")"
  [[ "$vips_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$libraw_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal 'Missing/invalid native-library versions in build metadata.'
  current_runtime_versions="$(runtime_apk_versions | LC_ALL=C sort)"
  recorded_runtime_versions="$(sed -n '/^apk_runtime_/p' "$APP/.build-info" | LC_ALL=C sort)"
  [[ "$current_runtime_versions" == "$recorded_runtime_versions" ]] || \
    fatal 'Installed native runtime packages differ from, or are missing in, build metadata. Rebuild the application before packaging.'

  PKG_WORK="$(mktemp -d /tmp/immich-apk.XXXXXXXX)"
  stage="$PKG_WORK/root"
  scripts="$PKG_WORK/scripts"
  runtime_dir="$PKG_WORK/runtime-apks"
  runtime_manifest="$PKG_WORK/runtime-apks.sha256"
  mkdir "$runtime_dir"
  : > "$runtime_manifest"
  if (( APK_BUNDLE_RUNTIME )); then
    bundle_runtime_apks "$runtime_dir" "$runtime_manifest"
  fi
  mkdir -p "$stage/var/lib/immich"
  chmod 0755 "$stage"
  cp -a "$APP" "$stage/var/lib/immich/app"
  ln -s app/i18n "$stage/var/lib/immich/i18n"
  write_package_support "$stage" "$scripts"
  install -m 0644 "$runtime_manifest" "$stage/usr/share/immich/runtime-apks.sha256"
  cp -a "$runtime_dir" "$stage/usr/share/immich/runtime-apks"
  # Never embed the builder account's numeric UID/GID or dereference symlinks.
  python3 - "$stage" <<'PY'
from pathlib import Path
import os, stat, sys
root = Path(sys.argv[1])
for base, dirs, names in os.walk(root, followlinks=False):
    for p in [Path(base)] + [Path(base, name) for name in dirs + names]:
        mode = p.lstat().st_mode
        os.chown(p, 0, 0, follow_symlinks=False)
        if not stat.S_ISLNK(mode):
            os.chmod(p, 0o755 if stat.S_ISDIR(mode) or mode & 0o111 else 0o644)
PY
  validate_payload "$stage"

  dependency_list="apk-tools>=3.0.0 busybox openrc bash nodejs~$node_major python3~3.14"
  dependency_list+=' ffmpeg7 perl perl-compress-raw-zlib perl-compress-raw-bzip2'
  dependency_list+=' abseil-cpp abseil-cpp-flags-marshalling'
  dependency_list+=" vips>=$vips_version vips-cpp>=$vips_version vips-jxl>=$vips_version libraw>=$libraw_version"
  dependency_list+=' py3-opencv py3-onnxruntime py3-yaml py3-shapely'
  dependency_list+=' postgresql-client util-linux lcms2 mesa-gl geos curl'
  if [[ -n "$APK_SIGNING_KEY" ]]; then
    signing_args=(--sign-key "$APK_SIGNING_KEY")
    mkdir "$PKG_WORK/keys"
    openssl pkey -in "$APK_SIGNING_KEY" -passin pass: -pubout \
      -out "$PKG_WORK/keys/$ASSET_NAME.pub"
    verify_args=(--keys-dir "$PKG_WORK/keys")
    log 'Creating signed Alpine package...'
  else
    log 'Creating unsigned Alpine package (installation requires --allow-untrusted)...'
  fi
  [[ -z "$APK_MAINTAINER" ]] || metadata_args+=(--info "maintainer:$APK_MAINTAINER")
  # Keep parent-directory entries, but never package the temporary root's mode.
  # Native mkpkg constructs all APKv3 metadata, file hashes, and signatures.
  apk mkpkg --compat 3.0.0_pre3 \
    --files "$stage" \
    --info 'name:immich' \
    --info "version:$APK_VERSION-r$APK_RELEASE" \
    --info "arch:$APK_ARCH" \
    --info "description:$APK_DESCRIPTION" \
    --info "url:$APK_URL" \
    --info 'license:AGPL-3.0-only' \
    --info 'origin:immich' \
    --info "repo-commit:$source_sha" \
    --info "build-time:$(date -u +%s)" \
    --info "depends:$dependency_list" \
    --script "pre-install:$scripts/pre-install" \
    --script "post-install:$scripts/post-install" \
    --script "pre-upgrade:$scripts/stop-services" \
    --script "post-upgrade:$scripts/post-install" \
    --script "pre-deinstall:$scripts/stop-services" \
    --script "post-deinstall:$scripts/post-deinstall" \
    --output "$PKG_WORK/$ASSET_NAME" "${metadata_args[@]}" "${signing_args[@]}"
  verify_apk "$PKG_WORK/$ASSET_NAME" "${verify_args[@]}"
  # Runtime APKs are already inside the signed payload. Publish one APK only.
  if [[ -n "$APK_SIGNING_KEY" ]]; then
    install -m 0644 "$PKG_WORK/keys/$ASSET_NAME.pub" "$ARTIFACT_DIR/$ASSET_NAME.pub"
  fi
  install -m 0644 "$PKG_WORK/$ASSET_NAME" "$ARTIFACT_DIR/.$ASSET_NAME.partial"
  mv -- "$ARTIFACT_DIR/.$ASSET_NAME.partial" "$ARTIFACT_DIR/$ASSET_NAME"
  (
    cd "$ARTIFACT_DIR"
    sha256sum "$ASSET_NAME" > "$ASSET_NAME.sha256"
    sha256sum -c "$ASSET_NAME.sha256"
  )
  PUBLISH_SUCCESS=1
  log "Build successful: $IMMICH_REV ($source_sha), APK $APK_VERSION-r$APK_RELEASE [$APK_ARCH]"
  log "Release asset: $ARTIFACT_DIR/$ASSET_NAME"
  log "Checksum: $ARTIFACT_DIR/$ASSET_NAME.sha256"
  [[ -z "$APK_SIGNING_KEY" ]] || log "Public key: $ARTIFACT_DIR/$ASSET_NAME.pub"
}

MODE=build
VERIFY_FILE=""
VERIFY_KEYS=""
ALLOW_UNTRUSTED=0
while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --build) MODE=build; shift ;;
    --build-app) MODE=build-app; shift ;;
    --package-only) MODE='package-only'; shift ;;
    --signing-key|--sign-key)
      (( $# >= 2 )) && [[ -n "$2" ]] || fatal "$1 requires a private-key path"
      APK_SIGNING_KEY="$2"; shift 2 ;;
    --maintainer|--description|--url)
      (( $# >= 2 )) && [[ -n "$2" ]] || fatal "$1 requires a value"
      case "$1" in
        --maintainer) APK_MAINTAINER="$2" ;;
        --description) APK_DESCRIPTION="$2" ;;
        --url) APK_URL="$2" ;;
      esac
      shift 2 ;;
    --no-bundle-runtime) APK_BUNDLE_RUNTIME=0; shift ;;
    --verify-apk)
      (( $# >= 2 )) && [[ -n "$2" ]] || fatal '--verify-apk requires a path'
      MODE=verify; VERIFY_FILE="$2"; shift 2 ;;
    --keys-dir)
      (( $# >= 2 )) && [[ -n "$2" ]] || fatal '--keys-dir requires a directory'
      VERIFY_KEYS="$2"; shift 2 ;;
    --allow-untrusted) ALLOW_UNTRUSTED=1; shift ;;
    *) fatal "Unexpected argument: $1 (see --help)" ;;
  esac
done
if [[ "$MODE" == verify ]]; then
  verify_options=()
  [[ -z "$VERIFY_KEYS" ]] || verify_options+=(--keys-dir "$VERIFY_KEYS")
  (( ! ALLOW_UNTRUSTED )) || verify_options+=(--allow-untrusted)
  verify_apk "$VERIFY_FILE" "${verify_options[@]}"
  exit 0
fi
[[ -z "$VERIFY_KEYS" && "$ALLOW_UNTRUSTED" == 0 ]] || fatal '--keys-dir/--allow-untrusted are only valid with --verify-apk.'
validate_package_options
[[ -n "$IMMICH_REV" ]] || fatal 'Set IMMICH_REV to the upstream Immich tag/ref.'
valid_ref "$IMMICH_REV" || fatal 'Unsafe IMMICH_REV.'
[[ -z "$EXTISM_JS_TAG" ]] || valid_ref "$EXTISM_JS_TAG" || fatal 'Unsafe EXTISM_JS_TAG.'
[[ -z "$IMMICH_EXPECTED_COMMIT" || "$IMMICH_EXPECTED_COMMIT" =~ ^[a-fA-F0-9]{40}$ ]] || fatal 'IMMICH_EXPECTED_COMMIT must be a full 40-digit SHA.'
[[ -z "$IMMICH_ALPINE_RELEASE" ]] || valid_ref "$IMMICH_ALPINE_RELEASE" || fatal 'Unsafe IMMICH_ALPINE_RELEASE.'
[[ "$ARTIFACT_DIR" = /* ]] || fatal 'ARTIFACT_DIR must be an absolute path.'
[[ "$APK_RELEASE" =~ ^(0|[1-9][0-9]*)$ ]] || fatal 'APK_RELEASE must be a nonnegative integer.'
APK_VERSION="${APK_VERSION:-${IMMICH_REV#v}}"

[[ ! -L "$IMMICH_PATH" && ! -L "$HOME_DIR" && ! -L "$APP" ]] || fatal 'Refusing symlinked build root/home/app path.'
[[ -f /etc/alpine-release ]] || fatal 'Builder must run on Alpine Linux.'
read -r alpine_version </etc/alpine-release
[[ "$alpine_version" == 3.24.* ]] || fatal "Expected Alpine 3.24, found $alpine_version."
require_cmd apk
[[ "$(apk --version)" =~ apk-tools[[:space:]]3\. ]] || fatal 'apk-tools 3.x is required for native APKv3 packaging.'
apk version --check "$APK_VERSION-r$APK_RELEASE" || fatal 'Invalid Alpine version. Set APK_VERSION explicitly (e.g. 3.2.0_rc1).'
APK_ARCH="$(apk --print-arch)"
case "$APK_ARCH" in x86_64|aarch64) ;; *) fatal "Unsupported architecture: $APK_ARCH" ;; esac
ASSET_NAME="immich-alpine-3.24-$APK_ARCH.apk"

# Never run this build process against an actual installation.
for marker in "$IMMICH_PATH/env" "$IMMICH_PATH/.immich-version" "$IMMICH_PATH/backups" "$IMMICH_PATH/.upgrade-pending"; do
  [[ ! -e "$marker" && ! -L "$marker" ]] || fatal "Detected runtime state at $marker; run only in a disposable builder."
done

if [[ "$MODE" != build-app ]]; then
  [[ "$EUID" == 0 ]] || fatal 'Run as root in a disposable Alpine builder; compilation is delegated to immich.'
  for tool in python3 readlink sha256sum node; do require_cmd "$tool"; done
  ARTIFACT_DIR="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$ARTIFACT_DIR")"
  [[ "$ARTIFACT_DIR" != / && "$ARTIFACT_DIR" != "$IMMICH_PATH" && "$ARTIFACT_DIR" != "$IMMICH_PATH/"* ]] || fatal 'ARTIFACT_DIR must be outside /var/lib/immich and must not be /. '
  if [[ -n "$APK_SIGNING_KEY" ]]; then
    require_cmd openssl
    APK_SIGNING_KEY="$(readlink -f -- "$APK_SIGNING_KEY")"
    [[ -f "$APK_SIGNING_KEY" && -r "$APK_SIGNING_KEY" ]] || fatal 'Signing key is not a readable regular file.'
    [[ "$APK_SIGNING_KEY" != "$IMMICH_PATH/"* && "$APK_SIGNING_KEY" != "$ARTIFACT_DIR/"* ]] || fatal 'Keep the signing key outside the application and output directories.'
    openssl pkey -in "$APK_SIGNING_KEY" -passin pass: -check -noout >/dev/null 2>&1 || fatal 'Signing key must be a valid, unencrypted PEM private key.'
  fi
  mkdir -p "$ARTIFACT_DIR"
  [[ ! -L "$ARTIFACT_DIR/runtime-apks" ]] || fatal 'Refusing a symlinked runtime APK output directory.'
  # Also remove external runtime artifacts left by an older builder. Keep
  # other architectures' assets intact when builds share an output directory.
  remove_public_assets() {
    rm -f -- "$ARTIFACT_DIR/$ASSET_NAME" "$ARTIFACT_DIR/$ASSET_NAME.sha256" \
      "$ARTIFACT_DIR/$ASSET_NAME.pub" "$ARTIFACT_DIR/.$ASSET_NAME.partial" \
      "$ARTIFACT_DIR/$ASSET_NAME.runtime-apks.sha256" \
      "$ARTIFACT_DIR/runtime-apks/"*".$APK_ARCH.apk"
  }
  remove_public_assets
  PKG_WORK=""
  tmp_extism=""
  PUBLISH_SUCCESS=0
  root_cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "$PKG_WORK" ]] || rm -rf -- "$PKG_WORK"
    [[ -z "$tmp_extism" ]] || rm -rf -- "$tmp_extism"
    if (( status != 0 || ! PUBLISH_SUCCESS )); then
      remove_public_assets
    fi
    exit "$status"
  }
  trap root_cleanup EXIT
  if [[ "$MODE" == package-only ]]; then
    package_app
    exit 0
  fi

  for tool in curl python3 su readlink; do require_cmd "$tool"; done
  log 'Installing Binaryen from Alpine 3.24 community repository...'
  apk add --no-cache binaryen openssl
  for tool in wasm-merge wasm-opt; do require_cmd "$tool"; done
  if [[ -z "$EXTISM_JS_TAG" ]]; then
    log 'EXTISM_JS_TAG unset; resolving latest Extism release (pin it for reproducibility).'
    EXTISM_JS_TAG="$(curl -fsSL --retry 3 https://api.github.com/repos/extism/js-pdk/releases/latest | \
      python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    valid_ref "$EXTISM_JS_TAG" || fatal 'Invalid Extism release tag from GitHub.'
  fi
  extism_url="https://github.com/extism/js-pdk/releases/download/${EXTISM_JS_TAG}/extism-js-${APK_ARCH}-linux-${EXTISM_JS_TAG}.gz"
  tmp_extism="$(mktemp -d)"
  log "Installing extism-js $EXTISM_JS_TAG ($APK_ARCH)..."
  curl -fL --retry 3 --retry-delay 2 -o "$tmp_extism/extism-js.gz" "$extism_url"
  gzip -t "$tmp_extism/extism-js.gz"
  gzip -dc "$tmp_extism/extism-js.gz" > "$tmp_extism/extism-js"
  install -m 0755 "$tmp_extism/extism-js" /usr/local/bin/extism-js
  /usr/local/bin/extism-js --help >/dev/null 2>&1 || fatal 'extism-js executable check failed; check architecture and ELF loader compatibility.'
  rm -rf -- "$tmp_extism"
  tmp_extism=""
  if ! id immich >/dev/null 2>&1; then
    getent group immich >/dev/null 2>&1 || addgroup -S immich
    adduser -S -D -h "$HOME_DIR" -s /sbin/nologin -G immich immich
  fi
  mkdir -p "$IMMICH_PATH" "$HOME_DIR"
  chown immich:immich "$IMMICH_PATH" "$HOME_DIR"
  SCRIPT_PATH="$(readlink -f -- "$0")"
  [[ -f "$SCRIPT_PATH" ]] || fatal "Cannot resolve script path: $0"
  log "Starting unprivileged build as immich (source $IMMICH_REV)..."
  # Explicit allowlist: no signing key, CI secret, or root environment reaches
  # upstream install/build scripts. %q quotes every value for su's Bash command.
  printf -v cmd 'exec env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin IMMICH_REV=%q EXTISM_JS_TAG=%q IMMICH_EXPECTED_COMMIT=%q IMMICH_ALPINE_RELEASE=%q IMMICH_SOURCE_REPO=%q APK_VERSION=%q APK_RELEASE=%q NODE_OPTIONS=%q bash %q --build-app' \
    "$IMMICH_REV" "$EXTISM_JS_TAG" "$IMMICH_EXPECTED_COMMIT" "$IMMICH_ALPINE_RELEASE" "$SOURCE_REPO" "$APK_VERSION" "$APK_RELEASE" "$NODE_OPTIONS" "$SCRIPT_PATH"
  su -s /bin/bash immich -c "$cmd"
  package_app
  exit 0
fi

[[ "$(id -un)" == immich ]] || fatal '--build-app is reserved for the unprivileged immich builder.'
[[ -z "$APK_SIGNING_KEY" ]] || fatal 'Do not pass signing keys to the unprivileged build phase.'
for tool in git curl python3 uv pnpm node npm gzip unzip wget pkg-config wasm-merge wasm-opt extism-js; do
  require_cmd "$tool"
done
extism-js --help >/dev/null 2>&1 || fatal 'extism-js fails under immich user.'
[[ -d "$HOME_DIR" && -w "$HOME_DIR" && -w "$IMMICH_PATH" ]] || fatal 'Builder home/target not writable by immich.'
export HOME="$HOME_DIR"
export PATH="/usr/local/bin:$HOME/.local/bin:$PATH"
export SHARP_FORCE_GLOBAL_LIBVIPS=true
export SHARP_USE_GLOBAL_LIBVIPS=true
export UV_PYTHON_PREFERENCE=only-system
umask 022

[[ ! -L "$APP" ]] || fatal "Refusing to replace symlinked app path: $APP"

WORK="$(mktemp -d /tmp/immich-src.XXXXXXXX)"
SERVER_PRUNED="$(mktemp -d /tmp/immich-prod.XXXXXXXX)"
SUCCESS=0
STEP='initialization'
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf -- "$WORK" "$SERVER_PRUNED"
  if (( status != 0 )) && (( ! SUCCESS )); then
    rm -f -- "$APP/.build-complete"
    log "FAILED at: $STEP (exit $status); no release asset was published."
  fi
  exit "$status"
}
trap cleanup EXIT

STEP='checkout'
log "Cloning Immich $IMMICH_REV..."
git init -q "$WORK/source"
cd "$WORK/source"
git remote add origin "$SOURCE_REPO"
git fetch --depth 1 origin "$IMMICH_REV"
git checkout --detach FETCH_HEAD
SOURCE_SHA="$(git rev-parse --verify 'HEAD^{commit}')"
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
# These files must work after apk installs the app on a new server.
cat > "$APP/start.sh" <<'SERVER_START'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a
# shellcheck disable=SC1091
source /var/lib/immich/env
set +a
# Writable runtime directories are created by the package install hook.
# The i18n link is package-owned; the fallback also supports legacy installs.
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
VIPS_VERSION="$(pkg-config --modversion vips-cpp)"
LIBRAW_VERSION="$(pkg-config --modversion libraw)"
RUNTIME_APK_VERSIONS="$(runtime_apk_versions)"
BINARYEN_VERSION="$(wasm-opt --version 2>&1 | head -n1)"
BUILT_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$APP/.build-info" <<EOF
format=immich-alpine-build-v2
apk_format=3
apk_version=$APK_VERSION-r$APK_RELEASE
apk_arch=$APK_ARCH
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
vips=$VIPS_VERSION
libraw=$LIBRAW_VERSION
$RUNTIME_APK_VERSIONS
binaryen=$BINARYEN_VERSION
built_at=$BUILT_AT
EOF

printf '%s\n' "$BUILT_AT" > "$APP/.build-complete"

SUCCESS=1
log "Application build complete: $IMMICH_REV ($SOURCE_SHA); returning to root for packaging."
