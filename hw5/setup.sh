#!/usr/bin/env bash
# One-command setup for HW5. Provisions (or, on re-run, starts/updates):
#   - APIs, service accounts, least-privilege IAM
#   - Pub/Sub topic + subscription (service1 -> service2)
#   - Cloud SQL (MySQL 8.0, Enterprise db-f1-micro) + schema   [setup_db]
#   - static IP + firewall rule for the web server
#   - VMs: hw5-web (service1), hw5-reporter (service2), hw5-client
#   - Cloud Function hw5-db-stopper + hourly Cloud Scheduler job hw5-db-check
#
# Prereqs: gcloud, python3 and openssl installed; an account that can create
# service accounts and grant IAM roles (e.g. project Owner). The script runs
# `gcloud auth login` / `gcloud auth application-default login` if needed.
#
# Usage (from anywhere):  ./setup.sh
# Optional env: WEB_MACHINE (e2-medium)  FORCE_SCHEMA=1 (re-run setup_schema.py
#               even when the database already exists)
#
# Re-running is safe: existing resources are kept, a stopped database is
# started, and the web/reporter VMs get the latest code from metadata and are
# rebooted to pick it up.
set -euo pipefail

PROJECT_ID="superb-heaven-507521-u2"   # hardcoded on purpose (grading rule)
REGION=us-central1
ZONE=us-central1-a
BUCKET=cs528-amernor
PORT=8080
TOPIC=hw5-forbidden-requests
SUBSCRIPTION=hw5-forbidden-requests-sub

DB_INSTANCE=hw5-db
DB_NAME=hw5
DB_USER=webapp
DB_PASSWORD_SECRET=hw5-db-password

WEB_VM=hw5-web
REPORT_VM=hw5-reporter
CLIENT_VM=hw5-client
WEB_MACHINE="${WEB_MACHINE:-e2-medium}"
REPORT_MACHINE=e2-micro
CLIENT_MACHINE=e2-small
STATIC_IP_NAME=hw5-web-ip
FIREWALL_RULE=hw5-allow-web
NETWORK_TAG=hw5-web

FUNCTION=hw5-db-stopper
SCHEDULER_JOB=hw5-db-check

WEB_SA="hw5-web-server@${PROJECT_ID}.iam.gserviceaccount.com"
REPORT_SA="hw5-forbidden-reporter@${PROJECT_ID}.iam.gserviceaccount.com"
STOPPER_SA="hw5-db-stopper@${PROJECT_ID}.iam.gserviceaccount.com"

HERE="$(cd "$(dirname "$0")" && pwd)"

gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }
exists() { "$@" >/dev/null 2>&1; }
# new service accounts take a few seconds to become visible to IAM
retry() {
  for _ in 1 2 3 4 5; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 10
  done
  "$@" >/dev/null
}
random_password() { openssl rand -base64 24 | tr -d '/+=\n'; }

echo "==> Checking prerequisites"
for tool in gcloud python3 openssl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done
gcloud auth print-access-token >/dev/null 2>&1 || gcloud auth login
# setup_schema.py and tools/ talk to Cloud SQL / Secret Manager with ADC
gcloud auth application-default print-access-token >/dev/null 2>&1 ||
  gcloud auth application-default login
gcloud auth application-default set-quota-project "$PROJECT_ID" >/dev/null 2>&1 || true

echo "==> Enabling APIs (can take a minute the first time)"
gc services enable compute.googleapis.com pubsub.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com iam.googleapis.com \
  sqladmin.googleapis.com secretmanager.googleapis.com \
  cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com cloudscheduler.googleapis.com

echo "==> Service accounts"
exists gc iam service-accounts describe "$WEB_SA" ||
  gc iam service-accounts create hw5-web-server --display-name "HW5 web server (service1)"
exists gc iam service-accounts describe "$REPORT_SA" ||
  gc iam service-accounts create hw5-forbidden-reporter --display-name "HW5 forbidden reporter (service2)"
