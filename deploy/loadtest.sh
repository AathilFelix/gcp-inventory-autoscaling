#!/usr/bin/env bash
# Drives CPU load through the load balancer so the autoscaler adds instances.
# usage: ./loadtest.sh [duration_seconds] [parallel_clients]
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

DURATION="${1:-420}"
CLIENTS="${2:-24}"
IP="$(gcloud --project="${PROJECT_ID}" compute addresses describe "${LB_IP_NAME}" --global --format='value(address)')"
echo "Load test against http://${IP}/ for ${DURATION}s with ${CLIENTS} clients"

end=$(( $(date +%s) + DURATION ))
worker() { while [ "$(date +%s)" -lt "$end" ]; do curl -s -o /dev/null --max-time 10 "http://${IP}/api/burn?ms=1500" || true; done; }
for _ in $(seq "${CLIENTS}"); do worker & done

while [ "$(date +%s)" -lt "$end" ]; do
  printf '%s  instances=%s\n' "$(date +%H:%M:%S)" \
    "$(gcloud --project="${PROJECT_ID}" compute instance-groups managed list-instances "${MIG}" --region="${REGION}" --format='value(name)' | wc -l | tr -d ' ')"
  sleep 20
done
wait
echo "Load test finished. Instances scale back in after the cool-down."
