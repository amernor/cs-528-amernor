#!/usr/bin/env bash
# Deletes everything deploy.sh created (VMs, static IP, firewall rule, ...)
# so nothing keeps billing after the homework is done.
#
# Usage: PROJECT_ID=<your-project> ./teardown.sh
set -euo pipefail

# TODO
