#!/usr/bin/env bash
# Runs the full stress test: 1, 2, 3, then 4 concurrent clients, with an idle
# gap between levels so each one shows up separately in the metrics.
#
# Usage: ./run-all.sh <server-ip>
# Env:   NUM_REQUESTS per client (default 2500, ~3+ min per level)
#        GAP seconds of idle time between levels (default 120)
#        plus anything run-clients.sh accepts (CLIENT, PORT)
set -euo pipefail

IP="${1:?usage: $0 <server-ip>}"
export NUM_REQUESTS="${NUM_REQUESTS:-2500}"
GAP="${GAP:-120}"
HERE="$(cd "$(dirname "$0")" && pwd)"

for n in 1 2 3 4; do
  "$HERE/run-clients.sh" "$IP" "$n" -b none -w pages -i 11999
  if (( n < 4 )); then
    echo
    echo "Idle for ${GAP}s before the next level..."
    sleep "$GAP"
  fi
done

echo
echo "All levels done. Summaries: results/*/summary.txt"
