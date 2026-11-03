#!/usr/bin/env bash
# Removes everything run.sh creates for a run, and stops the database.
# run.sh calls this at the end of every run (also on errors / Ctrl-C); it can
# also be run on its own, any number of times.
#
#   - deletes the hw6-trainer VM
#   - removes the hw6-trainer service account's IAM grants (project, secret,
#     bucket) and deletes the service account
#   - STOPS (never deletes) the Cloud SQL instance
#   - resumes the HW5 hourly DB-stopper job if it is paused
#
# Kept on purpose, because they are the homework's results or its input:
# the database and its tables (HW5 source + 3NF), the model output in
# gs://cs528-amernor/hw6/, the data snapshot in gs://cs528-amernor/hw6-data/,
# the bucket and the DB password secret (also used by HW5).
#
# Usage (from anywhere):  ./cleanup.sh
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

gcloud auth print-access-token >/dev/null 2>&1 || gcloud auth login

if exists gc compute instances describe "$VM" --zone "$ZONE"; then
  echo "==> Deleting VM $VM"
  gc compute instances delete "$VM" --zone "$ZONE"
else
  echo "==> VM $VM: not present"
fi

if exists gc iam service-accounts describe "$SA"; then
  echo "==> Removing IAM grants and service account $SA"
  member="serviceAccount:$SA"
  gc projects remove-iam-policy-binding "$PROJECT_ID" --member "$member" \
    --role roles/cloudsql.client --condition=None >/dev/null 2>&1 &&
    echo "    removed roles/cloudsql.client on project $PROJECT_ID"
  gc secrets remove-iam-policy-binding "$DB_PASSWORD_SECRET" --member "$member" \
    --role roles/secretmanager.secretAccessor >/dev/null 2>&1 &&
    echo "    removed roles/secretmanager.secretAccessor on secret $DB_PASSWORD_SECRET"
  gc storage buckets remove-iam-policy-binding "gs://$BUCKET" --member "$member" \
    --role roles/storage.objectAdmin >/dev/null 2>&1 &&
    echo "    removed roles/storage.objectAdmin on gs://$BUCKET"
  gc iam service-accounts delete "$SA" && echo "    deleted $SA"
else
  echo "==> Service account $SA: not present"
fi

if exists gc sql instances describe "$DB_INSTANCE"; then
  if [[ "$(db_field settings.activationPolicy)" != NEVER ]]; then
    echo "==> Stopping Cloud SQL $DB_INSTANCE"
    gc sql instances patch "$DB_INSTANCE" --activation-policy NEVER
  fi
  echo "==> Cloud SQL $DB_INSTANCE: $(db_field state) (activation policy $(db_field settings.activationPolicy))"
fi

if exists gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" &&
   [[ "$(gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" --format 'value(state)')" == PAUSED ]]; then
  echo "==> Resuming scheduler job $SCHEDULER_JOB"
  gc scheduler jobs resume "$SCHEDULER_JOB" --location "$REGION" >/dev/null
fi

vm_left=0; sa_left=0
exists gc compute instances describe "$VM" --zone "$ZONE" && vm_left=1
exists gc iam service-accounts describe "$SA" && sa_left=1
echo "==> Left behind by HW6: $vm_left VM(s), $sa_left service account(s)"
