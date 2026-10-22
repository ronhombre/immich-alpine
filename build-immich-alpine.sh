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
APK_RELEASE="${APK_RELEASE:-1}"
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
  IMMICH_REV=v3.3.5 bash build-immich-alpine.sh
  IMMICH_REV=v3.3.5 bash build-immich-alpine.sh --signing-key /run/keys/immich.rsa
  IMMICH_REV=v3.3.5 APK_SIGNING_KEY=/run/keys/immich.rsa bash build-immich-alpine.sh
  IMMICH_REV=v3.3.5 bash build-immich-alpine.sh --maintainer 'Your Name <you@example.com>'

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
  --no-bundle-runtime  Skip merging newer runtime files; targets must then supply
                       repositories containing the required native libraries.
  --package-only       Package an already completed app in the disposable builder.
                       Requires the same IMMICH_REV/APK_VERSION as that build;
                       APK_RELEASE may be increased for a packaging-only fix.
                       Native runtime package versions must also match its metadata.
  --verify-apk PATH    Verify integrity/signature, metadata, and payload paths.
  --keys-dir PATH      Public-key directory for --verify-apk (default: system keys).
  --allow-untrusted    Integrity-only verification, for unsigned packages.

Environment:
  APK_VERSION          Alpine version; default: IMMICH_REV without its leading v.
                       Set explicitly for branches, commits, or prereleases
                       (example: APK_VERSION=3.2.0_rc1 for v3.2.0-rc.1).
  APK_RELEASE          Alpine packaging revision; default: 1. Bump on a rebuild
                       of the same upstream version.
  APK_SIGNING_KEY       Private-key path; --signing-key takes precedence.
  APK_MAINTAINER        Public maintainer contact; omitted when unset.
  APK_DESCRIPTION       Package description; default: Immich for Alpine description.
  APK_URL               Package information URL; default: https://immich.app.
  APK_BUNDLE_RUNTIME    1 (default): merge verified runtime package files that are
                       unavailable in Alpine 3.24 stable. Set 0 to opt out.
  APK_RUNTIME_REPOSITORY Extra build-time source for those packages; default:
                       https://dl-cdn.alpinelinux.org/alpine/edge/community.
  ARTIFACT_DIR          Absolute output directory; default: /tmp/immich-alpine-dist.
  EXTISM_JS_TAG         Optional Extism release pin.
  IMMICH_EXPECTED_COMMIT Optional expected full upstream commit SHA.
  IMMICH_ALPINE_RELEASE Optional GitHub release tag recorded in build metadata.

Outputs (architecture remains in the package metadata):
  $ARTIFACT_DIR/immich-alpine-<version>-r<revision>.apk
  $ARTIFACT_DIR/immich-alpine-<version>-r<revision>.apk.sha256
  $ARTIFACT_DIR/immich-alpine-<version>-r<revision>.apk.pub  (only when signed)
  Use separate ARTIFACT_DIR values when building multiple architectures.

Required newer runtime files are part of the Immich APK itself. The package
declares their real package names, versions, shared-library provides, and
remaining dependencies. Install it directly with apk add ./immich-....apk.
Native APK hooks create the account/configuration, enable OpenRC services, and
handle service state and application/configuration backups on upgrades.
There are no nested dependency APKs or separate dependency release assets.
Ordinary dependencies come from Alpine 3.24 stable repositories.

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
  local runtime_paths
  runtime_paths="$(validate_bundled_runtime "$1")" || return
  python3 - "$1" "$runtime_paths" <<'PY'
from pathlib import Path
import os, stat, sys
root = Path(sys.argv[1])
app = root / 'var/lib/immich/app'
def fail(message):
    raise SystemExit('Invalid APK payload: ' + message)
if app.is_symlink() or not app.is_dir():
    fail('application root must be a regular directory')
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
             'usr/share/immich/immich.env.example', 'usr/share/immich/bundled-runtime.json'):
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
           'usr/share/immich/immich.env.example', 'usr/share/immich/bundled-runtime.json',
           'var/lib/immich/i18n'}
# Only exact paths whose original-package provenance, contents, permissions,
# and symlink targets passed validate_bundled_runtime are authorized here.
for name in sys.argv[2].splitlines():
    support.add(name)
    parents.update(p.as_posix() for p in Path(name).parents if p != Path('.'))
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
  apk adbdump --format json "$package" > "$check_dir/metadata"
  python3 - "$check_dir/metadata" <<'PY'
from pathlib import Path
import json, re, sys
data = json.loads(Path(sys.argv[1]).read_text())
info = data.get('info', {})
if info.get('name') != 'immich':
    raise SystemExit('Expected APKv3 package named immich')
if not re.fullmatch(r'[0-9][A-Za-z0-9._]*-r[0-9]+', info.get('version', '')):
    raise SystemExit('Missing or invalid Immich package version')
if info.get('arch') not in ('x86_64', 'aarch64'):
    raise SystemExit('Missing or unsupported Immich package architecture')
for action in ('pre-install', 'post-install', 'pre-upgrade', 'post-upgrade', 'pre-deinstall', 'post-deinstall'):
    script = data.get('scripts', {}).get(action, '')
    if not isinstance(script, str) or not script.startswith('#!/bin/sh\n'):
        raise SystemExit('Missing native APK lifecycle script: ' + action)
PY
  mkdir "$check_dir/root"
  apk extract "$@" --destination "$check_dir/root" "$package"
  validate_payload "$check_dir/root"
  python3 - "$check_dir/metadata" "$check_dir/root" <<'PY'
from pathlib import Path
import json, sys
package_metadata = json.loads(Path(sys.argv[1]).read_text())
info = package_metadata['info']
root = Path(sys.argv[2])
audit = json.loads((root / 'usr/share/immich/bundled-runtime.json').read_text())
if sorted(package_metadata.get('triggers', [])) != sorted(audit.get('triggers', [])):
    raise SystemExit('APK omits original runtime triggers')
controls = [{key: package[key] for key in ('name', 'version', 'scripts', 'triggers')}
            for package in audit['packages']]
expected_controls = 'BUNDLED_RUNTIME = ' + repr(controls)
actions = ['pre-install', 'post-install', 'pre-upgrade', 'post-upgrade', 'pre-deinstall', 'post-deinstall']
if audit.get('triggers'): actions.append('trigger')
for action in actions:
    if expected_controls not in package_metadata.get('scripts', {}).get(action, ''):
        raise SystemExit('APK hook omits original runtime callbacks: ' + action)
for field in ('provides', 'replaces'):
    if sorted(info.get(field, [])) != sorted(audit[field]):
        raise SystemExit('APK metadata does not declare its actual bundled runtime ' + field)
if not set(audit['depends']) <= set(info.get('depends', [])):
    raise SystemExit('APK metadata omits an external bundled-runtime dependency')
if info.get('license') != audit['license']:
    raise SystemExit('APK license metadata does not match its bundled runtime')
