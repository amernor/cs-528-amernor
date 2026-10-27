#!/usr/bin/env bash
# Load test (assignment step 5): runs 2 concurrent copies of the provided http
# client against the web server, BOTH WITH THE SAME RANDOM SEED, prints live
# progress every 10s, and saves each client's output plus a summary.
#
# Runs on the hw5-client VM, inside tmux so an ssh drop does not kill it:
#   gcloud compute scp <http-client-linux> hw5/tools/run-load-test.sh hw5-client:~ --zone us-central1-a
#   gcloud compute ssh hw5-client --zone us-central1-a
#   tmux new -s load
#   ./run-load-test.sh <server-ip> [seed=528] [requests-per-client=50000]
#
# Env: CLIENT   path to the http client (default ./http-client-linux)
#      PORT     server port (default 8080)
#      TIMEOUT  per-request timeout in seconds passed to -t (default 30)
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <server-ip> [seed=528] [requests-per-client=50000]" >&2
  exit 1
fi
IP="$1"
SEED="${2:-528}"
NUM_REQUESTS="${3:-50000}"
N=2
CLIENT="${CLIENT:-./http-client-linux}"
PORT="${PORT:-8080}"
TIMEOUT="${TIMEOUT:-30}"

[[ -x "$CLIENT" ]] || { echo "client $CLIENT not found or not executable (chmod +x it)" >&2; exit 1; }
[[ -n "${TMUX:-}" ]] || echo "WARNING: not inside tmux; an ssh drop will kill the test (tmux new -s load)"

OUT_DIR="results/load-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

# The client only prints responses with -v; keep the request/status lines
# and anything error-like, drop headers and file bodies.
KEEP='^(Requesting|[0-9]{3} )|[Tt]imeout|[Ee]rror|[Rr]efused|[Rr]eset|Exception'
# a request counts as finished once it has a status line or a timeout
DONE='^[0-9]{3} |[Tt]imeout'
# anything that isn't a request line, 200 OK, 400 (banned) or 404 (missing file)
ERRORS='^(Requesting|200 |400 |404 )'

count() { grep -cE "$1" "$2" || true; }
count_errors() { grep -cvE "$ERRORS" "$1" || true; }

stamp() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
START_STAMP="$(stamp)"
CMD=("$CLIENT" -d "$IP" -p "$PORT" -n "$NUM_REQUESTS" -r "$SEED" -b none -w pages -i 11999 -t "$TIMEOUT" -v)
echo "[$START_STAMP] Starting $N clients, $NUM_REQUESTS requests each, seed $SEED -> $OUT_DIR"
echo "  command (both clients): ${CMD[*]}"
start=$(date +%s)
pids=()
for i in $(seq 1 "$N"); do
  # same seed for every client (assignment requirement)
  ( "${CMD[@]}" 2>&1 | grep --line-buffered -E "$KEEP" ) > "$OUT_DIR/client-$i.log" &
  pids+=("$!")
done

running() {
  for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && return 0; done
  return 1
}

progress() {
  local now line
  now=$(( $(date +%s) - start ))
  line="[${now}s]"
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
  echo "===== Summary: $N clients x $NUM_REQUESTS requests, seed $SEED ====="
  echo "Command: ${CMD[*]}"
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
  echo "Unexpected responses (not 200/400/404): $errors"
  echo "Throughput: $(( total / (elapsed > 0 ? elapsed : 1) )) req/s"
} | tee "$OUT_DIR/summary.txt"