exists gc iam service-accounts describe "$STOPPER_SA" ||
  gc iam service-accounts create hw5-db-stopper --display-name "HW5 hourly Cloud SQL stopper"

echo "==> Pub/Sub topic and subscription"
exists gc pubsub topics describe "$TOPIC" || gc pubsub topics create "$TOPIC"
exists gc pubsub subscriptions describe "$SUBSCRIPTION" ||
  gc pubsub subscriptions create "$SUBSCRIPTION" --topic "$TOPIC"

echo "==> DB password secret"
ensure_db_secret() {
  if ! exists gc secrets describe "$DB_PASSWORD_SECRET"; then
    random_password | gc secrets create "$DB_PASSWORD_SECRET" \
      --replication-policy automatic --data-file=-
  fi
}
ensure_db_secret

echo "==> Local Python venv for setup_schema.py and tools/"
[[ -x "$HERE/.venv/bin/python" ]] || python3 -m venv "$HERE/.venv"
"$HERE/.venv/bin/pip" install -q --upgrade pip
"$HERE/.venv/bin/pip" install -q -r "$HERE/requirements-local.txt"

db_field() { gc sql instances describe "$DB_INSTANCE" --format "value($1)"; }

start_db() {
  if [[ "$(db_field settings.activationPolicy)" != ALWAYS ]]; then
    echo "    starting $DB_INSTANCE (activation policy -> ALWAYS)"
    gc sql instances patch "$DB_INSTANCE" --activation-policy ALWAYS
  fi
  local state
  for _ in $(seq 60); do
    state="$(db_field state)"
    [[ "$state" == RUNNABLE ]] && { echo "    $DB_INSTANCE is RUNNABLE"; return 0; }
    echo "    $DB_INSTANCE state: ${state:-unknown}, waiting..."
    sleep 10
  done
  echo "ERROR: $DB_INSTANCE did not become RUNNABLE" >&2
  return 1
}

# Cloud SQL: if the instance and database already exist, just start the server
# and skip creation; otherwise create + start it and build the schema with
# setup_schema.py.
setup_db() {
  local instance_exists=0
  exists gc sql instances describe "$DB_INSTANCE" && instance_exists=1

  # the database can only be looked up while the server is running
  (( instance_exists )) && start_db

  if (( instance_exists )) && exists gc sql databases describe "$DB_NAME" --instance "$DB_INSTANCE"; then
    echo "    Cloud SQL $DB_INSTANCE/$DB_NAME exists: started, skipping creation"
    if [[ "${FORCE_SCHEMA:-0}" == 1 ]]; then
      echo "    FORCE_SCHEMA=1: re-running setup_schema.py"
      run_setup_schema
    fi
    return 0
  fi

  if (( ! instance_exists )); then
    echo "    creating Cloud SQL instance $DB_INSTANCE (takes 5-10 min)"
    # --edition/--tier are explicit: newer gcloud may default to Enterprise Plus.
    # The root password is random and not stored; nothing logs in as root.
    gc sql instances create "$DB_INSTANCE" \
      --database-version MYSQL_8_0 --edition ENTERPRISE --tier db-f1-micro \
      --region "$REGION" --availability-type zonal \
      --storage-type HDD --storage-size 10 --no-backup \
      --root-password "$(random_password)" ||
      echo "    (create returned early; waiting for the instance)"
    exists gc sql instances describe "$DB_INSTANCE" ||
      { echo "ERROR: Cloud SQL instance was not created" >&2; return 1; }
  fi
  start_db

  echo "    creating database $DB_NAME and user $DB_USER"
  exists gc sql databases describe "$DB_NAME" --instance "$DB_INSTANCE" ||
    gc sql databases create "$DB_NAME" --instance "$DB_INSTANCE"
  local password
  password="$(gc secrets versions access latest --secret "$DB_PASSWORD_SECRET")"
  if gc sql users list --instance "$DB_INSTANCE" --format 'value(name)' | grep -qx "$DB_USER"; then
    gc sql users set-password "$DB_USER" --host % --instance "$DB_INSTANCE" --password "$password"
  else
    gc sql users create "$DB_USER" --host % --instance "$DB_INSTANCE" --password "$password"
  fi

  run_setup_schema
}

