#!/usr/bin/env bash
# Tears down what setup.sh created that keeps billing:
#   - deletes the hw5-web / hw5-reporter / hw5-client VMs
#   - releases the static IP and deletes the firewall rule
#   - STOPS (never deletes) the Cloud SQL instance
#   - resumes the hourly DB-stopper job in case it was paused
#   - revokes the application-default credentials setup.sh logged in with
#
# Kept on purpose (free or nearly free): service accounts, Pub/Sub topic and
# subscription, the DB password secret, the Cloud Function and the scheduler
# job (the safety net that keeps the database stopped), and the stopped
# Cloud SQL instance itself (storage only).
#
# Usage (from anywhere):  ./cleanup.sh
set -euo pipefail

PROJECT_ID="superb-heaven-507521-u2"   # hardcoded on purpose (grading rule)
REGION=us-central1
ZONE=us-central1-a
DB_INSTANCE=hw5-db
STATIC_IP_NAME=hw5-web-ip
FIREWALL_RULE=hw5-allow-web
SCHEDULER_JOB=hw5-db-check

gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }
exists() { "$@" >/dev/null 2>&1; }

gcloud auth print-access-token >/dev/null 2>&1 || gcloud auth login

vms=()
for vm in hw5-web hw5-reporter hw5-client; do
  exists gc compute instances describe "$vm" --zone "$ZONE" && vms+=("$vm")
done
if (( ${#vms[@]} )); then
  echo "==> Deleting VMs: ${vms[*]}"
  gc compute instances delete "${vms[@]}" --zone "$ZONE"
fi

# reserved-but-unattached static IPs are billed, so release it
if exists gc compute addresses describe "$STATIC_IP_NAME" --region "$REGION"; then
  echo "==> Releasing static IP $STATIC_IP_NAME"
  gc compute addresses delete "$STATIC_IP_NAME" --region "$REGION"
fi

if exists gc compute firewall-rules describe "$FIREWALL_RULE"; then
  echo "==> Deleting firewall rule $FIREWALL_RULE"
  gc compute firewall-rules delete "$FIREWALL_RULE"
fi

# Cloud SQL is stopped, not deleted (grading rule)
if exists gc sql instances describe "$DB_INSTANCE"; then
  if [[ "$(gc sql instances describe "$DB_INSTANCE" --format 'value(settings.activationPolicy)')" != NEVER ]]; then
    echo "==> Stopping Cloud SQL $DB_INSTANCE"
    gc sql instances patch "$DB_INSTANCE" --activation-policy NEVER
  else
    echo "==> Cloud SQL $DB_INSTANCE already stopped"
  fi
fi

if exists gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" &&
   [[ "$(gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" --format 'value(state)')" == PAUSED ]]; then
  echo "==> Resuming scheduler job $SCHEDULER_JOB"
  gc scheduler jobs resume "$SCHEDULER_JOB" --location "$REGION"
fi

echo "==> Revoking application-default credentials"
gcloud auth application-default revoke --quiet 2>/dev/null || echo "    (none to revoke)"

echo "Done."
