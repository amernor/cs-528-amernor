#!/usr/bin/env bash
# Settings shared by run.sh and cleanup.sh (sourced, not run).

PROJECT_ID="superb-heaven-507521-u2"   # hardcoded on purpose (grading rule)
REGION=us-central1
ZONE=us-central1-a

BUCKET=cs528-amernor
OUT_PREFIX=hw6          # model output, cleared at the start of every run
DATA_PREFIX=hw6-data    # snapshot of the HW5 tables (ensure_data.py)

DB_INSTANCE=hw5-db
DB_NAME="${DB_NAME:-hw5}"   # override only to test a run against an empty database
DB_USER=webapp
DB_PASSWORD_SECRET=hw5-db-password
SCHEDULER_JOB=hw5-db-check  # HW5 hourly DB stopper (paused during the run if present)

VM=hw6-trainer
MACHINE=e2-medium
SA_NAME=hw6-trainer
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }
exists() { "$@" >/dev/null 2>&1; }
ts() { date -u '+%H:%M:%S UTC'; }
db_field() { gc sql instances describe "$DB_INSTANCE" --format "value($1)"; }
