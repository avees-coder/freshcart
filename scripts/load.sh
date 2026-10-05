#!/usr/bin/env bash
# Generate CPU load on the API through the storefront, to drive the HPA demo.
# Usage: scripts/load.sh http://<node-public-ip>:30080 [seconds] [parallel]
set -euo pipefail
URL="${1:?usage: load.sh http://host:port [seconds] [parallel]}"
SECS="${2:-180}"; PAR="${3:-20}"
END=$(( $(date +%s) + SECS ))
echo "load: ${PAR} parallel clients for ${SECS}s against ${URL}/api/chaos/burn"
worker() { while [ "$(date +%s)" -lt "$END" ]; do curl -s -o /dev/null "${URL}/api/chaos/burn?ms=150" || true; done; }
for _ in $(seq "$PAR"); do worker & done
wait
echo "load finished"