build_lines = (root / 'var/lib/immich/app/.build-info').read_text().splitlines()
if 'apk_version=' + info['version'] not in build_lines or 'apk_layout=native-merged-v1' not in build_lines:
    raise SystemExit('Application build metadata does not match this native APK')
PY
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
IMMICH_MEDIA_LOCATION=/var/lib/immich/upload
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
  # Inline the common implementation in all six APK hooks: pre-install cannot
  # rely on a helper from the package having been unpacked already.
  cat > "$scripts/lifecycle" <<'HOOK'
#!/bin/sh
set -eu
umask 077
base=/var/lib/immich
state=$base/.apk-state
backups=$base/backups
pending=$state/pending
prepared=$state/prepared
backup=''
source_version=''
restart_server=0
restart_ml=0
target_version=${1:-}
old_version=${2:-}
hook=${APK_SCRIPT:-}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
safe_dir() {
    [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -d "$1" ]; } || fail "Unsafe directory: $1"
}
safe_file() {
    [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; } || fail "Unsafe state/configuration file: $1"
}
valid_version() {
    case "$1" in ''|*[!A-Za-z0-9._+-]*) fail 'Invalid version in package lifecycle state.' ;; esac
}
guard_paths() {
    for path in /var /var/lib /var/log "$base" "$base/app" "$state" "$backups" \
        "$base/home" "$base/upload" "$base/cache" /var/log/immich; do
        safe_dir "$path"
    done
    for path in "$base/env" "$base/.immich-version" "$pending" "$prepared" \
        "$state/pending.new" "$state/prepared.new" "$state/version.new" \
        "$state/runtime-before.json" "$state/runtime-before.new"; do
        safe_file "$path"
    done
}
failed_hook() {
    result=$?
    trap - 0
    if [ "$result" -ne 0 ]; then
        printf 'ERROR: Immich %s failed. APK may have changed package files; no automatic rollback was performed.\n' "$hook" >&2
        if [ -n "$backup" ]; then
            printf 'ERROR: Snapshot/state retained: %s ; %s\n' "$backup" "$pending" >&2
        fi
        echo 'ERROR: Fix the reported problem, then use apk fix --reinstall immich with this APK available in the APK cache or a configured repository.' >&2
    fi
    exit "$result"
}
trap failed_hook 0

# Verified dependency control scripts are carried by the Immich APK's own hooks.
# Only read-only installed-package queries occur here; never apk add or downloads.
run_bundled_runtime_hooks() {
    python3 - "$@" <<'RUNTIME_HOOKS_PY'
from pathlib import Path
import fnmatch, glob, json, os, re, shlex, subprocess, sys, tempfile
BUNDLED_RUNTIME = None
phase, *changed = sys.argv[1:]
state = Path('/var/lib/immich/.apk-state')
snapshot = state / 'runtime-before.json'

def fail(message):
    raise SystemExit('Immich bundled runtime: ' + message)

def versions(data):
    if not isinstance(data, dict) or any(not isinstance(k, str) or not isinstance(v, str)
                                       for k, v in data.items()):
        fail('invalid saved runtime versions')
    return data

def read_regular(path):
    if path.is_symlink() or not path.is_file():
        fail('expected regular metadata file: ' + str(path))
    details = path.stat()
    if details.st_uid != 0 or details.st_mode & 0o022:
        fail('runtime metadata must be root-owned and not group/world-writable: ' + str(path))
    return json.loads(path.read_text())

def save_versions():
    # Keep original versions across an interrupted installation/upgrade retry.
    if os.path.lexists(snapshot):
        return versions(read_regular(snapshot))
    result = subprocess.run(['apk', 'query', '--from', 'installed', '--all-matches',
                             '--format', 'json', '--fields', 'name,version', '*'],
                            check=True, text=True, stdout=subprocess.PIPE)
    rows = json.loads(result.stdout)
    if not isinstance(rows, list): fail('invalid installed-package query result')
    saved = {row['name']: row['version'] for row in rows}
    previous = Path('/usr/share/immich/bundled-runtime.json')
    if os.path.lexists(previous):
        old = read_regular(previous)
        for package in old.get('packages', []):
            saved[package['name']] = package['version']
    versions(saved)
    temp = state / 'runtime-before.new'
    if os.path.lexists(temp):
        if temp.is_symlink() or not temp.is_file(): fail('unsafe temporary runtime state')
        temp.unlink()
    with temp.open('x') as stream:
        json.dump(saved, stream, sort_keys=True)
        stream.write('\n')
    os.chmod(temp, 0o600)
    temp.replace(snapshot)
    return saved

def invoke(package, action, arguments):
    script = package['scripts'].get(action)
    if not script: return
    # Run the original body with its own version arguments and shebang flags.
    # A subprocess isolates exit, cd, traps, and shell options from Immich's hook.
    interpreter = shlex.split(script.splitlines()[0][2:])
    if not interpreter or interpreter[0] not in ('/bin/sh', '/bin/ash'):
        fail('unsupported original runtime interpreter')
    with tempfile.TemporaryDirectory(prefix='immich-runtime-hook-') as directory:
        path = Path(directory) / (package['name'] + '.' + action)
        path.write_text(script)
        os.chmod(path, 0o700)
        env = dict(os.environ, APK_SCRIPT=action, APK_PACKAGE_NAME=package['name'],
                   APK_PACKAGE_VERSION=package['version'])
        print('Immich runtime: ' + package['name'] + '.' + action, flush=True)
        subprocess.run([*interpreter, str(path), *arguments], env=env, check=True)

def trigger(package, directories=None):
    if 'trigger' not in package['scripts']: return
    patterns = [pattern.removeprefix('+') for pattern in package['triggers']]
    if directories is None:
        matched = sorted({path for pattern in patterns for path in glob.glob(pattern)
                          if Path(path).is_dir()})
    else:
        matched = [path for path in directories
                   if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)]
    if matched: invoke(package, 'trigger', matched)

if BUNDLED_RUNTIME is None: fail('runtime callback metadata was not embedded')
if BUNDLED_RUNTIME:
    if phase in ('pre', 'post'):
        before = save_versions() if phase == 'pre' else versions(read_regular(snapshot))
        for package in BUNDLED_RUNTIME:
            old = before.get(package['name'])
            action = phase + ('-upgrade' if old is not None else '-install')
            arguments = [package['version']] + ([old] if old is not None else [])
            invoke(package, action, arguments)
        if phase == 'post':
            # Refresh loader caches before restarting Immich. APK also registers
            # the original trigger paths to handle later dependency changes.
            for package in BUNDLED_RUNTIME: trigger(package)
    elif phase == 'trigger':
        for package in BUNDLED_RUNTIME: trigger(package, changed)
    elif phase in ('pre-deinstall', 'post-deinstall'):
        for package in reversed(BUNDLED_RUNTIME): invoke(package, phase, [package['version']])
    else:
        fail('unknown runtime hook phase: ' + phase)
RUNTIME_HOOKS_PY
}

