#!/usr/bin/env bash
# HW6 one-command run. Nothing is assumed to exist already; every resource
# the run needs is checked and, if missing, created:
#   1. APIs; the bucket; the DB password secret
#   2. Cloud SQL: the instance (created if missing) is started; the database
#      and the app user are created if missing (the user's password is always
#      re-synced with the secret)
#   3. the hw6-trainer service account + least-privilege IAM grants
#   4. the hw6-trainer VM; its startup script (startup-trainer.sh) runs
#        ensure_data.py   HW5 tables created if missing, data restored from
#                         the bucket snapshot if empty
#        migrate_3nf.py   3NF tables created if missing, data transferred
#        train_models.py  both models; test-set output -> gs://$BUCKET/$OUT_PREFIX/
#   5. waits for the output, then runs cleanup.sh: deletes the VM, the
#      service account and its grants, STOPS the database (also on errors /
#      Ctrl-C)
#   6. prints the output files from the bucket on the terminal
#
# Prereqs: gcloud and openssl; an account that can create service accounts
# and grant IAM roles (e.g. project Owner).
#
# Usage (from anywhere):  ./run.sh
# Optional env: SEED (528)  PRINT_ROWS (25 rows per CSV; 0 = whole files)
#               TIMEOUT_MIN (40)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/config.sh"
DEST="gs://$BUCKET/$OUT_PREFIX"

SEED="${SEED:-528}"
PRINT_ROWS="${PRINT_ROWS:-25}"
TIMEOUT_MIN="${TIMEOUT_MIN:-40}"

# new service accounts take a few seconds to become visible to IAM
retry() {
  for _ in 1 2 3 4 5 6; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 10
  done
  "$@" >/dev/null
}
random_password() { openssl rand -base64 24 | tr -d '/+=\n'; }

echo "==> Checking prerequisites"
for tool in gcloud openssl; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done
gcloud auth print-access-token >/dev/null 2>&1 || gcloud auth login

echo "==> Enabling APIs"
gc services enable compute.googleapis.com sqladmin.googleapis.com \
  secretmanager.googleapis.com storage.googleapis.com iam.googleapis.com