run_setup_schema() {
  PROJECT_ID="$PROJECT_ID" INSTANCE_CONNECTION_NAME="$INSTANCE_CONNECTION_NAME" \
  DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASSWORD_SECRET="$DB_PASSWORD_SECRET" \
    "$HERE/.venv/bin/python" "$HERE/setup_schema.py"
}

echo "==> Cloud SQL"
# the connection name is fixed by project/region/instance, so it is known
# before the instance exists (setup_schema.py needs it)
INSTANCE_CONNECTION_NAME="$PROJECT_ID:$REGION:$DB_INSTANCE"
setup_db
INSTANCE_CONNECTION_NAME="$(db_field connectionName)"

echo "==> IAM (least privilege)"
# service1: read bucket objects, publish forbidden events, write logs/metrics,
# connect to Cloud SQL, read the DB password
retry gc storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$WEB_SA" --role roles/storage.objectViewer
retry gc pubsub topics add-iam-policy-binding "$TOPIC" \
  --member "serviceAccount:$WEB_SA" --role roles/pubsub.publisher
for role in roles/logging.logWriter roles/monitoring.metricWriter roles/cloudsql.client; do
  retry gc projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$WEB_SA" --role "$role" --condition=None
done
retry gc secrets add-iam-policy-binding "$DB_PASSWORD_SECRET" \
  --member "serviceAccount:$WEB_SA" --role roles/secretmanager.secretAccessor
# service2: only pull from its subscription
retry gc pubsub subscriptions add-iam-policy-binding "$SUBSCRIPTION" \
  --member "serviceAccount:$REPORT_SA" --role roles/pubsub.subscriber
# DB stopper function: read + patch the Cloud SQL instance, write its logs
for role in roles/cloudsql.editor roles/logging.logWriter; do
  retry gc projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$STOPPER_SA" --role "$role" --condition=None
done

echo "==> Static IP and firewall"
exists gc compute addresses describe "$STATIC_IP_NAME" --region "$REGION" ||
  gc compute addresses create "$STATIC_IP_NAME" --region "$REGION"
STATIC_IP="$(gc compute addresses describe "$STATIC_IP_NAME" --region "$REGION" --format 'value(address)')"
exists gc compute firewall-rules describe "$FIREWALL_RULE" ||
  gc compute firewall-rules create "$FIREWALL_RULE" --allow "tcp:$PORT" \
    --target-tags "$NETWORK_TAG" --source-ranges 0.0.0.0/0

# create_vm <name> <metadata> <metadata-from-file> [extra create flags...]
# Existing VMs get new metadata and a reset: the startup script's run-once lock
# skips the install, and the systemd unit re-reads code/config from metadata.
create_vm() {
  local name="$1" metadata="$2" metadata_files="$3"
  shift 3
  if exists gc compute instances describe "$name" --zone "$ZONE"; then
    echo "    $name exists: updating code and rebooting"
    gc compute instances add-metadata "$name" --zone "$ZONE" \
      --metadata "$metadata" --metadata-from-file "$metadata_files"
    gc compute instances reset "$name" --zone "$ZONE"
  else
    gc compute instances create "$name" --zone "$ZONE" \
      --image-family debian-12 --image-project debian-cloud \
      --metadata "$metadata" --metadata-from-file "$metadata_files" "$@"
  fi
}

echo "==> VM: $WEB_VM (service1, $WEB_MACHINE, static IP $STATIC_IP)"
create_vm "$WEB_VM" \
  "PROJECT_ID=$PROJECT_ID,BUCKET=$BUCKET,TOPIC=$TOPIC,PORT=$PORT,INSTANCE_CONNECTION_NAME=$INSTANCE_CONNECTION_NAME,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD_SECRET=$DB_PASSWORD_SECRET" \
  "startup-script=$HERE/startup.sh,app-code=$HERE/service1/main.py,app-requirements=$HERE/service1/requirements.txt" \
  --machine-type "$WEB_MACHINE" --address "$STATIC_IP" --tags "$NETWORK_TAG" \
  --service-account "$WEB_SA" --scopes cloud-platform