ensure_account() {
    grep -q '^immich:' /etc/group || addgroup -S immich
    if ! id -u immich >/dev/null 2>&1; then
        adduser -S -D -H -h "$base/home" -s /sbin/nologin -G immich immich
    fi
}
prepare_state() {
    guard_paths
    mkdir -p "$base" "$state" "$backups"
    chown 0:0 "$state" "$backups"
    chmod 0700 "$state" "$backups"
    # Protect root-written state even when migrating an older installer that
    # made the parent directory writable by the service account.
    chown 0:0 "$base"
    chmod 0755 "$base"
}
read_pending() {
    [ "$(awk 'END { print NR }' "$pending")" = 5 ] || fail 'Invalid pending APK upgrade record.'
    source_version=$(sed -n '1p' "$pending")
    saved_target=$(sed -n '2p' "$pending")
    backup_name=$(sed -n '3p' "$pending")
    restart_server=$(sed -n '4p' "$pending")
    restart_ml=$(sed -n '5p' "$pending")
    valid_version "$source_version"
    valid_version "$saved_target"
    case "$backup_name" in native-*) ;; *) fail 'Unexpected pending backup name.' ;; esac
    case "$backup_name" in *[!A-Za-z0-9-]*) fail 'Unsafe pending backup name.' ;; esac
    case "$restart_server:$restart_ml" in 0:0|0:1|1:0|1:1) ;; *) fail 'Invalid saved service state.' ;; esac
    backup=$backups/$backup_name
    safe_dir "$backup"
    for path in "$backup/app.tar" "$backup/env" "$backup/source.version" \
        "$backup/backup.complete" "$backup/native-format" "$backup/attempts.log" \
        "$backup/upgrade.success" "$backup/health.success"; do safe_file "$path"; done
    [ -f "$backup/backup.complete" ] && [ -f "$backup/app.tar" ] && \
        [ "$(cat "$backup/native-format")" = immich-apk-v1 ] && \
        [ "$(cat "$backup/source.version")" = "$source_version" ] || \
        fail 'Pending snapshot is incomplete. Inspect it before retrying; APK may already have replaced application files.'
}
write_pending() {
    printf '%s\n%s\n%s\n%s\n%s\n' "$source_version" "$target_version" \
        "${backup##*/}" "$restart_server" "$restart_ml" > "$state/pending.new"
    mv "$state/pending.new" "$pending"
}
running() {
    [ -x "/etc/init.d/$1" ] && rc-service "$1" status >/dev/null 2>&1
}
stop_services() {
    for service in immich immich-ml; do
        if running "$service"; then
            rc-service --nodeps "$service" stop || fail "Could not stop $service."
            running "$service" && fail "$service is still running after stop."
        fi
    done
    return 0
}
pre_install_or_upgrade() {
    prepare_state
    # A failed pre hook must never leave an old approval for the post hook.
    rm -f "$prepared"
    ensure_account
    valid_version "$target_version"
    if [ -f "$pending" ]; then
        read_pending
        echo "Reusing completed Immich snapshot: $backup"
        stop_services
        write_pending
    elif [ -d "$base/app" ]; then
        if [ -e "$base/.upgrade-pending" ] || [ -L "$base/.upgrade-pending" ]; then
            fail 'An earlier standalone installer upgrade is pending. Preserve its backup and resolve that state before native package recovery.'
        fi
        [ -f "$base/app/start.sh" ] && [ ! -L "$base/app/start.sh" ] || fail 'Cannot snapshot an incomplete existing application.'
        if [ -n "$old_version" ]; then
            valid_version "$old_version"
            source_version=apk-$old_version
        elif [ -f "$base/.immich-version" ]; then
            source_version=$(cat "$base/.immich-version")
            valid_version "$source_version"
        else
            source_version=legacy-unversioned
        fi
        running immich && restart_server=1
        running immich-ml && restart_ml=1
        backup=$backups/native-$(date -u +%Y%m%dT%H%M%SZ)-$$
        mkdir -m 0700 "$backup"
        printf '%s\n' immich-apk-v1 > "$backup/native-format"
        printf '%s\n' "$source_version" > "$backup/source.version"
        # Persist original service intent before stopping anything. A retry must
        # not interpret services stopped by a failed attempt as intentionally off.
        write_pending
        stop_services
        # No dereferencing: media links remain links, and actual runtime data
        # directories are excluded even in a legacy application layout.
        tar -C "$base" \
            --exclude=app/upload --exclude=app/home --exclude=app/cache \
            --exclude=app/.cache --exclude=app/backups \
            --exclude=app/machine-learning/upload --exclude=app/machine-learning/cache \
            --exclude=app/machine-learning/.cache \
            -cf "$backup/app.tar" app
        if [ -f "$base/env" ]; then cp -p "$base/env" "$backup/env"; chmod 0600 "$backup/env"; fi
        printf 'completed_at=%s\n' "$(now)" > "$backup/backup.complete.new"
        mv "$backup/backup.complete.new" "$backup/backup.complete"
        echo "Completed Immich application/configuration snapshot: $backup"
    elif [ -n "$old_version" ]; then
        fail 'Installed application is missing and no completed upgrade snapshot is recorded.'
    fi
    run_bundled_runtime_hooks pre
    if [ -n "$backup" ]; then
        printf '%s\tto=%s\tstarted\n' "$(now)" "$target_version" >> "$backup/attempts.log"
        printf '%s\nupgrade\n' "$target_version" > "$state/prepared.new"
    else
        printf '%s\nfresh\n' "$target_version" > "$state/prepared.new"
    fi
    mv "$state/prepared.new" "$prepared"
}
setup_runtime() {
    ensure_account
    chown root:immich "$base"
    chmod 0750 "$base"
    for path in "$base/home" "$base/upload" "$base/cache" /var/log/immich; do
        mkdir -p "$path"
        chown immich:immich "$path"
        chmod 0750 "$path"
    done
    if [ ! -e "$base/env" ]; then
        cp /usr/share/immich/immich.env.example "$base/env"
        echo 'Created /var/lib/immich/env. Configure external PostgreSQL and Redis before starting Immich.'
    fi
    chown immich:immich "$base/env"
    chmod 0600 "$base/env"
    [ -x "$base/app/start.sh" ] && [ -f "$base/app/dist/main.js" ] && \
        [ -x "$base/app/machine-learning/start.sh" ] || fail 'Installed application files are incomplete.'
}
# Read only literal bind settings; never source service-owned configuration as
# root. Expansion/command substitutions are intentionally not evaluated here.
config_literal() {
    value=$(awk -v key="$1" '
        $0 ~ "^[ \t]*(export[ \t]+)?" key "=" {
            value=$0
            sub("^[ \t]*(export[ \t]+)?" key "=", "", value)
            sub(/[ \t]+#.*/, "", value)
            sub(/[ \t]+$/, "", value)
        }
        END { print value }
    ' "$base/env")
    case "$value" in \"*\") value=${value#\"}; value=${value%\"} ;; \'*\') value=${value#\'}; value=${value%\'} ;; esac
    printf '%s' "$value"
}
health_url() {
    host=$(config_literal "$1")
    port=$(config_literal "$2")
    host=${host:-127.0.0.1}
    port=${port:-$3}
    case "$host" in 0.0.0.0|localhost) host=127.0.0.1 ;; ::|'[::]') host='[::1]' ;; esac
    case "$host" in ''|*[!A-Za-z0-9._:\[\]-]*) fail 'Health checks require literal bind hostnames/IP addresses in /var/lib/immich/env.' ;; esac
    case "$port" in ''|*[!0-9]*) fail 'Health checks require literal numeric ports in /var/lib/immich/env.' ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail 'Invalid configured health-check port.'
    case "$host" in \[*\]) ;; *:*) host=[$host] ;; esac
    printf 'http://%s:%s%s' "$host" "$port" "$4"
}
check_restarted_services() {
    server_url=''
    ml_url=''
    if [ "$restart_server" = 1 ]; then server_url=$(health_url IMMICH_HOST IMMICH_PORT 2283 /api/server/ping); fi
    if [ "$restart_ml" = 1 ]; then ml_url=$(health_url MACHINE_LEARNING_HOST MACHINE_LEARNING_PORT 3003 /ping); fi
    attempt=0
    while [ "$attempt" -lt 30 ]; do
        healthy=1
        if [ "$restart_ml" = 1 ]; then
            running immich-ml && curl --silent --show-error --fail --max-time 3 --output /dev/null "$ml_url" 2>/dev/null || healthy=0
        fi
        if [ "$restart_server" = 1 ]; then
            running immich && curl --silent --show-error --fail --max-time 3 --output /dev/null "$server_url" 2>/dev/null || healthy=0
        fi
        [ "$healthy" = 1 ] && return 0
        attempt=$((attempt + 1))
        [ "$attempt" -ge 30 ] || sleep 2
    done
    fail 'A restarted Immich service failed its health check. Inspect /var/log/immich; the completed snapshot and pending state remain.'
}
prune_native_backups() {
    for previous in "$backups"/native-*; do
        [ "$previous" != "$backup" ] && [ -d "$previous" ] && [ ! -L "$previous" ] || continue
        [ -f "$previous/native-format" ] && [ ! -L "$previous/native-format" ] && \
            [ "$(cat "$previous/native-format")" = immich-apk-v1 ] || continue
        [ -f "$previous/backup.complete" ] && [ ! -L "$previous/backup.complete" ] && \
            [ -f "$previous/upgrade.success" ] && [ ! -L "$previous/upgrade.success" ] && \
            [ -f "$previous/app.tar" ] && [ ! -L "$previous/app.tar" ] || continue
        rm -rf "$previous" || echo "WARNING: Could not prune $previous" >&2
    done
}
post_install_or_upgrade() {
    guard_paths
    valid_version "$target_version"
    [ -f "$prepared" ] && [ "$(awk 'END { print NR }' "$prepared")" = 2 ] && \
        [ "$(sed -n '1p' "$prepared")" = "$target_version" ] || \
        fail 'Pre-install/upgrade preparation did not complete; services will not be started and success will not be recorded.'
    phase=$(sed -n '2p' "$prepared")
    case "$phase" in
        upgrade)
            [ -f "$pending" ] || fail 'Prepared upgrade has no pending snapshot record.'
            read_pending
            [ "$saved_target" = "$target_version" ] || fail 'Prepared and pending target versions do not match.' ;;
        fresh) [ ! -e "$pending" ] || fail 'Fresh installation has unexpected pending upgrade state.' ;;
        *) fail 'Invalid prepared installation phase.' ;;
    esac
    setup_runtime
    run_bundled_runtime_hooks post
    if [ "$phase" = fresh ]; then
        rc-update add immich-ml default
        rc-update add immich default
    else
        # --nodeps prevents OpenRC from starting an intentionally stopped
        # dependency while restoring the exact prior service running state.
        if [ "$restart_ml" = 1 ]; then rc-service --nodeps immich-ml start; fi
        if [ "$restart_server" = 1 ]; then rc-service --nodeps immich start; fi
        if [ "$restart_server:$restart_ml" != 0:0 ]; then
            check_restarted_services
            printf 'healthy_at=%s\n' "$(now)" > "$backup/health.success"
        fi
        printf '%s\tto=%s\tservices=%s:%s\n' "$(now)" "$target_version" "$restart_server" "$restart_ml" > "$backup/upgrade.success"
        printf '%s\tto=%s\tsucceeded\n' "$(now)" "$target_version" >> "$backup/attempts.log"
    fi
    printf 'apk-%s\n' "$target_version" > "$state/version.new"
    mv "$state/version.new" "$base/.immich-version"
    rm -f "$pending" "$prepared" "$state/runtime-before.json"
    if [ "$phase" = fresh ]; then
        echo 'Immich installed and enabled at boot; services remain stopped.'
        echo 'Configure /var/lib/immich/env, then run: rc-service immich-ml start; rc-service immich start'
    else
        # A repair of the same version must not discard the snapshot of the
        # earlier package version that remains useful for manual recovery.
        [ "$source_version" = "apk-$target_version" ] || prune_native_backups
        echo "Immich package upgrade completed. Retained snapshot: $backup"
    fi
}

