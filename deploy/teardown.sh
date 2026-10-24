#!/usr/bin/env bash
# Removes every billable resource the deploy script created, plus the Firestore data, so nothing is left running.
# The empty Firestore database itself stays (it costs nothing when idle and cannot be quickly recreated in the
# same location). Each step is independent, so re-running after a partial failure is safe.
set -uo pipefail
cd "$(dirname "$0")"
source ./config.sh
G="gcloud --project=${PROJECT_ID} --quiet"

$G compute forwarding-rules delete "${FWD_RULE}" --global
$G compute target-http-proxies delete "${PROXY}"
$G compute url-maps delete "${URL_MAP}"
$G compute backend-services delete "${BACKEND}" --global
$G compute instance-groups managed delete "${MIG}" --region="${REGION}"
$G compute instance-templates delete "${TEMPLATE}"
$G compute health-checks delete "${HEALTH_CHECK}"
$G compute addresses delete "${LB_IP_NAME}" --global
$G compute firewall-rules delete allow-lb-to-inventory allow-iap-ssh
$G storage rm -r "gs://${BUCKET}"
$G firestore bulk-delete --collection-ids=products,movements
exit 0
