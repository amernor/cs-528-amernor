#!/usr/bin/env bash
# Startup script for the client VM: installs what the load test needs. Runs
# as root, once (later boots skip it).
#
# The Linux http client is copied over by hand, then the test is run in tmux:
#   gcloud compute scp <http-client-linux> tools/run-load-test.sh hw5-client:~ --zone us-central1-a
if [ -f /var/log/startup_already_done ]; then
    echo "Startup script already ran once. Skipping."
    exit 0
fi
set -euo pipefail

apt-get update
apt-get install -y python3 python3-pip python3-venv python3-requests curl tmux

touch /var/log/startup_already_done
