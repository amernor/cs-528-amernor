#!/usr/bin/env bash
# Startup script for the web server VM (service1): installs dependencies and
# the Ops Agent, fetches the code and starts the server automatically.
#
# Runs as root on every boot. deploy.sh passes the code and settings as
# instance metadata (app-code, app-requirements, PROJECT_ID, BUCKET, ...).
# Output: sudo journalctl -u google-startup-scripts
set -euo pipefail

md() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

APP_DIR=/opt/service1
PROJECT_ID="$(md PROJECT_ID)"
BUCKET="$(md BUCKET)"
TOPIC="$(md TOPIC)"
PORT="$(md PORT)"

apt-get update
apt-get install -y python3-venv

# Ops Agent: reports memory usage (needed for the stress test graphs)
if ! systemctl is-active --quiet google-cloud-ops-agent; then
  curl -sSo /tmp/add-ops-agent.sh https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash /tmp/add-ops-agent.sh --also-install
fi

id -u service1 >/dev/null 2>&1 || useradd --system --no-create-home service1
mkdir -p "$APP_DIR"
md app-code > "$APP_DIR/main.py"
md app-requirements > "$APP_DIR/requirements.txt"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

cat > /etc/systemd/system/service1.service <<EOF
[Unit]
Description=HW4 service1 web server
After=network-online.target
Wants=network-online.target

[Service]
User=service1
Environment=PROJECT_ID=$PROJECT_ID BUCKET=$BUCKET TOPIC=$TOPIC PORT=$PORT PYTHONUNBUFFERED=1
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable service1
systemctl restart service1
