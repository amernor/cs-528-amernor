#!/usr/bin/env bash
# Demo for the assignment: requests 100 files with the http client and prints
# one line per request (file -> status) plus a status summary. Output is also
# saved to run100.txt.
#
# Usage: ./demo-100.sh <server-ip>
# Env:   CLIENT (default ./http-client-linux), PORT (default 8080)
set -euo pipefail

IP="${1:?usage: $0 <server-ip>}"
CLIENT="${CLIENT:-./http-client-linux}"
PORT="${PORT:-8080}"

PYTHONUNBUFFERED=1 "$CLIENT" -d "$IP" -p "$PORT" -b none -w pages -i 11999 -n 100 -v |
  awk '
    /^Requesting/ { file = $2 }
    /^[0-9][0-9][0-9] / {
      n++
      print n ". " file " -> " $0
      fflush()
      count[$0]++
    }
    END {
      print "\nTotal requests: " n
      for (s in count) print "  " count[s] " x " s
    }
  ' | tee run100.txt
