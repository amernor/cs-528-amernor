#!/usr/bin/env bash
# Guided curl demo (assignment step 4): shows both tables, then one successful
# and two failing requests, showing the tables after each one. Pauses between
# steps so each can be screenshotted (report/screenshots/demo-1..7.png).
#
# Run it on EMPTY tables, before the load test:
#   hw5/.venv/bin/python hw5/tools/reset_tables.py
#   hw5/tools/curl-demo.sh [server-ip] [existing-file]
# The IP defaults to the hw5-web-ip static address; the file to pages/1.html.
set -euo pipefail

PROJECT_ID="superb-heaven-507521-u2"
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/../.venv/bin/python"
IP="${1:-$(gcloud --project "$PROJECT_ID" compute addresses describe hw5-web-ip \
  --region us-central1 --format 'value(address)')}"
FILE="${2:-pages/1.html}"
URL="http://$IP:8080"

# same header names and value formats the provided client sends
HEADERS=(-H "X-country: France" -H "X-client-IP: 81.57.12.200" -H "X-gender: Female"
         -H "X-age: 26-35" -H "X-income: 60k-100k" -H "X-time: $(date -u '+%Y-%m-%d %H:00:00')")

pause() { echo; read -r -p "--- Screenshot, then press Enter ---"; echo; }
show() { "$PY" "$HERE/show_tables.py"; }
banner() { echo; echo "=================== $* ==================="; }
run_curl() {
  echo "\$ curl -i -s $*"
  # body is cut to keep the screenshot readable (|| true: head closes the pipe early)
  curl -i -s "$@" | head -c 600 | sed -e 's/\r$//' || true
  echo
}

banner "Tables before request 1"
show
pause

banner "Request 1 of 3: existing file -> 200"
run_curl "${HEADERS[@]}" "$URL/$FILE"
show
pause

banner "Request 2 of 3: missing file -> 404"
run_curl "${HEADERS[@]}" "$URL/does-not-exist.html"
show
pause

banner "Request 3 of 3: PUT (method not implemented) -> 501"
run_curl -X PUT "${HEADERS[@]}" "$URL/$FILE"
show
echo
echo "Demo done."
