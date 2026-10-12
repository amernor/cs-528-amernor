#!/usr/bin/env bash
# One-command setup for HW4: service accounts + IAM, static IP, firewall rule,
# Pub/Sub topic/subscription, then the service1 (web server) and service2 VMs
# with their startup scripts.
#
# Usage: PROJECT_ID=<your-project> ./deploy.sh
set -euo pipefail

# TODO
