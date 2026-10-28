#!/usr/bin/env bash
# Deletes everything deploy.sh created that costs money (VMs, static IP) plus
# the firewall rule, so nothing keeps billing after the homework is done.
# Service accounts and the Pub/Sub topic/subscription are free and are kept.
#
# Usage: PROJECT_ID=<your-project> ./teardown.sh
#   (set REGION/ZONE too if you overrode them for deploy.sh)
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID, e.g. PROJECT_ID=my-project ./teardown.sh}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-${REGION}-a}"

gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }

for vm in hw4-web hw4-reporter hw4-client; do
  if gc compute instances describe "$vm" --zone "$ZONE" >/dev/null 2>&1; then
    echo "==> Deleting VM $vm"
    gc compute instances delete "$vm" --zone "$ZONE"
  fi
done

# reserved-but-unattached static IPs are billed, so release it
if gc compute addresses describe hw4-web-ip --region "$REGION" >/dev/null 2>&1; then
  echo "==> Releasing static IP"
  gc compute addresses delete hw4-web-ip --region "$REGION"
fi

if gc compute firewall-rules describe hw4-allow-web >/dev/null 2>&1; then
  echo "==> Deleting firewall rule"
  gc compute firewall-rules delete hw4-allow-web
fi

echo "Done."