# from here on, any exit (success, error, Ctrl-C) runs cleanup.sh once
cleaned=0
cleanup() {
  (( cleaned )) && return 0
  cleaned=1
  echo
  "$HERE/cleanup.sh" || echo "WARNING: cleanup.sh reported an error" >&2
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> Bucket gs://$BUCKET"
if exists gc storage buckets describe "gs://$BUCKET"; then
  echo "    exists"
else
  gc storage buckets create "gs://$BUCKET" --location "$REGION" --uniform-bucket-level-access
fi

echo "==> DB password secret $DB_PASSWORD_SECRET"
if exists gc secrets describe "$DB_PASSWORD_SECRET"; then
  echo "    exists"
else
  random_password | gc secrets create "$DB_PASSWORD_SECRET" \
    --replication-policy automatic --data-file=-
fi
# a secret without an enabled version cannot be read; add one if needed
exists gc secrets versions access latest --secret "$DB_PASSWORD_SECRET" ||
  random_password | gc secrets versions add "$DB_PASSWORD_SECRET" --data-file=-

echo "==> Cloud SQL instance $DB_INSTANCE ($(ts))"
# the hourly HW5 stopper must not stop the DB in the middle of the run
if exists gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION"; then
  gc scheduler jobs pause "$SCHEDULER_JOB" --location "$REGION" >/dev/null 2>&1 || true
fi
if exists gc sql instances describe "$DB_INSTANCE"; then
  echo "    exists; starting it"
  [[ "$(db_field settings.activationPolicy)" == ALWAYS ]] ||
    gc sql instances patch "$DB_INSTANCE" --activation-policy ALWAYS --async >/dev/null
else
  echo "    not found; creating it (5-10 min)"
  # same settings as HW5; the root password is random and not stored
  gc sql instances create "$DB_INSTANCE" \
    --database-version MYSQL_8_0 --edition ENTERPRISE --tier db-f1-micro \
    --region "$REGION" --availability-type zonal \
    --storage-type HDD --storage-size 10 --no-backup \
    --root-password "$(random_password)" ||
    echo "    (create returned early; waiting for the instance)"
  exists gc sql instances describe "$DB_INSTANCE" ||
    { echo "ERROR: Cloud SQL instance was not created" >&2; exit 1; }
fi
# RUNNABLE is reported before the start operation finishes, and connections
# are dropped until it does, so wait for both
for i in $(seq 120); do
  state="$(db_field state)"
  pending="$(gc sql operations list --instance "$DB_INSTANCE" --limit 5 \
             --filter 'status!=DONE' --format 'value(name)' | wc -l | tr -d ' ')"
  [[ "$state" == RUNNABLE && "$pending" == 0 ]] && break
  (( i == 120 )) && { echo "ERROR: $DB_INSTANCE did not become ready" >&2; exit 1; }
  echo "    state ${state:-unknown}, $pending operation(s) running... ($(ts))"
  sleep 10
done
INSTANCE_CONNECTION_NAME="$(db_field connectionName)"
echo "    RUNNABLE ($INSTANCE_CONNECTION_NAME)"

echo "==> Database $DB_NAME and user $DB_USER"
if exists gc sql databases describe "$DB_NAME" --instance "$DB_INSTANCE"; then
  echo "    database $DB_NAME exists"
else
  echo "    creating database $DB_NAME"
  gc sql databases create "$DB_NAME" --instance "$DB_INSTANCE"
fi
password="$(gc secrets versions access latest --secret "$DB_PASSWORD_SECRET")"
if gc sql users list --instance "$DB_INSTANCE" --format 'value(name)' | grep -qx "$DB_USER"; then
  echo "    user $DB_USER exists; syncing its password with the secret"
  gc sql users set-password "$DB_USER" --host % --instance "$DB_INSTANCE" --password "$password"
else
  echo "    creating user $DB_USER"
  gc sql users create "$DB_USER" --host % --instance "$DB_INSTANCE" --password "$password"
fi
unset password
echo "    (tables are checked/created on the VM: ensure_data.py, migrate_3nf.py)"

echo "==> Service account $SA (least privilege)"
exists gc iam service-accounts describe "$SA" ||
  gc iam service-accounts create "$SA_NAME" --display-name "HW6 model trainer VM"
# connect to Cloud SQL, read the DB password, read/write the bucket
retry gc projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$SA" --role roles/cloudsql.client --condition=None
retry gc secrets add-iam-policy-binding "$DB_PASSWORD_SECRET" \
  --member "serviceAccount:$SA" --role roles/secretmanager.secretAccessor
retry gc storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$SA" --role roles/storage.objectAdmin
echo "    granted roles/cloudsql.client, secretAccessor on $DB_PASSWORD_SECRET, objectAdmin on gs://$BUCKET"

echo "==> Clearing old output in $DEST/"
gc storage rm "$DEST/**" >/dev/null 2>&1 || true

if exists gc compute instances describe "$VM" --zone "$ZONE"; then
  echo "==> Deleting leftover VM $VM"
  gc compute instances delete "$VM" --zone "$ZONE"
fi
echo "==> Creating VM $VM ($MACHINE) ($(ts))"
gc compute instances create "$VM" --zone "$ZONE" --machine-type "$MACHINE" \
  --image-family debian-12 --image-project debian-cloud \
  --service-account "$SA" --scopes cloud-platform \
  --metadata "PROJECT_ID=$PROJECT_ID,INSTANCE_CONNECTION_NAME=$INSTANCE_CONNECTION_NAME,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD_SECRET=$DB_PASSWORD_SECRET,BUCKET=$BUCKET,OUT_PREFIX=$OUT_PREFIX,DATA_PREFIX=$DATA_PREFIX,SEED=$SEED" \
  --metadata-from-file "startup-script=$HERE/startup-trainer.sh,train-code=$HERE/train_models.py,migrate-code=$HERE/migrate_3nf.py,ensure-code=$HERE/ensure_data.py,db-code=$HERE/db.py,requirements=$HERE/requirements.txt,sql-hw5-schema=$HERE/sql/hw5_schema.sql,sql-schema-3nf=$HERE/sql/schema_3nf.sql,sql-precheck-3nf=$HERE/sql/precheck_3nf.sql,sql-migrate-3nf=$HERE/sql/migrate_3nf.sql,sql-verify-3nf=$HERE/sql/verify_3nf.sql"

echo "==> Waiting for the VM: install packages, check data, migrate, train (up to ${TIMEOUT_MIN} min)"
start=$SECONDS
result=""
while (( SECONDS - start < TIMEOUT_MIN * 60 )); do
  if exists gc storage ls "$DEST/_SUCCESS"; then result=_SUCCESS; break; fi
  if exists gc storage ls "$DEST/_FAILED"; then result=_FAILED; break; fi
  echo "    still running... $(( (SECONDS - start) / 60 ))m$(( (SECONDS - start) % 60 ))s"
  sleep 20
done
[[ -n "$result" ]] || echo "ERROR: no result after ${TIMEOUT_MIN} min" >&2
echo "    VM finished: ${result:-timeout} ($(ts))"

# done with the cloud resources: delete the VM + service account, stop the DB
cleanup

echo
echo "==> Output files in $DEST/"
gc storage ls -l "$DEST/" || true

if [[ "$result" != _SUCCESS ]]; then
  echo; echo "======== train_log.txt ========"
  gc storage cat "$DEST/train_log.txt" 2>/dev/null || echo "(no log uploaded)"
  exit 1
fi

echo; echo "======== model_summary.txt ========"
gc storage cat "$DEST/model_summary.txt"

for f in country_model_test_predictions.csv income_model_test_predictions.csv; do
  echo; echo "======== $f ========"
  if (( PRINT_ROWS == 0 )); then
    gc storage cat "$DEST/$f"
  else
    tmp="$(mktemp)"
    gc storage cat "$DEST/$f" > "$tmp"
    head -n $(( PRINT_ROWS + 1 )) "$tmp"
    echo "... ($(( $(wc -l < "$tmp") - 1 )) rows in total; PRINT_ROWS=0 prints every row)"
    rm -f "$tmp"
  fi
done

echo
echo "Done. Model output: $DEST/"
