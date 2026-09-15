#!/bin/bash
# build-immich-alpine.sh
set -xeuo pipefail

REV="${IMMICH_REV:-v3.2.0}"
IMMICH_PATH=/var/lib/immich
APP=$IMMICH_PATH/app

# Prevent JavaScript OOM – builder can afford more memory
export NODE_OPTIONS="--max-old-space-size=4096"

if [[ "$(id -un)" != "immich" ]]; then
    # -----------------------------------------------------------------
    # Install extism-js and binaryen as root, into a system-wide location.
    # Doing this before we fork into the immich user avoids the
    # "Permission denied" error when symlinking into /usr/local/bin.
    # pnpm-spawned shells always see /usr/local/bin regardless of HOME.
    # -----------------------------------------------------------------
    EXTISM_HOME=/opt/immich-extism
    mkdir -p "$EXTISM_HOME/.local/bin" "$EXTISM_HOME/binaryen"

    curl -fsSL -o /tmp/install-extism.sh \
        https://raw.githubusercontent.com/extism/js-pdk/main/install.sh
    sed -i \
      -e 's@sudo@@g' \
      -e "s@/usr/local/binaryen@$EXTISM_HOME/binaryen@g" \
      -e "s@/usr/local/bin@$EXTISM_HOME/.local/bin@g" \
        /tmp/install-extism.sh
    HOME="$EXTISM_HOME" bash /tmp/install-extism.sh
    rm -f /tmp/install-extism.sh

    # Make the tree world-readable/executable
    chmod -R a+rX "$EXTISM_HOME"

    # Symlink extism-js into /usr/local/bin (always on base PATH,
    # regardless of pnpm's PATH sanitization).
    ln -sf "$EXTISM_HOME/.local/bin/extism-js" /usr/local/bin/extism-js

    # Discover and symlink every binaryen tool wherever it landed.
    # The extism install script puts wasm-merge / wasm-opt in
    # $HOME/.local/bin and/or $HOME/binaryen-version_N/bin; the layout
    # is not stable across releases, so we search rather than guess.
    find "$EXTISM_HOME" -maxdepth 4 -type f -name 'wasm-*' -perm -u+x \
        2>/dev/null | while read -r tool; do
        base=$(basename "$tool")
        # Skip symlinks we may have created ourselves
        [ -L "$tool" ] && continue
        ln -sf "$tool" "/usr/local/bin/$base"
        echo "linked $base -> $tool"
    done

    # Also walk any symlinks that point into the tarball extract dir
    # (some versions symlink wasm-merge into .local/bin rather than copy).
    find "$EXTISM_HOME" -maxdepth 4 -type l -name 'wasm-*' 2>/dev/null \
        | while read -r link; do
        base=$(basename "$link")
        target=$(readlink -f "$link")
        [ -x "$target" ] || continue
        ln -sf "$target" "/usr/local/bin/$base"
        echo "linked $base -> $target (via $link)"
    done

    # extism-js also honours BINARYEN_HOME; point it at whichever
    # directory actually contains the tools.
    BINARYEN_BIN_DIR=$(dirname "$(find "$EXTISM_HOME" -maxdepth 4 \
        -name 'wasm-merge' -type f -perm -u+x 2>/dev/null | head -n1)")
    if [ -n "$BINARYEN_BIN_DIR" ] && [ -d "$BINARYEN_BIN_DIR" ]; then
        export BINARYEN_HOME="$(dirname "$BINARYEN_BIN_DIR")"
        echo "BINARYEN_HOME resolved to $BINARYEN_HOME"
    else
        echo "WARNING: could not locate wasm-merge under $EXTISM_HOME"
    fi

    # Verification — fail fast if binaryen tools are missing.
    for tool in wasm-merge wasm-opt extism-js; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "CRITICAL: $tool is not on PATH after install"
            echo "Contents of $EXTISM_HOME:"
            find "$EXTISM_HOME" -maxdepth 3 -ls || true
            exit 1
        fi
        echo "$tool -> $(command -v "$tool")"
    done

    # Sanity check
    command -v extism-js || {
        echo "CRITICAL: extism-js not found after install"
        exit 1
    }
    echo "extism-js ready at $(command -v extism-js)"

    chmod +x /opt/immich-extism/.local/bin/extism-js
    # Make sure the symlink target and the intermediate directory are traversable
    chmod a+rx /opt /opt/immich-extism /opt/immich-extism/.local /opt/immich-extism/.local/bin
    chmod a+rx /usr/local/bin

    # ---- extism-js / binaryen diagnostics ----
    echo "=== extism-js diagnostics ==="
    file /opt/immich-extism/.local/bin/extism-js || true
    readelf -l /opt/immich-extism/.local/bin/extism-js 2>/dev/null \
        | grep -i 'interpreter' || true
    ldd /opt/immich-extism/.local/bin/extism-js 2>&1 | head -20 || true
    echo "=== glibc loader probe ==="
    ls -la /lib64/ld-linux-x86-64.so.2 2>&1 || true
    ls -la /lib/ld-linux-x86-64.so.2   2>&1 || true
    echo "=== end diagnostics ==="

    echo "Forking the script as user immich"
    exec su -s /bin/bash immich -c \
        "IMMICH_REV=$REV BINARYEN_HOME=$EXTISM_HOME/binaryen $0"
