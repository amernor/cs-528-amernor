#!/usr/bin/env bash
# Startup script for the forbidden-request reporting VM (service2). setup.sh
# passes the code (app-code, app-requirements) and settings (PROJECT_ID,
# SUBSCRIPTION) as instance metadata. Runs as root.
#
# Run-once like startup.sh: the install happens on the first boot only, and
# the unit's ExecStartPre re-reads the code/settings from metadata on every
# start. service2's stdout: journalctl -u service2 -f
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi
set -euo pipefail

APP_DIR=/opt/service2

md() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

apt-get update
apt-get install -y python3-venv

id -u service2 >/dev/null 2>&1 || useradd --system --no-create-home service2
mkdir -p "$APP_DIR"
md app-requirements > "$APP_DIR/requirements.txt"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

cat > "$APP_DIR/fetch-config.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
md() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}
md app-code > /opt/service2/service2.py.new
mv /opt/service2/service2.py.new /opt/service2/service2.py
{
  for key in PROJECT_ID SUBSCRIPTION; do
    echo "$key=$(md "$key")"
  done
  echo "PYTHONUNBUFFERED=1"
} > /etc/service2.env.new
mv /etc/service2.env.new /etc/service2.env
EOF
chmod 755 "$APP_DIR/fetch-config.sh"
"$APP_DIR/fetch-config.sh"

cat > /etc/systemd/system/service2.service <<EOF
[Unit]
Description=HW5 service2 forbidden-request reporter
After=network-online.target
Wants=network-online.target

[Service]
User=service2
ExecStartPre=+$APP_DIR/fetch-config.sh
EnvironmentFile=/etc/service2.env
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/service2.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now service2

touch /var/log/startup_already_done
