#!/usr/bin/env bash
# One command to bring the whole system up for a demo, and one to remove everything that costs money.
#
#   ./deploy/demo.sh up        create project (if missing), deploy everything, seed data, print the URL
#   ./deploy/demo.sh down      delete every billable resource (asks first; add --yes to skip the question)
#   ./deploy/demo.sh status    show what is currently running
#
# Needs: gcloud logged in, and a billing account the account can use (the first open one is picked unless
# BILLING_ACCOUNT is set). Takes about 10 minutes for "up": ~5 to build, ~5 for the load balancer to settle.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh
G="gcloud --project=${PROJECT_ID} --quiet"

lb_ip() { $G compute addresses describe "${LB_IP_NAME}" --global --format='value(address)' 2>/dev/null || true; }

up() {
  if ! gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
    echo "==> Creating project ${PROJECT_ID}"
    gcloud projects create "${PROJECT_ID}" --name="Inventory Autoscaling" --quiet
  fi
  BILLING="${BILLING_ACCOUNT:-$(gcloud billing accounts list --filter=open=true --format='value(name)' | head -1)}"
  [ -n "${BILLING}" ] || { echo "No open billing account found. Set BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX"; exit 1; }
  echo "==> Linking billing account ${BILLING##*/} and enabling APIs"
  gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING##*/}" --quiet >/dev/null
  $G services enable compute.googleapis.com firestore.googleapis.com storage.googleapis.com \
    monitoring.googleapis.com logging.googleapis.com

  ./deploy.sh

  IP="$(lb_ip)"
  echo "==> Waiting for the load balancer to serve consistently (15 good responses in a row; usually 3 to 6 minutes)"
  ok=0
  for _ in $(seq 1 180); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://${IP}/healthz")" = 200 ]; then ok=$((ok + 1)); else ok=0; fi
    [ "${ok}" -ge 15 ] && break
    sleep 4
  done
  [ "${ok}" -ge 15 ] || { echo "Timed out waiting for http://${IP}/ - check './demo.sh status'"; exit 1; }

  ./seed.sh
  echo
  echo "READY: http://${IP}/"
  echo "Load test: ./deploy/loadtest.sh 540 24      Tear down: ./deploy/demo.sh down"
}

down() {
  if [ "${1:-}" != "--yes" ]; then
    read -r -p "Delete the load balancer, VMs, bucket, firewall rules and all Firestore data in ${PROJECT_ID}? [y/N] " a
    [[ "${a}" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
  fi
  ./teardown.sh
  echo "Everything billable is deleted. './demo.sh up' brings it all back."
}

status() {
  echo "Project: ${PROJECT_ID}"
  $G compute instance-groups managed list --format='table(name,location,size,targetSize)' 2>/dev/null || true
  $G compute instances list --format='table(name,zone.basename(),status)' 2>/dev/null || true
  IP="$(lb_ip)"
  [ -n "${IP}" ] && echo "Load balancer: http://${IP}/" || echo "Load balancer: not deployed"
}

case "${1:-}" in
  up) up ;;
  down) down "${2:-}" ;;
  status) status ;;
  *) echo "usage: $0 up | down [--yes] | status"; exit 2 ;;
esac