fi

umask 077

rm -rf $APP $IMMICH_PATH/i18n
mkdir -p $APP

# Wipe pnpm, uv, etc.
rm -rf $IMMICH_PATH/home
mkdir -p $IMMICH_PATH/home/.local/bin
echo 'umask 077' > $IMMICH_PATH/home/.bashrc
export PATH="$HOME/.local/bin:$PATH"

TMP=$(mktemp -d /tmp/immich-XXXXXX)
SERVER_PRUNED=$(mktemp -d /tmp/immich-server-pruned-XXXXXX)

git clone https://github.com/immich-app/immich $TMP --depth=1 -b $REV
cd $TMP
git reset --hard $REV
rm -rf .git

# --- Patch machine-learning Python version constraint to allow 3.14 ---
# Alpine 3.24's system Python is 3.14, and Alpine's py3-opencv and
# py3-onnxruntime are compiled for 3.14. Immich pins Python 3.13; we
# relax this so uv accepts the system interpreter.
if [ -f machine-learning/pyproject.toml ]; then
    sed -i -E \
      -e 's/requires-python = ">=3\.12,<3\.14"/requires-python = ">=3.12,<3.15"/' \
      -e 's/requires-python = ">=3\.13,<3\.14"/requires-python = ">=3.13,<3.15"/' \
      -e 's/requires-python = "~=3\.13"/requires-python = ">=3.13,<3.15"/' \
      machine-learning/pyproject.toml
    echo "--- machine-learning requires-python after patch ---"
    grep -n 'requires-python' machine-learning/pyproject.toml || true
fi

# uv may also read a .python-version file that pins 3.13.
if [ -f machine-learning/.python-version ]; then
    echo "Patching .python-version (3.13 -> 3.14)"
    sed -i 's/^3\.13$/3.14/' machine-learning/.python-version
    cat machine-learning/.python-version
fi

# uv's pyproject may also carry a [tool.uv] python-version pin.
if grep -q 'python-version' machine-learning/pyproject.toml 2>/dev/null; then
    sed -i -E 's/(python-version\s*=\s*")3\.13(")/\13.14\2/' machine-learning/pyproject.toml
    echo "--- tool.uv python-version after patch ---"
    grep -n 'python-version' machine-learning/pyproject.toml || true
fi

# Also check uv.toml if present.
if [ -f machine-learning/uv.toml ]; then
    sed -i -E 's/(python-version\s*=\s*")3\.13(")/\13.14\2/' machine-learning/uv.toml || true
fi

# Replace /usr/src with our install path
if grep -Rql /usr/src . 2>/dev/null; then
    grep -Rl /usr/src . | xargs -n1 sed -i -e "s@/usr/src@$IMMICH_PATH@g"
fi

mkdir -p $IMMICH_PATH/cache

# Replace /build with $APP
if grep -RqlE "\"/build\"|'/build'" . 2>/dev/null; then
    grep -RlE "\"/build\"|'/build'" . \
      | xargs -n1 sed -i -e "s@\"/build\"@\"$APP\"@g" -e "s@'/build'@'$APP'@g"
fi

