#!/usr/bin/env bash
# Controls the hourly job that stops the database (Cloud Scheduler hw5-db-check
# -> Cloud Function hw5-db-stopper).
#
# Usage: tools/scheduler.sh pause    # while actively using the DB
#        tools/scheduler.sh resume   # when done (cleanup.sh also does this)
#        tools/scheduler.sh run      # trigger it now (a paused job is resumed, run, re-paused)
#        tools/scheduler.sh status   # job state + DB state
set -euo pipefail

PROJECT_ID="superb-heaven-507521-u2"
REGION=us-central1
JOB=hw5-db-check
DB_INSTANCE=hw5-db

gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }

case "${1:-}" in
  pause|resume) gc scheduler jobs "$1" "$JOB" --location "$REGION" ;;
  run)
    # a paused job cannot be run, so resume it briefly and pause it again
    was="$(gc scheduler jobs describe "$JOB" --location "$REGION" --format 'value(state)')"
    [[ "$was" == PAUSED ]] && gc scheduler jobs resume "$JOB" --location "$REGION"
    gc scheduler jobs run "$JOB" --location "$REGION"
    [[ "$was" == PAUSED ]] && gc scheduler jobs pause "$JOB" --location "$REGION"
    ;;
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
