#!/usr/bin/env bash
# Controls the hourly job that stops the database (Cloud Scheduler hw5-db-check
# -> Cloud Function hw5-db-stopper).
#
# Usage: tools/scheduler.sh pause    # while actively using the DB
#        tools/scheduler.sh resume   # when done (cleanup.sh also does this)
#        tools/scheduler.sh run      # trigger it now (works even when paused)
#        tools/scheduler.sh status   # job state + DB state
set -euo pipefail

PROJECT_ID="superb-heaven-507521-u2"
REGION=us-central1
JOB=hw5-db-check
DB_INSTANCE=hw5-db

gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }

case "${1:-}" in
  pause|resume|run) gc scheduler jobs "$1" "$JOB" --location "$REGION" ;;
  status) ;;
  *)
    echo "usage: $0 pause|resume|run|status" >&2
    exit 1
    ;;
esac
echo "job $JOB: $(gc scheduler jobs describe "$JOB" --location "$REGION" \
  --format 'value(state,schedule,lastAttemptTime)')"
echo "db  $DB_INSTANCE: $(gc sql instances describe "$DB_INSTANCE" \
  --format 'value(settings.activationPolicy,state)')"
