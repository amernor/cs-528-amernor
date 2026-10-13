#!/usr/bin/env bash
# Runs N concurrent copies of the http client against the web server
# (N must be 1-4) and saves each client's output for the report.
#
# Usage: ./run-clients.sh <server-ip> <num-clients> [extra http-client args...]
#   e.g. NUM_REQUESTS=5000 ./run-clients.sh 34.1.2.3 4 -b cs528-amernor -w none -i 9999
#
# Env: CLIENT        path to the http client (default ./http-client)
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

CLIENT="${CLIENT:-./http-client}"
PORT="${PORT:-8080}"
NUM_REQUESTS="${NUM_REQUESTS:-100}"
OUT_DIR="results/${N}-clients-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

echo "Starting $N client(s), $NUM_REQUESTS requests each -> $OUT_DIR"
start=$(date +%s)
pids=()
for i in $(seq 1 "$N"); do
  # different seed per client so they don't all request the same files
  "$CLIENT" -d "$IP" -p "$PORT" -n "$NUM_REQUESTS" -r "$i" "$@" \
    > "$OUT_DIR/client-$i.log" 2>&1 &
  pids+=("$!")
done

for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    echo "client $((i + 1)) exited with an error (see $OUT_DIR/client-$((i + 1)).log)"
  fi
done
echo "Done in $(( $(date +%s) - start ))s"
