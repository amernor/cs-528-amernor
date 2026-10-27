#!/usr/bin/env bash
# Keeps internet scanners out of the tables during the curl demo and the load
# test by limiting the web server's port to this machine and the client VM.
#
# Usage: tools/firewall.sh lock     # allow only this machine's public IP + hw5-client
#        tools/firewall.sh open     # allow everyone again (what setup.sh creates)
#        tools/firewall.sh status
# setup.sh only creates the rule when it is missing, so re-running it keeps a
# lock; cleanup.sh deletes the rule, so a fresh setup.sh starts open.
set -euo pipefail

PROJECT_ID="superb-heaven-507521-u2"
ZONE=us-central1-a
RULE=hw5-allow-web
CLIENT_VM=hw5-client

gc() { gcloud --project "$PROJECT_ID" --quiet "$@"; }

case "${1:-}" in
  lock)
    my_ip="$(curl -s -m 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
    client_ip="$(gc compute instances describe "$CLIENT_VM" --zone "$ZONE" \
      --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')"
    [[ -n "$my_ip" && -n "$client_ip" ]] ||
      { echo "could not determine this machine's IP ($my_ip) or $CLIENT_VM's IP ($client_ip)" >&2; exit 1; }
    gc compute firewall-rules update "$RULE" --source-ranges "$my_ip/32,$client_ip/32"
    ;;
  open)
    gc compute firewall-rules update "$RULE" --source-ranges 0.0.0.0/0
    ;;
  status) ;;
  *)
    echo "usage: $0 lock|open|status" >&2
    exit 1
    ;;
esac
echo "$RULE allows: $(gc compute firewall-rules describe "$RULE" --format 'value(sourceRanges.list())')"
