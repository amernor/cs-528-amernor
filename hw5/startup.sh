#!/usr/bin/env bash
# Startup script for the web server VM (service1). Passed by setup.sh with
#   --metadata-from-file startup-script=startup.sh
# together with the code (app-code, app-requirements) and settings
# (PROJECT_ID, BUCKET, TOPIC, PORT, INSTANCE_CONNECTION_NAME, DB_NAME, DB_USER,
# DB_PASSWORD_SECRET) as instance metadata. Runs as root.
#
# Run-once: the install below happens on the first boot only. Code/config
# updates still work on later boots because the systemd unit's ExecStartPre
# (fetch-config.sh) re-reads main.py and the settings from metadata every time
# the service starts. If requirements.txt changes, delete the VM (or
# /var/log/startup_already_done) so the venv is rebuilt.
# Output: journalctl -u google-startup-scripts
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi
set -euo pipefail

APP_DIR=/opt/service1

md() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

apt-get update
apt-get install -y python3-venv

# Ops Agent: reports memory usage for the load-test graphs
if ! systemctl is-active --quiet google-cloud-ops-agent; then
  curl -sSo /tmp/add-ops-agent.sh https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash /tmp/add-ops-agent.sh --also-install
fi

id -u service1 >/dev/null 2>&1 || useradd --system --no-create-home service1
mkdir -p "$APP_DIR"
md app-requirements > "$APP_DIR/requirements.txt"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

# Runs (as root) before every service start: latest code + settings from metadata
cat > "$APP_DIR/fetch-config.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
md() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}
md app-code > /opt/service1/main.py.new
mv /opt/service1/main.py.new /opt/service1/main.py
{
  for key in PROJECT_ID BUCKET TOPIC PORT INSTANCE_CONNECTION_NAME DB_NAME DB_USER DB_PASSWORD_SECRET; do
    echo "$key=$(md "$key")"
  done
  echo "TIMINGS_PATH=/var/lib/service1/timings.csv"
  echo "PYTHONUNBUFFERED=1"
} > /etc/service1.env.new
mv /etc/service1.env.new /etc/service1.env
EOF
chmod 755 "$APP_DIR/fetch-config.sh"
"$APP_DIR/fetch-config.sh"   # so /etc/service1.env exists before the first start

# StateDirectory creates /var/lib/service1 (owned by service1) for timings.csv
cat > /etc/systemd/system/service1.service <<EOF
[Unit]
Description=HW5 service1 web server
After=network-online.target
Wants=network-online.target

[Service]
User=service1
StateDirectory=service1
ExecStartPre=+$APP_DIR/fetch-config.sh
EnvironmentFile=/etc/service1.env
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now service1

touch /var/log/startup_already_done