# Patch plugin-core's build:wasm script to use an absolute path.
# pnpm sanitizes PATH for lifecycle scripts on Alpine, so PATH-based
# lookup of extism-js does not work even when /usr/local/bin is on PATH.
if [ -f packages/plugin-core/package.json ]; then
  sed -i \
    -e 's@"extism-js dist/@"/usr/local/bin/extism-js dist/@g' \
    packages/plugin-core/package.json
  echo "--- plugin-core script section after patch ---"
  grep -n "extism-js" packages/plugin-core/package.json || true
fi

# --- Sharp / libvips ---
# Alpine provides libvips 8.18.2, which satisfies sharp 0.34.x (>= 8.17.1).
SHARP_USE_GLOBAL_LIBVIPS=true

SHARP_FORCE_GLOBAL_LIBVIPS=true pnpm \
  --filter @immich/sdk \
  --filter @immich/plugin-sdk \
  --filter @immich/plugin-core \
  --filter immich \
  --filter immich-web \
  install --frozen-lockfile --force

pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter immich build
pnpm --filter @immich/sdk --filter immich-web build
pnpm --filter @immich/sdk --filter @immich/plugin-sdk --filter @immich/plugin-core build

# Deploy production dependencies
SHARP_FORCE_GLOBAL_LIBVIPS=true pnpm --filter immich --prod --no-optional deploy "$SERVER_PRUNED"

# Build Sharp from source, disabling LTO to avoid a conflict
# between GCC's LTO and Alpine's fortify-headers package.
# See: https://gitlab.alpinelinux.org/alpine/aports/-/issues/8626
SHARP_FORCE_GLOBAL_LIBVIPS=true \
CXXFLAGS="-fno-lto" \
CFLAGS="-fno-lto" \
LDFLAGS="-fno-lto" \
pnpm \
  --config.verify-deps-before-run=false \
  --dir "$SERVER_PRUNED/node_modules/sharp" \
  exec npm run build

cp -a "$SERVER_PRUNED/." $APP/
cp -a web/build $APP/www
mkdir -p $APP/plugins/immich-plugin-core
cp -a packages/plugin-core/dist $APP/plugins/immich-plugin-core/
cp -a packages/plugin-core/manifest.json $APP/plugins/immich-plugin-core/
cp -a pnpm-lock.yaml $APP/
cp -a LICENSE $APP/
cp -a i18n $IMMICH_PATH/
cd $APP
pnpm store prune
cd -

# --- immich-machine-learning ---
mkdir -p $APP/machine-learning
python3 -m venv $APP/machine-learning/venv
(
    . $APP/machine-learning/venv/bin/activate
    cd machine-learning

    # Force uv to use Alpine's Python (not its own managed CPython).
    # This is required so that the Alpine py3-* native packages
    # (py3-opencv, py3-onnxruntime) are ABI-compatible with the venv.
    export UV_PYTHON_PREFERENCE=only-system

    echo "=== uv sync diagnostics ==="
    echo "System Python: $(python3 --version)"
    echo "uv: $(uv --version)"
    echo "requires-python in pyproject.toml:"
    grep -n 'requires-python' pyproject.toml || true
    echo ".python-version:"
    cat .python-version 2>/dev/null || echo "(none)"
    echo "=========================="

    # Native packages that lack musl wheels and have no sdist are
    # excluded here and provided by Alpine's apk packages instead.
    uv sync \
        --frozen \
        --extra cpu \
        --no-dev \
        --no-editable \
        --no-install-project \
        --no-install-workspace \
        --no-install-package opencv-python-headless \
        --no-install-package opencv-python \
        --no-install-package onnxruntime \
        --no-install-package shapely \
        --no-install-package pyyaml \
        --compile-bytecode \
        --no-progress \
        --no-cache \
        --active \
        --link-mode=copy

    # Locate the system site-packages that apk installed cv2/onnxruntime into.
    SYS_SITE=""
    for p in /usr/lib/python3.*/site-packages; do
        if [ -d "$p" ]; then SYS_SITE="$p"; break; fi
    done
    VENV_SITE="$(python -c 'import site; print(site.getsitepackages()[0])')"
    echo "SYS_SITE=$SYS_SITE"
    echo "VENV_SITE=$VENV_SITE"

    # Symlink the system native modules into the venv so immich_ml can import them.
    for mod in cv2 onnxruntime shapely yaml; do
        if [ -d "$SYS_SITE/$mod" ]; then
            ln -sfn "$SYS_SITE/$mod" "$VENV_SITE/$mod"
            echo "linked $mod (dir)"
        fi
        for so in "$SYS_SITE/${mod}"*.so "$SYS_SITE/${mod}"*.pyd; do
            [ -e "$so" ] || continue
            ln -sf "$so" "$VENV_SITE/$(basename "$so")"
            echo "linked $(basename "$so")"
        done
    done

    # Sanity check: both modules must import successfully.
    python - <<'PY'
import sys
try:
    import cv2
    print("cv2 OK:", cv2.__version__)
except Exception as e:
    print("cv2 FAILED:", e); sys.exit(1)
try:
    import onnxruntime
    print("onnxruntime OK:", onnxruntime.__version__)
except Exception as e:
    print("onnxruntime FAILED:", e); sys.exit(1)
PY

    cd ..
)
cp -a machine-learning/immich_ml $APP/machine-learning/

