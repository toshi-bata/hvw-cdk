#!/bin/bash
#
# HOOPS Visualize Web (HVW) server - EC2 bootstrap (Ubuntu 24.04 LTS)
#
# Based on the TechSoft3D articles:
#   "HOOPS Visualize Web HTTPS server with reverse proxy" (forum topic 1682)
#   and its prerequisite "How to setup HTTPS server with AWS" (topic 1680).
#
# Installs NGINX + certbot, configures the reverse proxy, adds the mjs MIME
# type, deploys a minimal sample.html, and registers the systemd boot service.
#
# NOTE: The HOOPS Visualize Web SDK (tar.gz) is proprietary and is NOT
# downloaded here. After deployment, transfer it via SCP and run setup
# (see README, "Post-deploy: install the HVW SDK").
#
set -eux
export DEBIAN_FRONTEND=noninteractive

# 1. System packages
apt-get update
apt-get upgrade -y
apt-get install -y \
    nginx \
    certbot python3-certbot-nginx \
    unzip build-essential \
    libglu1-mesa mesa-utils xserver-xorg xinit

# 2. Web root directories expected by the article
mkdir -p /var/www/html

# 3. Add the mjs MIME type as a conf.d snippet (survives certbot edits)
cat > /etc/nginx/conf.d/mjs.conf <<'MJS_EOF'
types {
    text/javascript mjs;
}
MJS_EOF

# 4. NGINX reverse-proxy site (port 80; certbot adds the 443 block later)
cat > /etc/nginx/sites-available/default <<'NGINX_EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html index.htm;
    server_name _;

    location / {
        try_files $uri $uri/ =404;
    }

    location /wsproxy/ {
        rewrite /wsproxy/([^/]+) / break;
        proxy_pass http://127.0.0.1:$1;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
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

# 5. Minimal sample viewer (served once SDK files are in place)
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

# 6. systemd service to auto-start the HVW server on boot
cat > /etc/onboot.sh <<'ONBOOT_EOF'
#!/bin/bash
cd /var/www/server/node
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

echo "HVW bootstrap complete. Transfer the SDK via SCP and start onboot.service."
