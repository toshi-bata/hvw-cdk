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
apt-get update
apt-get upgrade -y
apt-get install -y \
    nginx \
    certbot python3-certbot-nginx \
    unzip build-essential curl \
    libglu1-mesa mesa-utils xserver-xorg xinit

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

    # Modern, client-agnostic routing: a WebSocket upgrade on the standard port
    # goes to the private SC server; any other request is served statically.
    # Works with the current demo-app (ws://host:<80|443>/?renderingLocation=..).
    location / {
        if ($http_upgrade = websocket) {
            proxy_pass http://127.0.0.1:11182;
        }
        try_files $uri $uri/ =404;
    }

    # Classic path-based reverse proxy (forum article style). Used by sample.html
    # and any client that targets ws(s)://host/wsproxy/<port>.
    location /wsproxy/ {
        rewrite /wsproxy/([^/]+) / break;
        proxy_pass http://127.0.0.1:$1;
    }

    location /httpproxy/ {
        rewrite /httpproxy/([^/]+)/([^/]+) /$2 break;
        proxy_pass http://127.0.0.1:$1;
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
