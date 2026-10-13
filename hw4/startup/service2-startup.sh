#!/usr/bin/env bash
# Startup script for the forbidden-request reporting VM (service2): installs
# dependencies, fetches the code and starts service2 automatically.
#
# Runs as root on every boot. deploy.sh passes the code and settings as
# instance metadata (app-code, app-requirements, PROJECT_ID, SUBSCRIPTION).
# service2's stdout: sudo journalctl -u service2 -f
set -euo pipefail

md() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

APP_DIR=/opt/service2
PROJECT_ID="$(md PROJECT_ID)"
SUBSCRIPTION="$(md SUBSCRIPTION)"

apt-get update
apt-get install -y python3-venv

id -u service2 >/dev/null 2>&1 || useradd --system --no-create-home service2
mkdir -p "$APP_DIR"
md app-code > "$APP_DIR/service2.py"
md app-requirements > "$APP_DIR/requirements.txt"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

cat > /etc/systemd/system/service2.service <<EOF
[Unit]
Description=HW4 service2 forbidden-request reporter
After=network-online.target
Wants=network-online.target

[Service]
User=service2
Environment=PROJECT_ID=$PROJECT_ID SUBSCRIPTION=$SUBSCRIPTION PYTHONUNBUFFERED=1
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/service2.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable service2
systemctl restart service2
