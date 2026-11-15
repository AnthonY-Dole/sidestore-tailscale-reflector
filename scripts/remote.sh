#!/bin/sh
# Runs a local script on the router: scripts/remote.sh <file.sh>
# The script is piped over stdin, so PowerShell quoting never gets involved.
set -eu
HOST=${HOST:-slate7}
[ $# -eq 1 ] || { echo "usage: $0 <script.sh>" >&2; exit 2; }
ssh "$HOST" 'sh -s' < "$1"
