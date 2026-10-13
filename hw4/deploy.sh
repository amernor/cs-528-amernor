#!/usr/bin/env bash
# One-command setup for HW4: service accounts + IAM, static IP, firewall rule,
# Pub/Sub topic/subscription, then the service1 (web server) and service2 VMs
# with their startup scripts.
#
# Prereqs:
#   - gcloud installed and logged in (`gcloud auth login`) as a user who can
#     create service accounts and grant IAM roles (e.g. project Owner)
#   - the HW2 bucket already exists
#
# Usage (from anywhere):
#   PROJECT_ID=<your-project> ./deploy.sh
#
# Optional env overrides:
#   BUCKET (cs528-amernor)  REGION (us-central1)  ZONE (<REGION>-a)  PORT (8080)
#   TOPIC (forbidden-requests)  SUBSCRIPTION (forbidden-requests-sub)
#   CREATE_CLIENT=1          also create a client VM for the http client
#   CLIENT_MACHINE (e2-small)
#
# Re-running is safe: existing resources are kept, and existing VMs get the
# latest code pushed to their metadata and are rebooted to pick it up.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID, e.g. PROJECT_ID=my-project ./deploy.sh}"
BUCKET="${BUCKET:-cs528-amernor}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"
PORT="${PORT:-8080}"
TOPIC="${TOPIC:-forbidden-requests}"
SUBSCRIPTION="${SUBSCRIPTION:-forbidden-requests-sub}"
CLIENT_MACHINE="${CLIENT_MACHINE:-e2-small}"

WEB_VM=hw4-web
REPORT_VM=hw4-reporter
CLIENT_VM=hw4-client
WEB_SA="hw4-web-server@${PROJECT_ID}.iam.gserviceaccount.com"
REPORT_SA="hw4-forbidden-reporter@${PROJECT_ID}.iam.gserviceaccount.com"
STATIC_IP_NAME=hw4-web-ip
FIREWALL_RULE=hw4-allow-web
NETWORK_TAG=hw4-web

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

echo "==> Enabling APIs"
gc services enable compute.googleapis.com pubsub.googleapis.com \
  logging.googleapis.com monitoring.googleapis.com iam.googleapis.com

echo "==> Service accounts"
exists gc iam service-accounts describe "$WEB_SA" ||
  gc iam service-accounts create hw4-web-server --display-name "HW4 web server (service1)"
exists gc iam service-accounts describe "$REPORT_SA" ||
  gc iam service-accounts create hw4-forbidden-reporter --display-name "HW4 forbidden reporter (service2)"

echo "==> Pub/Sub topic and subscription"
exists gc pubsub topics describe "$TOPIC" || gc pubsub topics create "$TOPIC"
exists gc pubsub subscriptions describe "$SUBSCRIPTION" ||
  gc pubsub subscriptions create "$SUBSCRIPTION" --topic "$TOPIC"

echo "==> IAM (least privilege)"
# service1: read bucket objects, publish forbidden events, write logs/metrics
retry gc storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$WEB_SA" --role roles/storage.objectViewer
retry gc pubsub topics add-iam-policy-binding "$TOPIC" \
  --member "serviceAccount:$WEB_SA" --role roles/pubsub.publisher
for role in roles/logging.logWriter roles/monitoring.metricWriter; do
  retry gc projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$WEB_SA" --role "$role" --condition=None
done
# service2: only pull from its subscription
retry gc pubsub subscriptions add-iam-policy-binding "$SUBSCRIPTION" \
  --member "serviceAccount:$REPORT_SA" --role roles/pubsub.subscriber

echo "==> Static IP and firewall"
exists gc compute addresses describe "$STATIC_IP_NAME" --region "$REGION" ||
  gc compute addresses create "$STATIC_IP_NAME" --region "$REGION"
STATIC_IP="$(gc compute addresses describe "$STATIC_IP_NAME" --region "$REGION" --format 'value(address)')"
exists gc compute firewall-rules describe "$FIREWALL_RULE" ||
  gc compute firewall-rules create "$FIREWALL_RULE" --allow "tcp:$PORT" \
    --target-tags "$NETWORK_TAG" --source-ranges 0.0.0.0/0

# create_vm <name> <metadata> <metadata-from-file> [extra gcloud flags...]
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

echo "==> VM: $WEB_VM (service1, e2-micro, static IP $STATIC_IP)"
create_vm "$WEB_VM" \
  "PROJECT_ID=$PROJECT_ID,BUCKET=$BUCKET,TOPIC=$TOPIC,PORT=$PORT" \
  "startup-script=$HERE/startup/service1-startup.sh,app-code=$HERE/service1/main.py,app-requirements=$HERE/service1/requirements.txt" \
  --machine-type e2-micro --address "$STATIC_IP" --tags "$NETWORK_TAG" \
  --service-account "$WEB_SA" --scopes cloud-platform

echo "==> VM: $REPORT_VM (service2)"
create_vm "$REPORT_VM" \
  "PROJECT_ID=$PROJECT_ID,SUBSCRIPTION=$SUBSCRIPTION" \
  "startup-script=$HERE/startup/service2-startup.sh,app-code=$HERE/service2/service2.py,app-requirements=$HERE/service2/requirements.txt" \
  --machine-type e2-micro \
  --service-account "$REPORT_SA" --scopes cloud-platform

if [[ "${CREATE_CLIENT:-0}" == 1 ]]; then
  echo "==> VM: $CLIENT_VM (http client, no service account)"
  exists gc compute instances describe "$CLIENT_VM" --zone "$ZONE" ||
    gc compute instances create "$CLIENT_VM" --zone "$ZONE" \
      --machine-type "$CLIENT_MACHINE" \
      --image-family debian-12 --image-project debian-cloud \
      --no-service-account --no-scopes \
      --metadata-from-file "startup-script=$HERE/startup/client-startup.sh"
fi

cat <<EOF

Done. The VMs need a few minutes to install packages on first boot.
  Web server:     http://$STATIC_IP:$PORT/<file>
  Server logs:    gcloud compute ssh $WEB_VM --zone $ZONE -- sudo journalctl -u service1 -f
  Service2 out:   gcloud compute ssh $REPORT_VM --zone $ZONE -- sudo journalctl -u service2 -f
  Startup output: ... -- sudo journalctl -u google-startup-scripts
  Tear down:      PROJECT_ID=$PROJECT_ID $HERE/teardown.sh
EOF
