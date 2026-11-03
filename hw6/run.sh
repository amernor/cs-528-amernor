#!/usr/bin/env bash
# HW6 one-command run:
#   1. enables the APIs, creates the hw6-trainer service account + IAM
#   2. starts the HW5 Cloud SQL database (pauses the hourly DB stopper job)
#   3. creates the hw6-trainer VM; its startup script (startup-trainer.sh)
#      runs migrate_3nf.py and train_models.py and writes the model output
#      to gs://$BUCKET/$OUT_PREFIX/
#   4. waits for the output, then STOPS the database, resumes the stopper
#      job and DELETES the VM (also on failure or Ctrl-C)
#   5. prints the output files from the bucket on the terminal
#
# Prereqs: gcloud; an account that can create service accounts and grant IAM
# roles (e.g. project Owner); the HW5 database hw5-db with its data.
#
# Usage (from anywhere):  ./run.sh
# Optional env: SEED (528)  PRINT_ROWS (25 rows per CSV; 0 = whole files)
#               TIMEOUT_MIN (30)
set -euo pipefail

PROJECT_ID="superb-heaven-507521-u2"   # hardcoded on purpose (grading rule)
REGION=us-central1
ZONE=us-central1-a
BUCKET=cs528-amernor
OUT_PREFIX=hw6
DEST="gs://$BUCKET/$OUT_PREFIX"

DB_INSTANCE=hw5-db
DB_NAME=hw5
DB_USER=webapp
DB_PASSWORD_SECRET=hw5-db-password
SCHEDULER_JOB=hw5-db-check

VM=hw6-trainer
MACHINE=e2-medium
SA="hw6-trainer@${PROJECT_ID}.iam.gserviceaccount.com"

SEED="${SEED:-528}"
PRINT_ROWS="${PRINT_ROWS:-25}"
TIMEOUT_MIN="${TIMEOUT_MIN:-30}"

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
ts() { date -u '+%H:%M:%S UTC'; }

echo "==> Checking prerequisites"
command -v gcloud >/dev/null || { echo "ERROR: gcloud not found on PATH" >&2; exit 1; }
gcloud auth print-access-token >/dev/null 2>&1 || gcloud auth login

echo "==> Enabling APIs"
gc services enable compute.googleapis.com sqladmin.googleapis.com \
  secretmanager.googleapis.com storage.googleapis.com iam.googleapis.com

echo "==> Service account $SA (least privilege)"
exists gc iam service-accounts describe "$SA" ||
  gc iam service-accounts create hw6-trainer --display-name "HW6 model trainer VM"
# connect to Cloud SQL, read the DB password, write the model output
retry gc projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$SA" --role roles/cloudsql.client --condition=None
retry gc secrets add-iam-policy-binding "$DB_PASSWORD_SECRET" \
  --member "serviceAccount:$SA" --role roles/secretmanager.secretAccessor
retry gc storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$SA" --role roles/storage.objectAdmin

db_field() { gc sql instances describe "$DB_INSTANCE" --format "value($1)"; }

# Runs on every exit (success, error, Ctrl-C): VM deleted, DB stopped,
# stopper job resumed.
cleaned=0
cleanup() {
  (( cleaned )) && return 0
  cleaned=1
  set +e
  echo
  if exists gc compute instances describe "$VM" --zone "$ZONE"; then
    echo "==> Deleting VM $VM"
    gc compute instances delete "$VM" --zone "$ZONE"
  fi
  if [[ "$(db_field settings.activationPolicy)" != NEVER ]]; then
    echo "==> Stopping Cloud SQL $DB_INSTANCE"
    gc sql instances patch "$DB_INSTANCE" --activation-policy NEVER
  fi
  echo "    $DB_INSTANCE: $(db_field state) (activation policy $(db_field settings.activationPolicy))"
  if exists gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" &&
     [[ "$(gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION" --format 'value(state)')" == PAUSED ]]; then
    echo "==> Resuming scheduler job $SCHEDULER_JOB"
    gc scheduler jobs resume "$SCHEDULER_JOB" --location "$REGION" >/dev/null
  fi
  set -e
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "==> Starting Cloud SQL $DB_INSTANCE ($(ts))"
exists gc sql instances describe "$DB_INSTANCE" ||
  { echo "ERROR: $DB_INSTANCE not found (create it with hw5/setup.sh)" >&2; exit 1; }
# so the hourly stopper cannot stop the DB in the middle of the run
if exists gc scheduler jobs describe "$SCHEDULER_JOB" --location "$REGION"; then
  gc scheduler jobs pause "$SCHEDULER_JOB" --location "$REGION" >/dev/null 2>&1 || true
fi
if [[ "$(db_field settings.activationPolicy)" != ALWAYS ]]; then
  gc sql instances patch "$DB_INSTANCE" --activation-policy ALWAYS --async >/dev/null
fi
# RUNNABLE is reported before the start operation finishes, and connections
# are dropped until it does, so wait for both
for i in $(seq 90); do
  state="$(db_field state)"
  pending="$(gc sql operations list --instance "$DB_INSTANCE" --limit 5 \
             --filter 'status!=DONE' --format 'value(name)' | wc -l | tr -d ' ')"
  [[ "$state" == RUNNABLE && "$pending" == 0 ]] && break
  (( i == 90 )) && { echo "ERROR: $DB_INSTANCE did not become ready" >&2; exit 1; }
  echo "    state ${state:-unknown}, $pending operation(s) running... ($(ts))"
  sleep 10
done
INSTANCE_CONNECTION_NAME="$(db_field connectionName)"
echo "    $DB_INSTANCE is RUNNABLE ($INSTANCE_CONNECTION_NAME)"

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
  --metadata "PROJECT_ID=$PROJECT_ID,INSTANCE_CONNECTION_NAME=$INSTANCE_CONNECTION_NAME,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD_SECRET=$DB_PASSWORD_SECRET,BUCKET=$BUCKET,OUT_PREFIX=$OUT_PREFIX,SEED=$SEED" \
  --metadata-from-file "startup-script=$HERE/startup-trainer.sh,train-code=$HERE/train_models.py,migrate-code=$HERE/migrate_3nf.py,db-code=$HERE/db.py,requirements=$HERE/requirements.txt,sql-schema-3nf=$HERE/sql/schema_3nf.sql,sql-precheck-3nf=$HERE/sql/precheck_3nf.sql,sql-migrate-3nf=$HERE/sql/migrate_3nf.sql,sql-verify-3nf=$HERE/sql/verify_3nf.sql"

echo "==> Waiting for the VM to install packages, migrate and train (up to ${TIMEOUT_MIN} min)"
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

# done with the cloud resources: stop the DB and delete the VM before printing
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
