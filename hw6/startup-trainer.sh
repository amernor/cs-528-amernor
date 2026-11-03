#!/usr/bin/env bash
# Startup script for the hw6-trainer VM (passed by run.sh). Runs as root on
# first boot:
#   1. fetches the code and settings run.sh put in the instance metadata
#   2. installs Python packages in a venv
#   3. runs migrate_3nf.py (no-op if already migrated) and train_models.py
#   4. uploads its log and a _SUCCESS or _FAILED marker to
#      gs://$BUCKET/$OUT_PREFIX/, which run.sh waits for
#   5. powers the VM off (run.sh deletes it)
# Output on the VM: journalctl -u google-startup-scripts
set -uo pipefail

APP=/opt/hw6
LOG=/var/log/hw6-train.log

md() {
  curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

BUCKET="$(md BUCKET)"
OUT_PREFIX="$(md OUT_PREFIX)"
DEST="gs://$BUCKET/$OUT_PREFIX"

finish() {
  local marker="$1"
  gcloud storage cp "$LOG" "$DEST/train_log.txt" --quiet || true
  echo "$marker $(date -u '+%F %T UTC')" | gcloud storage cp - "$DEST/$marker" --quiet
  shutdown -h now
}

main() {
  set -e
  echo "==> hw6-trainer started $(date -u '+%F %T UTC')"
  mkdir -p "$APP/sql"
  md train-code    > "$APP/train_models.py"
  md migrate-code  > "$APP/migrate_3nf.py"
  md db-code       > "$APP/db.py"
  md requirements  > "$APP/requirements.txt"
  for f in schema_3nf precheck_3nf migrate_3nf verify_3nf; do
    md "sql-${f//_/-}" > "$APP/sql/$f.sql"
  done

  export PROJECT_ID="$(md PROJECT_ID)" INSTANCE_CONNECTION_NAME="$(md INSTANCE_CONNECTION_NAME)"
  export DB_NAME="$(md DB_NAME)" DB_USER="$(md DB_USER)" DB_PASSWORD_SECRET="$(md DB_PASSWORD_SECRET)"
  export BUCKET OUT_PREFIX SEED="$(md SEED)" PYTHONUNBUFFERED=1

  echo "==> Installing Python packages"
  apt-get update -q
  apt-get install -y -q python3-venv
  python3 -m venv "$APP/venv"
  "$APP/venv/bin/pip" install -q --upgrade pip
  "$APP/venv/bin/pip" install -q -r "$APP/requirements.txt"

  cd "$APP"
  echo; echo "==> migrate_3nf.py"
  "$APP/venv/bin/python" migrate_3nf.py
  echo; echo "==> train_models.py"
  "$APP/venv/bin/python" train_models.py
}

# not `if main`: bash ignores set -e inside a function used as a condition
( main ) >"$LOG" 2>&1
rc=$?
if (( rc == 0 )); then
  finish _SUCCESS
else
  echo "FAILED (exit $rc)" >>"$LOG"
  finish _FAILED
fi
