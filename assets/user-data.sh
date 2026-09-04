#!/bin/bash
#
# HOOPS Visualize Web (HVW) server - EC2 bootstrap (Ubuntu 24.04 LTS)
#
# Sets up an NGINX front end that:
#   * serves the static web assets from /var/www/html, and
#   * reverse-proxies the WebSocket streaming connection to the private SC
#     server on 127.0.0.1:11182, so port 11182 is never exposed publicly.
#
# Two proxy styles are configured so both viewer clients work:
#   1. Header-based routing at "/" (modern): a WebSocket-upgrade request to the
#      normal HTTP(S) port is forwarded to 11182, everything else is served as
#      a static file. This lets the current demo-app (which connects to
#      host:port, path-less) stream through the proxy - just pass scPort=80/443.
#   2. Path-based routing "/wsproxy/<port>" (classic, from the TechSoft3D forum
#      article): kept for the bundled sample.html and older clients.
#
# The proprietary HVW SDK is NOT downloaded here. It is either installed
# automatically by assets/install-sdk.sh (when HVW_SDK_URL is supplied at deploy
# time) or transferred manually (see README).
#
set -eux
export DEBIAN_FRONTEND=noninteractive

# 1. System packages
#
# NOTE: awscli is intentionally NOT installed from apt. Ubuntu 24.04 (noble)
# dropped the `awscli` package, so `apt-get install awscli` aborts the whole
# install with "Package 'awscli' has no installation candidate". We install the
# official AWS CLI v2 below instead (used by the webapp S3 download step).
#
# Headless OpenGL: HOOPS server-side rendering / conversion (SC server, and
# Python apps such as HOOPS AI) need an OpenGL + display context even on a box
# with no monitor attached. Without it the HOOPS Converter dies with SIGSEGV
# (exit -11) - it is a missing DISPLAY, not a license problem. We install the
# GL / OSMesa runtime plus Xvfb (a virtual framebuffer X server) here, and run a
# system-wide `xvfb.service` (section 1c) that provides DISPLAY=:99 at boot.
apt-get update
apt-get upgrade -y
apt-get install -y \
    nginx \
    certbot python3-certbot-nginx \
    unzip build-essential curl \
    libglu1-mesa libgl1 libosmesa6 xvfb \
    libxrender1 libxext6 libsm6 mesa-utils

# 1b. AWS CLI v2 (official installer). Provides `aws` at /usr/local/bin/aws,
# used by the webapp download step (`aws s3 cp`) with the instance role creds.
# Skip if a working `aws` is already present (idempotent re-runs).
if ! command -v aws >/dev/null 2>&1; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o /tmp/awscliv2.zip
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install --update
    rm -rf /tmp/awscliv2.zip /tmp/aws
fi

# 1c. Headless virtual display (Xvfb) as a system service.
#
# HOOPS license validation and rendering/inference expect a display to exist.
# Running Xvfb on :99 as its own long-lived systemd unit gives every HOOPS
# workload on this box a ready-to-use DISPLAY=:99 immediately after boot - no
# manual `Xvfb ... &` before launching anything. Consumers (the SC server, or a
# Python app service) just set `Environment=DISPLAY=:99` and
# `Requires=xvfb.service`. Pattern from the TechSoft3D forum article
# "running HOOPS AI headless on Ubuntu 24.04 (EC2)".
cat > /etc/systemd/system/xvfb.service <<'XVFB_EOF'
[Unit]
Description=Virtual Framebuffer X Server (headless DISPLAY=:99 for HOOPS)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x960x24
Restart=on-failure

[Install]
WantedBy=multi-user.target
XVFB_EOF

systemctl daemon-reload
systemctl enable --now xvfb.service

# 2. Directories: static web root and the SDK install root
mkdir -p /var/www/html /opt/hvw

# 3. Add the mjs MIME type as a conf.d snippet (survives certbot edits)
cat > /etc/nginx/conf.d/mjs.conf <<'MJS_EOF'
types {
    text/javascript mjs;
}
MJS_EOF

