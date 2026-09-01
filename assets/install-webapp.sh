#!/bin/bash
#
# Deploy a custom web-service redistributable package into the NGINX web root.
#
# This script is appended to the EC2 user-data only when a package is supplied
# at deploy time (context `webappPackage` or env var WEBAPP_PACKAGE). CDK uploads
# the local archive as an S3 asset, user-data downloads it, and this script
# extracts it. WEBAPP_ARCHIVE points at the downloaded archive on the instance.
#
# Placement / ordering (see README):
#   * The archive's TOP-LEVEL contents are extracted straight into
#     /var/www/html/ (the NGINX web root). For example, an archive whose top
#     contains `myWebService/` yields /var/www/html/myWebService/. Multiple files
#     and folders at the top are all fine - no single top-level directory is
#     required.
#   * This runs AFTER sample.html (user-data.sh) and demo-app (install-sdk.sh,
#     when HVW_SDK_URL is set), and extraction OVERWRITES existing files. So if
#     the archive top contains sample.html or a demo-app/ folder, those already
#     placed files are updated by this package.
#
# By default this script only extracts the package. Building the web service or
# starting any service is intentionally left to you: add your own steps in the
# clearly marked user-customization section at the bottom.
#
set -eu

: "${WEBAPP_ARCHIVE:?WEBAPP_ARCHIVE is not set}"

WEB_ROOT=/var/www/html
mkdir -p "$WEB_ROOT"

# The redistributable may be a ZIP (common on Windows) or a gzip/xz/plain tar,
# so detect the real format and extract accordingly. Extraction overwrites any
# existing files so bundled sample.html / demo-app get updated.
ARCHIVE_TYPE=$(file -b "$WEBAPP_ARCHIVE")
echo "Web service package type: $ARCHIVE_TYPE"
echo "==> Extracting web service package into $WEB_ROOT (overwriting existing files)"
case "$ARCHIVE_TYPE" in
  *Zip*) unzip -q -o "$WEBAPP_ARCHIVE" -d "$WEB_ROOT" ;;
  *)     tar -xf "$WEBAPP_ARCHIVE" -C "$WEB_ROOT" ;;
esac
echo "==> Web service package extracted"

# Tidy up the downloaded archive.
rm -f "$WEBAPP_ARCHIVE"

# === User customization: build / start service below =========================
# The default deployment only extracts the package above. If your web service
# needs a build step (e.g. `npm ci && npm run build`) or a long-running service
# (e.g. a systemd unit, `pm2 start`, a container), add those commands here. They
# run as root at the end of the EC2 bootstrap. Example:
#
#   cd "$WEB_ROOT/myWebService"
#   npm ci
#   npm run build
#   # install & start a systemd service, etc.
#
# =============================================================================

echo "Web service package deployed into $WEB_ROOT."
