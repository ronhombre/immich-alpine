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

    # Symlink extism-js and binaryen tools into /usr/local/bin
    ln -sf "$EXTISM_HOME/.local/bin/extism-js" /usr/local/bin/extism-js
    if [ -d "$EXTISM_HOME/binaryen/bin" ]; then
        for tool in "$EXTISM_HOME"/binaryen/bin/*; do
            [ -x "$tool" ] || continue
            ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
        done
    fi

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

SHARP_FORCE_GLOBAL_LIBVIPS=true pnpm --filter immich --prod --no-optional deploy "$SERVER_PRUNED"
SHARP_FORCE_GLOBAL_LIBVIPS=true pnpm \
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
    # Alpine provides uv as a system package; use it directly.
    cd machine-learning
    uv sync \
        --frozen \
        --extra cpu \
        --no-dev \
        --no-editable \
        --no-install-project \
        --no-install-workspace \
        --compile-bytecode \
        --no-progress \
        --no-cache \
        --active \
        --link-mode=copy
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
date --iso-8601=seconds | tr -d "\n" > geodata-date.txt
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