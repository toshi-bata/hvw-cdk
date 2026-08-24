#!/bin/bash
#
# Download and install the HOOPS Visualize Web (HVW) SDK, then start the server.
#
# Expects the environment variable HVW_SDK_URL to point at the Linux tar.gz
# (for example a TechSoft3D Developer Zone presigned S3 URL). This script is
# appended to the EC2 user-data only when an SDK URL is supplied at deploy time,
# so the whole install is automated instead of a manual SCP + copy.
#
# Layout (see README "配置設計"):
#   /opt/hvw/HOOPS_Visualize_Web_<ver>/  - full SDK tree; the SC server runs here
#   /opt/hvw/current                     - symlink to the active version
#   /var/www/html/                       - static web assets served by NGINX only
#                                          (demo-app/, hoops-web-viewer.mjs,
#                                           engine.esm.wasm, sample.html)
#
set -eux

: "${HVW_SDK_URL:?HVW_SDK_URL is not set}"

WORK=/tmp/hvw-sdk
mkdir -p "$WORK" /opt/hvw /var/www/html

# Download and extract the SDK archive straight into /opt/hvw, keeping the
# vendor tree intact so the server keeps its original relative paths.
curl -fSL "$HVW_SDK_URL" -o "$WORK/hvw.tar.gz"
tar -zxf "$WORK/hvw.tar.gz" -C /opt/hvw

# Resolve the extracted top-level SDK directory (name embeds the version) and
# point /opt/hvw/current at it so systemd and NGINX use a stable path.
SRC=$(find /opt/hvw -maxdepth 1 -type d -name 'HOOPS_Visualize_Web_*' | sort | tail -n1)
test -n "$SRC"
ln -sfn "$SRC" /opt/hvw/current

# Copy ONLY the static web assets NGINX needs to serve. The streaming models
# stay inside the SDK tree and are delivered by the SC server, not by NGINX.
cp -r "$SRC/web_viewer/demo-app" /var/www/html/
cp "$SRC/web_viewer/hoops-web-viewer.mjs" \
   "$SRC/web_viewer/engine.esm.wasm" /var/www/html/

# Point the SC server at the bundled streaming models (.scz) inside the SDK
# tree. "microengine" (used by sample.html and the demo-app csr example) lives
# here as microengine.scz.
perl -0777 -pi -e \
  's/modelDirs:\s*\[.*?\]/modelDirs: [\n        "\/opt\/hvw\/current\/quick_start\/converted_models\/standard\/sc_models",\n    ]/s' \
  "$SRC/server/node/Config.js"

# Start (or restart) the HVW server now that the SDK is in place.
systemctl restart onboot.service

# Tidy up the downloaded archive.
rm -rf "$WORK"
echo "HVW SDK installed under $SRC and server started."