case "$hook" in
    pre-install|pre-upgrade) pre_install_or_upgrade ;;
    post-install|post-upgrade) post_install_or_upgrade ;;
    pre-deinstall) guard_paths; stop_services; run_bundled_runtime_hooks pre-deinstall ;;
    post-deinstall)
        run_bundled_runtime_hooks post-deinstall
        for service in immich immich-ml; do
            if [ -e "/etc/runlevels/default/$service" ] || [ -L "/etc/runlevels/default/$service" ]; then
                rc-update del "$service" default
            fi
        done
        echo 'Immich package removed. Account, configuration, media, caches and backups were retained.' ;;
    trigger) run_bundled_runtime_hooks trigger "$@" ;;
    *) fail 'Unexpected APK lifecycle action.' ;;
esac
HOOK
  local hook
  for hook in pre-install post-install pre-upgrade post-upgrade pre-deinstall post-deinstall trigger; do
    cp "$scripts/lifecycle" "$scripts/$hook"
    chmod 0755 "$scripts/$hook"
  done
  rm "$scripts/lifecycle"
}

# Fetch only installed runtime packages absent from Alpine 3.24's current stable
# repositories. Verify the original Alpine signatures before merging their files.
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
    log 'All installed runtime packages are available from Alpine 3.24; no runtime files need merging.'
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
    log "Verified runtime source package: $asset"
  done < "$work/selected.tsv"
}