# 4. NGINX front end (port 80; certbot adds the 443 block later)
cat > /etc/nginx/sites-available/default <<'NGINX_EOF'
# Map the Upgrade header so WebSocket connections keep the "upgrade" token
# while plain requests send a "close" connection.
map $http_upgrade $hvw_connection {
    default upgrade;
    ''      close;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html index.htm;
    server_name _;

    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection $hvw_connection;
    proxy_set_header Host       $host;
    proxy_read_timeout          86400s;

    # Defaults for the "who owns the site root" decision. On a plain HVW box
    # these stay as-is: WebSocket upgrades stream to the private SC server and
    # everything else is served as a static file. A Python app that owns the
    # root (install-pyapp.sh) overrides both via the include below.
    #   $ws_upstream : where a WebSocket upgrade on "/" is proxied.
    #   $pyapp_root  : root application upstream; empty = no root app.
    set $ws_upstream "http://127.0.0.1:11182";
    set $pyapp_root  "";

    # App-owned overrides. install-pyapp.sh drops a snippet into
    # /etc/nginx/pyapp-locations/ that re-points $pyapp_root (and $ws_upstream)
    # at the app, so /, /static, API routes and WebSockets all reach it - the
    # app is published on 80/443 without opening its port or loosening the
    # SC-server whitelist below. Wildcard include is optional (zero-match safe).
    include /etc/nginx/pyapp-locations/*.conf;

    # Modern, client-agnostic routing: a WebSocket upgrade on the standard port
    # goes to $ws_upstream (SC server by default); any other request is served
    # statically, then falls through to the root app (if any) via @pyapp.
    location / {
        if ($http_upgrade = websocket) {
            proxy_pass $ws_upstream;
        }
        try_files $uri $uri/ @pyapp;
    }

    # Fallback: anything not matched above goes to the root application when one
    # is installed ($pyapp_root set); otherwise 404. `return` is one of the few
    # directives that is safe inside `if` in a location context.
    location @pyapp {
        if ($pyapp_root = "") {
            return 404;
        }
        # NOTE: nginx does NOT merge proxy_set_header across levels - defining
        # any here discards the server-level ones (Host, Upgrade, Connection).
        # They must be restated, or the app receives Host: 127.0.0.1:<port> and
        # builds absolute URLs (e.g. thumbnail_url) pointing at its own loopback,
        # which the browser then fails to load.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $hvw_connection;
        proxy_pass $pyapp_root;
    }

    # Classic path-based reverse proxy (forum article style). Used by sample.html
    # and any client that targets ws(s)://host/wsproxy/<port>. The port is
    # whitelisted (only the HVW 11182 / 11180 ports) so clients cannot use these
    # routes to relay to arbitrary localhost ports. proxy_pass carries a variable
    # ($1), so the forwarded URI is stated explicitly ("/" and "/$2").
    location ~ ^/wsproxy/(11182|11180)$ {
        proxy_pass http://127.0.0.1:$1/;
    }

    location ~ ^/httpproxy/(11182|11180)/(.*)$ {
        proxy_pass http://127.0.0.1:$1/$2;
    }

    client_max_body_size 200M;
}
NGINX_EOF

nginx -t
systemctl reload nginx

# 5. Minimal sample viewer (classic path-based proxy). demo-app is deployed
#    separately by the SDK install and reached at /demo-app/.
cat > /var/www/html/sample.html <<'HTML_EOF'
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
    <head>
        <meta charset="utf-8"/>
        <title>Simple</title>
        <style>
            #container {
                width:600px;
                height:480px;
                position:relative;
                border: thin solid #000000;
            }
        </style>

        <script type="importmap">
            {
              "imports": {
                "@hoops/web-viewer": "/hoops-web-viewer.mjs"
              }
            }
        </script>
        <script type="module">
            import {WebViewer} from "@hoops/web-viewer";
            WebViewer.defaultEnginePath = "./";
        </script>

        <script type="module">
            import { WebViewer } from "@hoops/web-viewer";
            window.onload = function () {
                // Use ws:// when the page is served over HTTP and wss:// over
                // HTTPS, so the sample works with or without an SSL certificate.
                const proto = window.location.protocol === "https:" ? "wss://" : "ws://";
                const endpoint = proto + window.location.hostname + "/wsproxy/11182";
                const viewer = new WebViewer({
                    containerId: "container",
                    model: "microengine",
                    endpointUri: endpoint,
                    enginePath: "./"
                });
                viewer.start();
            };
        </script>
    </head>
    <body>
        <div id="container"></div>
    </body>
</html>
HTML_EOF

# 6. systemd service to auto-start the HVW SC server on boot. The server runs
#    from the SDK tree at /opt/hvw/current so its relative paths stay intact.
cat > /etc/onboot.sh <<'ONBOOT_EOF'
#!/bin/bash
cd /opt/hvw/current/server/node
../../3rd_party/node/bin/node --expose-gc ./lib/Startup.js
ONBOOT_EOF
chmod 0755 /etc/onboot.sh

cat > /etc/systemd/system/onboot.service <<'SERVICE_EOF'
[Unit]
Description=auto start commands in /etc/onboot.sh on boot
After=network.target
[Service]
Type=simple
ExecStart=/etc/onboot.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable onboot.service

echo "HVW bootstrap complete. Install the SDK (auto via HVW_SDK_URL or manual SCP), then start onboot.service."