# --- GeoNames ---
mkdir -p $APP/geodata
cd $APP/geodata
wget -q -O admin1CodesASCII.txt https://download.geonames.org/export/dump/admin1CodesASCII.txt &
wget -q -O admin2Codes.txt https://download.geonames.org/export/dump/admin2Codes.txt &
wget -q -O countryInfo.txt https://download.geonames.org/export/dump/countryInfo.txt &
wget -q -O cities500.zip https://download.geonames.org/export/dump/cities500.zip &
wget -q -O ne_10m_admin_0_countries.geojson https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_10m_admin_0_countries.geojson &
wait
unzip -q cities500.zip
date -Iseconds | tr -d "\n" > geodata-date.txt
rm cities500.zip
cd -

# --- Upload directory ---
mkdir -p $IMMICH_PATH/upload
ln -s $IMMICH_PATH/upload $APP/
ln -s $IMMICH_PATH/upload $APP/machine-learning/

# --- start.sh scripts ---
cat <<EOF > $APP/start.sh
#!/bin/bash
set -a
. $IMMICH_PATH/env
set +a

cd $APP
exec node $APP/dist/main "\$@"
EOF
chmod 700 $APP/start.sh

cat <<EOF > $APP/machine-learning/start.sh
#!/bin/bash
set -a
. $IMMICH_PATH/env
set +a

cd $APP/machine-learning
. venv/bin/activate

: "\${MACHINE_LEARNING_HOST:=127.0.0.1}"
: "\${MACHINE_LEARNING_PORT:=3003}"
: "\${MACHINE_LEARNING_WORKERS:=1}"
: "\${MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S:=2}"
: "\${MACHINE_LEARNING_WORKER_TIMEOUT:=300}"
: "\${MACHINE_LEARNING_CACHE_FOLDER:=$IMMICH_PATH/cache}"
: "\${TRANSFORMERS_CACHE:=$IMMICH_PATH/cache}"
: "\${HF_HOME:=$IMMICH_PATH/cache/hf-cache}"

exec gunicorn immich_ml.main:app \\
    -k immich_ml.config.CustomUvicornWorker \\
    -c immich_ml/gunicorn_conf.py \\
    -b "\$MACHINE_LEARNING_HOST":"\$MACHINE_LEARNING_PORT" \\
    -w "\$MACHINE_LEARNING_WORKERS" \\
    -t "\$MACHINE_LEARNING_WORKER_TIMEOUT" \\
    --log-config-json log_conf.json \\
    --keep-alive "\$MACHINE_LEARNING_HTTP_KEEPALIVE_TIMEOUT_S" \\
    --graceful-timeout 10 \\
    --no-control-socket
EOF
chmod 700 $APP/machine-learning/start.sh

# --- Cleanup ---
rm -rf $TMP $SERVER_PRUNED
rm -rf $IMMICH_PATH/home/.wget-hsts \
       $IMMICH_PATH/home/.pnpm \
       $IMMICH_PATH/home/.local/share/pnpm \
       $IMMICH_PATH/home/.cache

echo "Build complete. Artifact ready at /var/lib/immich."