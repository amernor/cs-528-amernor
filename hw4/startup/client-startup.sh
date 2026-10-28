#!/usr/bin/env bash
# Startup script for the client VM: installs what the provided http client
# needs so it can be run against the web server's static IP.
#
# The client itself is copied over by hand (it must be a Linux build, the
# macOS binary will not run here):
#   gcloud compute scp <client> stress-test/run-clients.sh hw4-client:~ --zone <zone>
set -euo pipefail

apt-get update
apt-get install -y python3 python3-pip python3-venv python3-requests curl