echo "==> VM: $REPORT_VM (service2)"
create_vm "$REPORT_VM" \
  "PROJECT_ID=$PROJECT_ID,SUBSCRIPTION=$SUBSCRIPTION" \
  "startup-script=$HERE/startup-service2.sh,app-code=$HERE/service2/service2.py,app-requirements=$HERE/service2/requirements.txt" \
  --machine-type "$REPORT_MACHINE" \
  --service-account "$REPORT_SA" --scopes cloud-platform

# Ubuntu 24.04: the Linux http client needs glibc >= 2.38 (Debian 12 has 2.36).
# Never reset on re-run so a load test in progress is not killed.
echo "==> VM: $CLIENT_VM (http client, no service account)"
if exists gc compute instances describe "$CLIENT_VM" --zone "$ZONE"; then
  echo "    $CLIENT_VM exists: leaving it running"
else
  gc compute instances create "$CLIENT_VM" --zone "$ZONE" \
    --machine-type "$CLIENT_MACHINE" \
    --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
    --no-service-account --no-scopes \
    --metadata-from-file "startup-script=$HERE/startup-client.sh"
fi

echo "==> Cloud Function $FUNCTION + Cloud Scheduler job $SCHEDULER_JOB"
# Cloud Build runs as the Compute default SA in new projects and needs this
# role to build the function
PROJECT_NUMBER="$(gc projects describe "$PROJECT_ID" --format 'value(projectNumber)')"
retry gc projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role roles/cloudbuild.builds.builder --condition=None
gc functions deploy "$FUNCTION" --gen2 --region "$REGION" --runtime python312 \
  --source "$HERE/db_stopper" --entry-point stop_db_if_running \
  --trigger-http --no-allow-unauthenticated \
  --service-account "$STOPPER_SA" \
  --set-env-vars "PROJECT_ID=$PROJECT_ID,DB_INSTANCE=$DB_INSTANCE" \
  --memory 256Mi --timeout 120s
# the stopper SA is also the scheduler's OIDC identity, so it must be able to invoke
retry gc functions add-invoker-policy-binding "$FUNCTION" --region "$REGION" \
  --member "serviceAccount:$STOPPER_SA"
FUNCTION_URL="$(gc functions describe "$FUNCTION" --gen2 --region "$REGION" --format 'value(serviceConfig.uri)')"
scheduler_flags=(--location "$REGION" --schedule "0 * * * *" --time-zone UTC
  --uri "$FUNCTION_URL" --http-method POST
  --oidc-service-account-email "$STOPPER_SA" --oidc-token-audience "$FUNCTION_URL")
if exists gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION"; then
  gc scheduler jobs update http "$SCHEDULER_JOB" "${scheduler_flags[@]}"
else
  gc scheduler jobs create http "$SCHEDULER_JOB" "${scheduler_flags[@]}"
fi
SCHEDULER_STATE="$(gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" --format 'value(state)')"

cat <<EOF

Done. The VMs need a few minutes to install packages on first boot.
  Web server:     http://$STATIC_IP:$PORT/<file>
  Server logs:    gcloud compute ssh $WEB_VM --zone $ZONE -- sudo journalctl -u service1 -f
  Service2 out:   gcloud compute ssh $REPORT_VM --zone $ZONE -- sudo journalctl -u service2 -f
  Startup output: ... -- sudo journalctl -u google-startup-scripts
  DB tables:      $HERE/.venv/bin/python $HERE/tools/show_tables.py
  Tear down:      $HERE/cleanup.sh

  !! The hourly job $SCHEDULER_JOB (now $SCHEDULER_STATE) STOPS the database at
  !! the top of every hour. While you are working with the DB:
       $HERE/tools/scheduler.sh pause      ... and when done:
       $HERE/tools/scheduler.sh resume
EOF
