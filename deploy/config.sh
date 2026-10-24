#!/usr/bin/env bash
# Shared settings for every deploy script. Override any value from the environment.
export PROJECT_ID="${PROJECT_ID:-inventory-gce-24cs010}"
export REGION="${REGION:-asia-south1}"
export NETWORK="${NETWORK:-default}"

export BUCKET="${BUCKET:-${PROJECT_ID}-app-artifacts}"
export SA_NAME="inventory-vm"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

export TEMPLATE="inventory-template-v1"
export MIG="inventory-mig"
export HEALTH_CHECK="inventory-hc"
export BACKEND="inventory-backend"
export URL_MAP="inventory-urlmap"
export PROXY="inventory-proxy"
export FWD_RULE="inventory-fwd"
export LB_IP_NAME="inventory-lb-ip"
export NETWORK_TAG="inventory-app"

export MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
export MIN_REPLICAS="${MIN_REPLICAS:-2}"
export MAX_REPLICAS="${MAX_REPLICAS:-4}"
export CPU_TARGET="${CPU_TARGET:-0.60}"
export COOL_DOWN="${COOL_DOWN:-180}"
export APP_PORT=8080
