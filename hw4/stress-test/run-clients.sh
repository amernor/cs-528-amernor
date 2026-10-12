#!/usr/bin/env bash
# Runs N concurrent copies of the http client against the web server
# (N must be 1-4) and saves each client's output for the report.
#
# Usage: ./run-clients.sh <server-ip> <num-clients>
set -euo pipefail

# TODO
