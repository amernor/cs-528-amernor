#!/usr/bin/env bash
# Runs N concurrent copies of the http client against the web server
# (N must be 1-4), prints live progress every 10s, and saves each client's
# output plus a summary for the report.
#
# Usage: ./run-clients.sh <server-ip> <num-clients> [extra http-client args...]
#   e.g. NUM_REQUESTS=1500 ./run-clients.sh 34.1.2.3 4 -b none -w pages -i 11999
#
# Env: CLIENT        path to the http client (default ./http-client-linux)
#      PORT          server port (default 8080)
#      NUM_REQUESTS  requests per client (default 100); raise it so a run
#                    lasts at least 3 minutes when measuring resource usage
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <server-ip> <num-clients> [extra http-client args...]" >&2
  exit 1
fi
IP="$1"
N="$2"
shift 2
if (( N < 1 || N > 4 )); then
  echo "num-clients must be between 1 and 4" >&2
  exit 1
fi

CLIENT="${CLIENT:-./http-client-linux}"
PORT="${PORT:-8080}"
NUM_REQUESTS="${NUM_REQUESTS:-100}"
OUT_DIR="results/${N}-clients-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

# The client only prints responses with -v; keep the request/status lines
# and anything error-like, drop headers and file bodies.
KEEP='^(Requesting|[0-9]{3} )|[Tt]imeout|[Ee]rror|[Rr]efused|[Rr]eset|Exception'
# a request counts as finished once it has a status line or a timeout
DONE='^[0-9]{3} |[Tt]imeout'
# anything that isn't a request line, 200 OK or 400 (permission denied)
ERRORS='^(Requesting|200 |400 )'

count() { grep -cE "$1" "$2" || true; }
count_errors() { grep -cvE "$ERRORS" "$1" || true; }

stamp() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
START_STAMP="$(stamp)"
echo "[$START_STAMP] Starting $N client(s), $NUM_REQUESTS requests each -> $OUT_DIR"
start=$(date +%s)
pids=()
for i in $(seq 1 "$N"); do
  # different seed per client so they don't all request the same files
  ( "$CLIENT" -d "$IP" -p "$PORT" -n "$NUM_REQUESTS" -r "$i" -v "$@" 2>&1 \
      | grep --line-buffered -E "$KEEP" ) > "$OUT_DIR/client-$i.log" &
  pids+=("$!")
done

running() {
  for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && return 0; done
  return 1
}

progress() {
  local line="[$(( $(date +%s) - start ))s]"
  for i in $(seq 1 "$N"); do
    local log="$OUT_DIR/client-$i.log"
    line+="  client$i: $(count "$DONE" "$log")/$NUM_REQUESTS done, $(count_errors "$log") err"
  done
  echo "$line"
}

while running; do
  sleep 10
  progress
done
wait || true
END_STAMP="$(stamp)"
elapsed=$(( $(date +%s) - start ))

{
  echo
  echo "===== Summary: $N client(s) x $NUM_REQUESTS requests ====="
  echo "Start:   $START_STAMP"
  echo "End:     $END_STAMP"
  echo "Elapsed: ${elapsed}s"
  total=0
  errors=0
  for i in $(seq 1 "$N"); do
    log="$OUT_DIR/client-$i.log"
    echo "client $i:"
    { grep -oE '^[0-9]{3} [A-Za-z ]*' "$log" || true; } | sort | uniq -c | sed 's/^/   /'
    timeouts=$(count '[Tt]imeout' "$log")
    (( timeouts > 0 )) && echo "   $timeouts timeouts"
    total=$(( total + $(count "$DONE" "$log") ))
    errors=$(( errors + $(count_errors "$log") ))
  done
  echo "Total requests finished: $total"
  echo "Errors (excluding 400s): $errors"
  echo "Throughput: $(( total / (elapsed > 0 ? elapsed : 1) )) req/s"
} | tee "$OUT_DIR/summary.txt"
