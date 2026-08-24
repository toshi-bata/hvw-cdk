#!/bin/bash
#
# Download and install the HOOPS Visualize Web (HVW) SDK, then start the server.
#
# Expects the environment variable HVW_SDK_URL to point at the Linux tar.gz
# (for example a TechSoft3D Developer Zone presigned S3 URL). This script is
# appended to the EC2 user-data only when an SDK URL is supplied at deploy time,
# so the whole install is automated instead of a manual SCP + copy.
#
set -eux

: "${HVW_SDK_URL:?HVW_SDK_URL is not set}"

WORK=/tmp/hvw-sdk
mkdir -p "$WORK"

# Download and extract the SDK archive.
curl -fSL "$HVW_SDK_URL" -o "$WORK/hvw.tar.gz"
tar -zxf "$WORK/hvw.tar.gz" -C "$WORK"

# Locate the extracted top-level SDK directory (name embeds the version).
SRC=$(find "$WORK" -maxdepth 1 -type d -name 'HOOPS_Visualize_Web_*' | head -n1)
test -n "$SRC"

# Place server runtime, bundled node, sample models and web viewer files,
# mirroring the manual layout under /var/www.
cp -r "$SRC/3rd_party" "$SRC/server" /var/www/
cp -r "$SRC/quick_start/converted_models/standard/sc_models" /var/www/
cp -r "$SRC/web_viewer/demo-app" \
      "$SRC/web_viewer/hoops-web-viewer.mjs" \
      "$SRC/web_viewer/engine.esm.wasm" /var/www/html/

# Point the SC server at the bundled sample models. sc_models lives at
# /var/www/sc_models and the server resolves the relative "./sc_models".
perl -0777 -pi -e 's/modelDirs:\s*\[.*?\]/modelDirs: [\n        ".\/sc_models",\n    ]/s' \
      /var/www/server/node/Config.js

# Start (or restart) the HVW server now that the SDK is in place.
systemctl restart onboot.service

# Tidy up the downloaded archive.
rm -rf "$WORK"
echo "HVW SDK installed and server started."
