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
# NOTE: no `set -x` here. This script is appended to user-data.sh and runs as one
# combined bash script, so an -x from either side would trace the injected
# `export HVW_SDK_URL=...` / `export HVW_LICENSE=...` lines and the curl and
# license-replacement commands below into /var/log/cloud-init-output.log in clear
# text. We keep -eu for safety and emit explicit `echo "==> ..."` progress logs
# instead of tracing every command.
set -eu

: "${HVW_SDK_URL:?HVW_SDK_URL is not set}"

WORK=/tmp/hvw-sdk
mkdir -p "$WORK" /opt/hvw /var/www/html

# Download and extract the SDK archive straight into /opt/hvw, keeping the
# vendor tree intact so the server keeps its original relative paths. The
# Developer Zone package may actually be a ZIP (despite the .tar.gz name) or a
# gzip/xz/plain tar, so detect the real format and extract accordingly.
echo "==> Downloading HVW SDK archive"
curl -fSL "$HVW_SDK_URL" -o "$WORK/hvw.tar.gz"
ARCHIVE_TYPE=$(file -b "$WORK/hvw.tar.gz")
echo "SDK archive type: $ARCHIVE_TYPE"
echo "==> Extracting HVW SDK archive into /opt/hvw"
case "$ARCHIVE_TYPE" in
  *Zip*) unzip -q -o "$WORK/hvw.tar.gz" -d /opt/hvw ;;
  *)     tar -xf "$WORK/hvw.tar.gz" -C /opt/hvw ;;
esac
echo "==> Extraction complete"

# Resolve the extracted top-level SDK directory (name embeds the version) and
# point /opt/hvw/current at it so systemd and NGINX use a stable path.
SRC=$(find /opt/hvw -maxdepth 1 -type d -name 'HOOPS_Visualize_Web_*' | sort | tail -n1)
test -n "$SRC"
ln -sfn "$SRC" /opt/hvw/current

# Copy ONLY the static web assets NGINX needs to serve. The streaming models
# stay inside the SDK tree and are delivered by the SC server, not by NGINX.
echo "==> Deploying static web assets to /var/www/html"
cp -r "$SRC/web_viewer/demo-app" /var/www/html/
cp "$SRC/web_viewer/hoops-web-viewer.mjs" \
   "$SRC/web_viewer/engine.esm.wasm" /var/www/html/
echo "==> Static web assets deployed"

# Point the SC server at the bundled streaming models (.scz) inside the SDK
# tree. "microengine" (used by sample.html and the demo-app csr example) lives
# here as microengine.scz.
echo "==> Patching Config.js modelDirs"
perl -0777 -pi -e \
  's/modelDirs:\s*\[.*?\]/modelDirs: [\n        "\/opt\/hvw\/current\/quick_start\/converted_models\/standard\/sc_models",\n    ]/s' \
  "$SRC/server/node/Config.js"

# Override the bundled evaluation license when HVW_LICENSE is supplied at deploy
# time. The SDK ships a time-limited key in server/node/Config.js; replacing it
# here lets the deployment use a longer-lived key. When HVW_LICENSE is unset,
# the Config.js default is left untouched.
if [ -n "${HVW_LICENSE:-}" ]; then
  # Replace the license value regardless of whether Config.js quotes it with
  # single or double quotes (the SDK ships double quotes). The hex classes
  # \x22 (") and \x27 (') keep this perl program free of literal quotes so it
  # embeds cleanly inside the shell single-quoted string, and \2 back-references
  # the opening quote so the same style is preserved on output.
  perl -0777 -pi -e \
    'my $lic = $ENV{HVW_LICENSE}; $lic =~ s/\\/\\\\/g; $lic =~ s/([\x22\x27])/\\$1/g; s/(license:\s*)([\x22\x27])(?:\\.|(?!\2).)*?\2/$1$2$lic$2/s' \
    "$SRC/server/node/Config.js"
fi
echo "==> Config.js patch complete"

# Start (or restart) the HVW server now that the SDK is in place.
echo "==> Starting HVW server (onboot.service)"
systemctl restart onboot.service

# Tidy up the downloaded archive.
rm -rf "$WORK"
echo "HVW SDK installed under $SRC and server started."