# Called only by the root parent after all upstream build commands have finished.
package_app() {
  local stage scripts runtime_dir runtime_manifest runtime_metadata source_sha build_ref built_package_version
  local node_major vips_version libraw_version dependency_list current_runtime_versions recorded_runtime_versions
  local runtime_provides runtime_replaces package_license runtime_trigger
  local -a signing_args=() verify_args=(--allow-untrusted) metadata_args=()
  [[ -d "$APP" && ! -L "$APP" && -f "$APP/.build-complete" && ! -L "$APP/.build-complete" && \
     -f "$APP/.build-info" && ! -L "$APP/.build-info" ]] || fatal 'No completed regular app and build metadata to package.'
  source_sha="$(sed -n 's/^immich_commit=//p' "$APP/.build-info")"
  build_ref="$(sed -n 's/^immich_ref=//p' "$APP/.build-info")"
  [[ "$source_sha" =~ ^[a-fA-F0-9]{40}$ && "$build_ref" == "$IMMICH_REV" ]] || fatal 'Build metadata does not match IMMICH_REV.'
  built_package_version="$(sed -n 's/^apk_version=//p' "$APP/.build-info")"
  [[ "$built_package_version" =~ ^[0-9][A-Za-z0-9._]*-r[0-9]+$ && "${built_package_version%-r*}" == "$APK_VERSION" ]] || \
    fatal 'APK_VERSION must match the completed application build; only the packaging revision may change.'
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
  runtime_metadata="$PKG_WORK/runtime-metadata"
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
  # Originals are temporary build inputs. Their verified runtime files and
  # truthful capabilities become part of this one native package.
  merge_runtime_apks "$stage" "$runtime_dir" "$runtime_manifest" "$runtime_metadata"
  # Embed verified original callback bodies into native hooks, including pre-
  # install (which cannot depend on the new payload already being unpacked).
  python3 - "$stage/usr/share/immich/bundled-runtime.json" "$scripts" <<'PY_RUNTIME_CONTROLS'
from pathlib import Path
import json, sys
manifest = json.loads(Path(sys.argv[1]).read_text())
controls = [{key: package[key] for key in ('name', 'version', 'scripts', 'triggers')}
            for package in manifest['packages']]
for path in Path(sys.argv[2]).iterdir():
    text = path.read_text()
    if text.count('BUNDLED_RUNTIME = None') != 1:
        raise SystemExit('Missing unique runtime-hook data placeholder in ' + path.name)
    path.write_text(text.replace('BUNDLED_RUNTIME = None', 'BUNDLED_RUNTIME = ' + repr(controls)))
PY_RUNTIME_CONTROLS
  # A packaging-only rebuild may increment -rN without recompiling the app.
  # Update only the staged metadata, leaving the completed build untouched.
  python3 - "$stage/var/lib/immich/app/.build-info" "$APK_VERSION-r$APK_RELEASE" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if path.parent.is_symlink() or path.is_symlink() or not path.is_file():
    raise SystemExit('Staged build metadata must be a regular file in the application directory')
lines = [line for line in path.read_text().splitlines()
         if not line.startswith(('apk_version=', 'apk_layout='))]
lines.extend(('apk_version=' + sys.argv[2], 'apk_layout=native-merged-v1'))
path.write_text('\n'.join(lines) + '\n')
PY
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
  # Retain external dependencies of the original libraries. Exact bundled
  # names/versions and SONAME capabilities satisfy internal requirements.
  dependency_list+=" $(tr '\n' ' ' < "$runtime_metadata/depends")"
  runtime_provides="$(tr '\n' ' ' < "$runtime_metadata/provides")"
  runtime_replaces="$(tr '\n' ' ' < "$runtime_metadata/replaces")"
  package_license="$(cat "$runtime_metadata/license")"
  [[ -z "$runtime_provides" ]] || metadata_args+=(--info "provides:$runtime_provides")
  [[ -z "$runtime_replaces" ]] || metadata_args+=(--info "replaces:$runtime_replaces")
  if [[ -s "$runtime_metadata/triggers" ]]; then
    metadata_args+=(--script "trigger:$scripts/trigger")
    while IFS= read -r runtime_trigger; do
      metadata_args+=(--trigger "$runtime_trigger")
    done < "$runtime_metadata/triggers"
  fi
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
    --info "license:$package_license" \
    --info 'origin:immich' \
    --info "repo-commit:$source_sha" \
    --info "build-time:$(date -u +%s)" \
    --info "depends:$dependency_list" \
    --script "pre-install:$scripts/pre-install" \
    --script "post-install:$scripts/post-install" \
    --script "pre-upgrade:$scripts/pre-upgrade" \
    --script "post-upgrade:$scripts/post-upgrade" \
    --script "pre-deinstall:$scripts/pre-deinstall" \
    --script "post-deinstall:$scripts/post-deinstall" \
    --output "$PKG_WORK/$ASSET_NAME" "${metadata_args[@]}" "${signing_args[@]}"
  verify_apk "$PKG_WORK/$ASSET_NAME" "${verify_args[@]}"
  # Runtime files are already inside the signed payload. Publish one APK only.
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

# Merge verified original runtime payloads into a single native Immich package.
# Call before mkpkg and before final payload validation/ownership normalization.
# Outputs provides, depends, replaces (one value per line) and license (one line).
merge_runtime_apks() {
  python3 - "$1" "$2" "$3" "$4" "$APK_ARCH" <<'PY'
from pathlib import Path
import functools, hashlib, json, os, posixpath, re, shutil, stat, subprocess, sys, tarfile, tempfile

stage, archives, manifest, metadata = map(Path, sys.argv[1:5])
arch = sys.argv[5]
def fail(message):
    source = globals().get('original')
    context = (' [' + source.name + ']') if isinstance(source, Path) else ''
    raise SystemExit('Runtime merge: ' + message + context)
def command(*args):
    return subprocess.run(['apk', *map(str, args)], check=True, text=True, stdout=subprocess.PIPE).stdout
def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
def allowed(path, directory=False):
    if not isinstance(path, str) or not path or path.startswith('/') or '\\' in path:
        return False
    parts = path.split('/')
    if any(p in ('', '.', '..') or any(ord(c) < 32 or ord(c) == 127 for c in p) for p in parts):
        return False
    if any(p in ('pkgconfig', 'cmake', '.cache', '.cargo', '.env', 'node_modules', 'home', 'backups') for p in parts):
        return False
    # These are paths INSIDE verified runtime APKs, not directories copied from
    # the builder. Keep executables, loader helpers, and their runtime data too.
    roots = ('usr/bin', 'usr/lib', 'usr/libexec', 'usr/share/licenses',
             'usr/share/glycin-loaders', 'usr/share/glycin', 'usr/share/mime',
             'usr/share/locale', 'usr/share/thumbnailers', 'usr/share/vips')
    if directory and any(path == root or root.startswith(path + '/') for root in roots):
        return True
    if not any(path.startswith(root + '/') for root in roots):
        return False
    return not path.endswith(('.apk', '.a', '.la', '.tar', '.tar.gz'))
def target_path(path, target):
    if not isinstance(target, str) or not target or any(ord(c) < 32 or ord(c) == 127 for c in target):
        fail('invalid runtime symlink target: ' + path)
    resolved = posixpath.normpath(target.lstrip('/') if target.startswith('/') else posixpath.join(posixpath.dirname(path), target))
    if not allowed(resolved):
        fail('runtime symlink escapes the allowed runtime paths: ' + path)
    return resolved
def audit_header(path, kind, mode, target=None):
    if not allowed(path, kind == 'directory'):
        fail('unsupported runtime payload path: ' + path)
    if kind not in ('directory', 'file', 'symlink') or mode & 0o7000:
        fail('unsupported runtime file type or special permission bits: ' + path)
    if kind == 'symlink':
        target_path(path, target)
def one(fields, name, required=True):
    values = fields.get(name, [])
    if len(values) != 1:
        if not values and not required:
            return ''
        fail('missing or duplicate package field: ' + name)
    value = values[0]
    if not isinstance(value, str) or any(ord(c) < 32 or ord(c) == 127 for c in value):
        fail('invalid package field: ' + name)
    return value

CONTROL_ACTIONS = ('pre-install', 'post-install', 'pre-upgrade', 'post-upgrade',
                   'pre-deinstall', 'post-deinstall', 'trigger')
def check_controls(scripts, triggers, source):
    if not isinstance(scripts, dict) or not isinstance(triggers, list):
        fail('invalid runtime control metadata: ' + source)
    for action, script in scripts.items():
        if action not in CONTROL_ACTIONS or not isinstance(script, str):
            fail('unsupported runtime control script: ' + source + ':' + action)
        if not script or len(script.encode('utf-8')) > 1048576 or '\0' in script:
            fail('invalid runtime control script: ' + source + ':' + action)
        if not re.fullmatch(r'#!/bin/(?:a)?sh(?:[ \t]+-[A-Za-z]+)*', script.splitlines()[0]):
            fail('runtime control script requires a supported sh/ash shebang: ' + source + ':' + action)
    for pattern in triggers:
        if (not isinstance(pattern, str) or not pattern or
                any(ord(c) <= 32 or ord(c) == 127 for c in pattern) or '\\' in pattern):
            fail('invalid runtime trigger: ' + source)
        plain = pattern.removeprefix('+')
        if not plain.startswith('/') or any(p in ('.', '..') for p in plain.split('/')):
            fail('unsafe runtime trigger: ' + source)
    if bool(triggers) != ('trigger' in scripts):
        fail('runtime trigger paths/script do not match: ' + source)

def read_metadata(path):
    with path.open('rb') as stream:
        magic = stream.read(4)
    if magic.startswith(b'ADB'):
        data = json.loads(command('adbdump', '--format', 'json', path))
        info = data.get('info', {})
        scripts = {k: v for k, v in data.get('scripts', {}).items() if v}
        triggers = data.get('triggers', [])
        check_controls(scripts, triggers, path.name)
        for directory in data.get('paths', []):
            dirname = directory['name']
            acl = directory.get('acl', {})
            if acl.get('user') != 'root' or acl.get('group') != 'root' or acl.get('xattrs'):
                fail('non-root owner or extended attributes in ' + path.name)
            if dirname:
                audit_header(dirname, 'directory', acl['mode'])
            elif directory.get('files'):
                fail('runtime package contains files at filesystem root: ' + path.name)
            for entry in directory.get('files', []):
                filename = entry['name']
                if '/' in filename:
                    fail('invalid APKv3 file basename')
                full = dirname + '/' + filename
                acl = entry.get('acl', {})
                if acl.get('user') != 'root' or acl.get('group') != 'root' or acl.get('xattrs'):
                    fail('non-root owner or extended attributes in ' + path.name)
                kind, target = 'file', None
                if 'target' in entry:
                    encoded = bytes.fromhex(entry['target'])
                    if len(encoded) < 3 or int.from_bytes(encoded[:2], 'little') != stat.S_IFLNK:
                        fail('unsupported APKv3 special file/hardlink: ' + full)
                    kind, target = 'symlink', encoded[2:].decode('utf-8')
                audit_header(full, kind, acl['mode'], target)
        return {
            'name': info['name'], 'version': info['version'], 'arch': info['arch'],
            'license': [info['license']] if info.get('license') else [],
            'depends': info.get('depends', []), 'provides': info.get('provides', []),
            'replaces': info.get('replaces', []), 'url': info.get('url', ''),
            'origin': info.get('origin', ''), 'maintainer': info.get('maintainer', ''),
            'scripts': scripts, 'triggers': triggers,
        }
    if magic[:2] != b'\x1f\x8b':
        fail('unsupported original APK format: ' + path.name)
    fields, scripts = {}, {}
    found_info = False
    # APKv2 consists of concatenated gzip/tar members. Parse only metadata and
    # headers with Python's standard tar reader; native apk extracts payloads.
    with tarfile.open(path, mode='r:gz', ignore_zeros=True) as archive:
        for member in archive:
            name = member.name.rstrip('/')
            if name == '.PKGINFO':
                if found_info or not member.isfile() or member.size > 1048576:
                    fail('invalid or duplicate .PKGINFO: ' + path.name)
                found_info = True
                for line in archive.extractfile(member).read().decode('utf-8').splitlines():
                    if not line or line.startswith('#'):
                        continue
                    key, separator, value = line.partition(' = ')
                    if not separator:
                        fail('invalid .PKGINFO line: ' + path.name)
                    fields.setdefault(key, []).append(value)
            elif name.startswith('.SIGN.') and '/' not in name:
                if not member.isfile():
                    fail('invalid signature control member')
            elif name.startswith('.') and '/' not in name:
                action = name[1:]
                if (action not in CONTROL_ACTIONS or action in scripts or not member.isfile()
                        or member.size > 1048576 or member.uid != 0 or member.gid != 0):
                    fail('unsupported or duplicate lifecycle/control member ' + name + ' from ' + path.name)
                scripts[action] = archive.extractfile(member).read().decode('utf-8')
            else:
                if member.uid != 0 or member.gid != 0 or any('xattr' in key for key in member.pax_headers):
                    fail('non-root owner or extended attributes in ' + name)
                kind = 'directory' if member.isdir() else 'file' if member.isfile() else 'symlink' if member.issym() else 'special'
                audit_header(name, kind, member.mode, member.linkname if member.issym() else None)
    triggers = [pattern for value in fields.get('triggers', []) + fields.get('trigger', [])
                for pattern in value.split()]
    check_controls(scripts, triggers, path.name)
    return {
        'name': one(fields, 'pkgname'), 'version': one(fields, 'pkgver'),
        'arch': one(fields, 'arch'), 'license': fields.get('license', []),
        'depends': fields.get('depend', []), 'provides': fields.get('provides', []),
        'replaces': fields.get('replaces', []), 'url': one(fields, 'url', False),
        'origin': one(fields, 'origin', False), 'maintainer': one(fields, 'maintainer', False),
        'scripts': scripts, 'triggers': triggers,
    }

if stage.is_symlink() or not stage.is_dir() or archives.is_symlink() or not archives.is_dir():
    fail('stage and original APK directory must be regular directories')
metadata.mkdir(mode=0o700, parents=True, exist_ok=True)
if metadata.is_symlink():
    fail('metadata output must be a regular directory')
entries = {}
for line in manifest.read_text().splitlines():
    match = re.fullmatch(r'([0-9a-f]{64})  ([a-z0-9][a-z0-9+_.-]*-[0-9][0-9a-z._]*-r[0-9]+\.(?:x86_64|aarch64)\.apk)', line)
    if not match or '..' in match[2] or match[2] in entries:
        fail('invalid or duplicate original APK manifest entry')
    entries[match[2]] = match[1]
if set(p.name for p in archives.iterdir()) != set(entries):
    fail('original APK directory does not exactly match its manifest')

packages, payloads, all_files = [], [], {}
with tempfile.TemporaryDirectory(prefix='runtime-merge-', dir=metadata) as temporary:
    for filename, expected in sorted(entries.items()):
        original = archives / filename
        if original.is_symlink() or not original.is_file() or digest(original) != expected:
            fail('original APK checksum mismatch or invalid file: ' + filename)
        command('verify', original)
        package = read_metadata(original)
        name, version = package['name'], package['version']
        if not re.fullmatch(r'[a-z0-9][a-z0-9+_.-]*', name) or not re.fullmatch(r'[0-9][0-9a-z._]*-r[0-9]+', version):
            fail('invalid original package name/version')
        if name == 'immich' or any(name == p or name.startswith(p + '-') for p in ('musl', 'apk-tools', 'alpine-baselayout', 'busybox')):
            fail('refusing to merge core/application package: ' + name)
        if package['arch'] not in (arch, 'noarch') or filename != name + '-' + version + '.' + arch + '.apk':
            fail('original package filename/architecture does not match its metadata')
        if not package['license'] or any(not isinstance(v, str) or not v or any(ord(c) < 32 for c in v) for v in package['license']):
            fail('missing or invalid original license: ' + name)
        if any(p['name'] == name for p in packages):
            fail('duplicate original package name: ' + name)
        package['sha256'] = expected
        package['files'] = []
        root = Path(temporary, name)
        root.mkdir()
        command('extract', '--destination', root, original)
        for directory, subdirs, filenames in os.walk(root, followlinks=False):
            for basename in sorted(subdirs + filenames):
                path = Path(directory, basename)
                relative = path.relative_to(root).as_posix()
                details = path.lstat()
                kind = 'symlink' if stat.S_ISLNK(details.st_mode) else 'directory' if stat.S_ISDIR(details.st_mode) else 'file' if stat.S_ISREG(details.st_mode) else 'special'
                target = os.readlink(path) if kind == 'symlink' else None
                audit_header(relative, kind, stat.S_IMODE(details.st_mode), target)
                record = {'path': relative, 'type': kind, 'mode': 0o777 if kind == 'symlink' else 0o755 if kind == 'directory' or details.st_mode & 0o111 else 0o644}
                if kind == 'file': record['sha256'] = digest(path)
                if kind == 'symlink': record['target'] = target
                package['files'].append(relative)
                if relative in all_files:
                    if kind != 'directory' or all_files[relative]['type'] != 'directory':
                        fail('duplicate runtime file path: ' + relative)
                else:
                    all_files[relative] = record
                    payloads.append((path, record))
        packages.append(package)

    # Every claimed soname comes from original metadata and an actual merged
    # file. All runtime symlinks must resolve within the selected payload.
    for record in all_files.values():
        if record['type'] != 'symlink': continue
        target = target_path(record['path'], record['target'])
        visited = {record['path']}
        while True:
            if target in visited or target not in all_files:
                fail('dangling or circular merged runtime symlink: ' + record['path'])
            visited.add(target)
            linked = all_files[target]
            if linked['type'] != 'symlink': break
            target = target_path(target, linked['target'])
        if linked['type'] != 'file':
            fail('runtime symlink must resolve to a regular runtime file')

    providers = {}
    dependency_re = re.compile(r'(!?)([A-Za-z0-9/][A-Za-z0-9+_.:/-]*)([<>=~]*)([^\s]*)')
    def dependency(value):
        match = dependency_re.fullmatch(value)
        if not match or bool(match[3]) != bool(match[4]):
            fail('unsupported original dependency/provide: ' + repr(value))
        return match.groups()
    for package in packages:
        for value in [package['name'] + '=' + package['version'], *package['provides']]:
            conflict, name, operator, version = dependency(value)
            if conflict or operator not in ('', '=') or name == 'immich':
                fail('unsupported original provides: ' + value)
            if name in providers and providers[name] != version:
                fail('conflicting versions of merged provide: ' + name)
            providers[name] = version
            if name.startswith('so:') and not any(Path(p).name == name[3:] and f['type'] in ('file', 'symlink') for p, f in all_files.items()):
                fail('provided SONAME has no merged runtime file: ' + name)
    @functools.lru_cache(None)
    def comparison(left, right):
        result = command('version', '--test', left, right).strip()
        if result not in ('<', '=', '>'): fail('invalid native version comparison')
        return result
    depends = set()
    for package in packages:
        for value in package['depends']:
            negative, name, operator, version = dependency(value)
            if name not in providers:
                depends.add(value)
                continue
            if operator and operator not in ('=', '<', '>', '<=', '>='):
                fail('unsupported internal runtime version constraint: ' + value)
            provided = providers[name]
            satisfied = not operator or bool(provided) and comparison(provided, version) in operator
            if negative:
                if satisfied: fail('merged runtime conflicts with itself: ' + value)
            elif not satisfied:
                fail('merged runtime does not satisfy its original dependency: ' + value)
    names = {p['name'] for p in packages}
    replaces = set(names)
    for package in packages:
        for value in package['replaces']:
            negative, replaced, operator, version = dependency(value)
            if (negative or not re.fullmatch(r'[a-z0-9][a-z0-9+_.-]*', replaced) or
                    replaced == 'immich' or any(replaced == p or replaced.startswith(p + '-')
                    for p in ('musl', 'apk-tools', 'alpine-baselayout', 'busybox'))):
                fail('unsafe original replacement: ' + value)
            replaces.add(value)
    provides = sorted(name + ('=' + version if version else '') for name, version in providers.items())
    licenses = sorted({value for p in packages for value in p['license']})
    license_expression = 'AGPL-3.0-only' + ''.join(' AND (' + value + ')' for value in licenses)

    # Refuse every file collision and symlinked destination ancestor. Directory
    # sharing is allowed; source links are copied as links, never dereferenced.
    for source, record in sorted(payloads, key=lambda item: (item[1]['path'].count('/'), item[1]['path'])):
        destination = stage / record['path']
        for parent in list(destination.parents)[:len(Path(record['path']).parts)]:
            if parent.is_symlink() or not parent.is_dir():
                fail('non-directory/symlinked staging ancestor: ' + str(parent))
        if record['type'] == 'directory':
            if os.path.lexists(destination) and (destination.is_symlink() or not destination.is_dir()):
                fail('runtime directory collides with staged file: ' + record['path'])
            destination.mkdir(exist_ok=True)
        else:
            if os.path.lexists(destination):
                fail('runtime file collides with existing payload: ' + record['path'])
            if record['type'] == 'symlink':
                destination.symlink_to(record['target'])
            else:
                shutil.copyfile(source, destination, follow_symlinks=False)
        os.chown(destination, 0, 0, follow_symlinks=False)
        if record['type'] != 'symlink': os.chmod(destination, record['mode'])

metadata_values = {'provides': provides, 'depends': sorted(depends), 'replaces': sorted(replaces),
                   'triggers': sorted({v for p in packages for v in p['triggers']}), 'license': [license_expression]}
for filename, values in metadata_values.items():
    destination = metadata / filename
    if os.path.lexists(destination): fail('metadata output already exists: ' + filename)
    destination.write_text(''.join(value + '\n' for value in values))
audit = {'schema': 1, 'packages': packages, 'files': [all_files[p] for p in sorted(all_files)], **{k:v for k,v in metadata_values.items() if k != 'license'}, 'license': license_expression}
audit_dir = stage / 'usr/share/immich'
for parent in (stage / 'usr', stage / 'usr/share', audit_dir):
    if os.path.lexists(parent) and (parent.is_symlink() or not parent.is_dir()):
        fail('invalid audit-manifest directory')
    parent.mkdir(exist_ok=True)
audit_file = audit_dir / 'bundled-runtime.json'
if os.path.lexists(audit_file): fail('audit manifest already exists')
audit_file.write_text(json.dumps(audit, indent=2, sort_keys=True) + '\n')
os.chmod(audit_file, 0o644)
PY
}

# Validate the signed audit manifest against actual runtime files, then emit
# their exact paths for validate_payload's allowlist (one path per line).
validate_bundled_runtime() {
  python3 - "$1" <<'PY'
from pathlib import Path
import hashlib, json, os, posixpath, re, stat, sys
root = Path(sys.argv[1])
def fail(message): raise SystemExit('Invalid bundled runtime: ' + message)
def allowed(path, directory=False):
    if not isinstance(path, str) or not path or path.startswith('/') or '\\' in path:
        return False
    parts = path.split('/')
    if any(p in ('', '.', '..') or any(ord(c) < 32 or ord(c) == 127 for c in p) for p in parts):
        return False
    if any(p in ('pkgconfig', 'cmake', '.cache', '.cargo', '.env', 'node_modules', 'home', 'backups') for p in parts):
        return False
    # These are paths INSIDE verified runtime APKs, not directories copied from
    # the builder. Keep executables, loader helpers, and their runtime data too.
    roots = ('usr/bin', 'usr/lib', 'usr/libexec', 'usr/share/licenses',
             'usr/share/glycin-loaders', 'usr/share/glycin', 'usr/share/mime',
             'usr/share/locale', 'usr/share/thumbnailers', 'usr/share/vips')
    if directory and any(path == root or root.startswith(path + '/') for root in roots):
        return True
    if not any(path.startswith(root + '/') for root in roots):
        return False
    return not path.endswith(('.apk', '.a', '.la', '.tar', '.tar.gz'))
manifest = root / 'usr/share/immich/bundled-runtime.json'
for relative in ('usr', 'usr/share', 'usr/share/immich'):
    if (root / relative).is_symlink() or not (root / relative).is_dir(): fail('invalid audit-manifest parent')
if manifest.is_symlink() or not manifest.is_file(): fail('missing regular audit manifest')
data = json.loads(manifest.read_text())
if data.get('schema') != 1 or not isinstance(data.get('packages'), list) or not isinstance(data.get('files'), list): fail('unsupported audit schema')
records = {}
for item in data['files']:
    path, kind = item['path'], item['type']
    if not allowed(path, kind == 'directory') or path in records: fail('unsafe or duplicate path: ' + path)
    if kind not in ('file', 'directory', 'symlink'): fail('unsupported runtime file type')
    records[path] = item
    file = root / path
    for parent in list(file.parents)[:len(Path(path).parts)]:
        if parent.is_symlink() or not parent.is_dir(): fail('symlinked or missing parent: ' + path)
    if not os.path.lexists(file): fail('missing runtime file: ' + path)
    details = file.lstat()
    expected_mode = item['mode']
    if details.st_uid != 0 or details.st_gid != 0: fail('non-root runtime owner: ' + path)
    if kind == 'directory':
        valid = stat.S_ISDIR(details.st_mode) and expected_mode == 0o755
    elif kind == 'file':
        valid = stat.S_ISREG(details.st_mode) and expected_mode in (0o644, 0o755)
        expected = item.get('sha256', '')
        if not re.fullmatch('[0-9a-f]{64}', expected): fail('invalid runtime digest')
        if valid:
            with file.open('rb') as stream:
                valid = hashlib.file_digest(stream, 'sha256').hexdigest() == expected
    else:
        valid = stat.S_ISLNK(details.st_mode) and expected_mode == 0o777 and os.readlink(file) == item.get('target')
    if not valid or stat.S_IMODE(details.st_mode) != expected_mode: fail('runtime type/mode/content mismatch: ' + path)
for path, item in records.items():
    if item['type'] != 'symlink': continue
    seen = {path}
    current = path
    while records[current]['type'] == 'symlink':
        target = records[current]['target']
        if not isinstance(target, str) or not target or any(ord(c) < 32 or ord(c) == 127 for c in target): fail('invalid symlink target')
        current = posixpath.normpath(target.lstrip('/') if target.startswith('/') else posixpath.join(posixpath.dirname(current), target))
        if not allowed(current) or current in seen or current not in records: fail('escaping/dangling runtime symlink: ' + path)
        seen.add(current)
    if records[current]['type'] != 'file': fail('runtime symlink does not resolve to a file')
package_names = set()
for package in data['packages']:
    name = package.get('name', '')
    if not re.fullmatch('[a-z0-9][a-z0-9+_.-]*', name) or name in package_names: fail('invalid/duplicate source package')
    package_names.add(name)
    if not re.fullmatch('[0-9a-f]{64}', package.get('sha256', '')) or not package.get('license'): fail('missing source provenance')
    if any(path not in records for path in package.get('files', [])): fail('source file is absent from runtime allowlist')
if set(path for package in data['packages'] for path in package.get('files', [])) != set(records): fail('runtime file has no original source package')
for path in sorted(records): print(path)
print('usr/share/immich/bundled-runtime.json')
PY
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
ASSET_NAME="immich-alpine-${APK_VERSION}-r${APK_RELEASE}.apk"

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
  # Also remove external runtime artifacts left by an older builder.
  # Versioned APK filenames require separate output directories per architecture.
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
