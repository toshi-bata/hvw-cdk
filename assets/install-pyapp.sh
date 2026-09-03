#!/bin/bash
#
# Deploy a Python application server redistributable (TEMPLATE, pre-filled for
# the HOOPS AI WebAPI).
#
# This script is appended to the EC2 user-data only when a Python app package is
# supplied at deploy time via pyAppS3Uri / PYAPP_S3_URI (pre-uploaded
# s3://bucket/key) or pyAppPackage / PYAPP_PACKAGE (local path). It is
# INDEPENDENT of HVW_SDK_URL and the static webapp (install-webapp.sh): use it
# for a self-contained Python service that renders/infers with HOOPS and needs
# the headless display.
#
# Inputs (exported by lib/hvw-cdk-stack.ts):
#   PYAPP_ARCHIVE  - path to the downloaded redistributable on the instance.
#   PYAPP_PORT     - TCP port the app listens on (default 8000; from -c appPort).
#
# What it does (adapt freely - this is a sample, not a fixed contract):
#   1. Installs the Python toolchain the app needs (pip, venv, 7z/unzip).
#   2. Extracts the package into APP_DIR (NOT the NGINX static root) and hands
#      ownership to the `ubuntu` user.
#   3. Builds a venv and installs the app's web-stack requirements.
#   4. Installs & starts a systemd service that runs the app against the
#      shared headless display (DISPLAY=:99 from xvfb.service in user-data.sh).
#   5. Publishes the app through the existing NGINX front end (80/443) by
#      dropping a reverse-proxy `location` snippet into /etc/nginx/pyapp-locations/,
#      so you do NOT have to open PYAPP_PORT to the internet.
#
# NOTE (model / weights): fetching large ML models (e.g. a *.ckpt) is the app's
# concern, not this infra script. Place them per the app's own README (see the
# HOOPS AI WebAPI README) - either baked into the redistributable, downloaded on
# first run, or copied to the instance out of band.
#
set -eu

: "${PYAPP_ARCHIVE:?PYAPP_ARCHIVE is not set}"
PYAPP_PORT="${PYAPP_PORT:-8000}"

# ---------------------------------------------------------------------------
# Tunables - edit these for your app.
# ---------------------------------------------------------------------------
APP_DIR=/opt/hoops-ai              # extraction target (outside the web root)
APP_USER=ubuntu                    # runs the service as this non-root user
VENV_DIR="$APP_DIR/.webvenv"       # web-stack venv (HOOPS AI adds its own venv)
SERVICE_NAME=pyapp                 # systemd unit name -> pyapp.service
PROXY_PREFIX=/app/                 # NGINX location prefix proxied to the app

# 1. Python toolchain. Ubuntu 24.04 ships Python 3.12 but not pip/venv, and the
#    redistributable may be a .zip or .7z, so make both extractors available.
export DEBIAN_FRONTEND=noninteractive
apt-get install -y python3-pip python3.12-venv p7zip-full

# 2. Extract into APP_DIR, then hand ownership to the service user.
mkdir -p "$APP_DIR"
ARCHIVE_TYPE=$(file -b "$PYAPP_ARCHIVE")
echo "Python app package type: $ARCHIVE_TYPE"
echo "==> Extracting Python app package into $APP_DIR"
case "$ARCHIVE_TYPE" in
  *Zip*|*7-zip*)
    # Use 7z rather than `unzip` for .zip archives: Info-ZIP's unzip rejects
    # large / ZIP64 / offset-prefixed archives with "extra bytes at beginning"
    # and "overlapped components (possible zip bomb)" - a false positive on
    # legitimate multi-GB redistributables. 7z handles those. If 7z still fails
    # we fall back to Python's zipfile, which transparently corrects a prepended
    # byte offset (self-extracting-style prefix).
    if ! 7z x -y -bd -o"$APP_DIR" "$PYAPP_ARCHIVE" >/dev/null; then
      echo "==> 7z extraction failed; falling back to Python zipfile"
      python3 - "$PYAPP_ARCHIVE" "$APP_DIR" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
    fi
    ;;
  *) tar -xf "$PYAPP_ARCHIVE" -C "$APP_DIR" ;;
esac
rm -f "$PYAPP_ARCHIVE"

# If the archive expands into a single top-level folder, treat that as APP_DIR
# so the paths below (requirements.txt, main.py, ...) resolve. Comment this out
# if your archive already extracts flat.
shopt -s dotglob nullglob
entries=("$APP_DIR"/*)
if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
  APP_DIR="${entries[0]}"
  VENV_DIR="$APP_DIR/.webvenv"
  echo "==> Single top-level dir detected; APP_DIR is now $APP_DIR"
fi
shopt -u dotglob nullglob

chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# 3. Web-stack venv + requirements, created AS the service user so the venv is
#    owned by it. The HOOPS AI redistributable bundles its own hoops_ai / torch /
#    faiss venv that main.py auto-activates - this .webvenv holds only the web
#    stack (see the app README).
sudo -u "$APP_USER" bash -eu <<VENV_EOF
cd "$APP_DIR"
python3.12 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip
if [ -f requirements.txt ]; then
  "$VENV_DIR/bin/pip" install -r requirements.txt
fi
VENV_EOF

# 4. systemd service. Requires the headless display from xvfb.service (DISPLAY
#    =:99) so HOOPS does not SIGSEGV, and runs as the non-root APP_USER.
#
#    The ExecStart below is the forum-article "main.py" pattern. If your
#    redistributable ships start_server.sh (which starts its OWN Xvfb), use the
#    commented variant instead AND expect it to spawn a second Xvfb - either let
#    it (it picks a free display) or drop the DISPLAY=:99 / Requires=xvfb.service
#    lines here to avoid two servers on :99.
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE_EOF
[Unit]
Description=Python application server (HOOPS AI WebAPI sample)
After=network.target xvfb.service
Requires=xvfb.service

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=DISPLAY=:99
Environment=PYAPP_PORT=${PYAPP_PORT}
ExecStart=${VENV_DIR}/bin/python main.py --host 0.0.0.0 --port ${PYAPP_PORT}
# --- start_server.sh variant (starts its own Xvfb) -------------------------
# ExecStart=/bin/bash -lc 'HOOPS_AI_VENV=${VENV_DIR} ./start_server.sh --port ${PYAPP_PORT}'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.service"

# 5. Expose the app through the existing NGINX front end (port 80/443) instead
#    of opening PYAPP_PORT publicly. user-data.sh's server block does
#    `include /etc/nginx/pyapp-locations/*.conf;`, so this snippet is picked up
#    on reload. Adjust PROXY_PREFIX / add more locations for your app's routes.
mkdir -p /etc/nginx/pyapp-locations
cat > /etc/nginx/pyapp-locations/hoops-ai.conf <<NGINX_EOF
location ${PROXY_PREFIX} {
    proxy_pass http://127.0.0.1:${PYAPP_PORT};
    proxy_http_version 1.1;
    proxy_set_header Upgrade    \$http_upgrade;
    proxy_set_header Connection \$hvw_connection;
    proxy_set_header Host       \$host;
    proxy_set_header X-Real-IP  \$remote_addr;
    proxy_read_timeout          86400s;
}
NGINX_EOF

nginx -t
systemctl reload nginx

echo "Python app deployed to $APP_DIR, service ${SERVICE_NAME} on port ${PYAPP_PORT}."
echo "Reachable via the NGINX front end at ${PROXY_PREFIX} (and directly on ${PYAPP_PORT} if appPort was set)."
