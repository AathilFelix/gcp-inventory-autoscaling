#!/usr/bin/env bash
# Provisions the whole stack on Google Cloud. Safe to re-run: every create is guarded.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh
G="gcloud --project=${PROJECT_ID} --quiet"

step() { printf '\n==> %s\n' "$*"; }
exists() { "$@" >/dev/null 2>&1; }

step "Firestore database (${REGION})"
exists $G firestore databases describe || $G firestore databases create --location="${REGION}" --type=firestore-native

step "Service account for the VMs (least privilege)"
exists $G iam service-accounts describe "${SA_EMAIL}" || $G iam service-accounts create "${SA_NAME}" --display-name="Inventory VM"
for role in roles/datastore.user roles/logging.logWriter roles/monitoring.metricWriter; do
  # IAM read-modify-write can conflict right after the service account is created; retry with backoff.
  for attempt in 1 2 3 4 5; do
    $G projects add-iam-policy-binding "${PROJECT_ID}" --member="serviceAccount:${SA_EMAIL}" --role="${role}" --condition=None >/dev/null && break
    sleep $((attempt * 3))
  done
done

step "Cloud Storage bucket for the app bundle"
exists $G storage buckets describe "gs://${BUCKET}" || $G storage buckets create "gs://${BUCKET}" --location="${REGION}" --uniform-bucket-level-access
$G storage buckets add-iam-policy-binding "gs://${BUCKET}" --member="serviceAccount:${SA_EMAIL}" --role=roles/storage.objectViewer >/dev/null
tar -czf /tmp/app.tar.gz -C ../app --exclude='__pycache__' .
$G storage cp /tmp/app.tar.gz "gs://${BUCKET}/app.tar.gz"

step "Firewall: health checks + load balancer reach the app, SSH only through IAP"
exists $G compute firewall-rules describe allow-lb-to-inventory || $G compute firewall-rules create allow-lb-to-inventory \
  --network="${NETWORK}" --direction=INGRESS --action=allow --rules="tcp:${APP_PORT}" \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 --target-tags="${NETWORK_TAG}"
exists $G compute firewall-rules describe allow-iap-ssh || $G compute firewall-rules create allow-iap-ssh \
  --network="${NETWORK}" --direction=INGRESS --action=allow --rules=tcp:22 --source-ranges=35.235.240.0/20
exists $G compute firewall-rules describe default-allow-ssh && $G compute firewall-rules delete default-allow-ssh || true
exists $G compute firewall-rules describe default-allow-rdp && $G compute firewall-rules delete default-allow-rdp || true

step "Instance template"
exists $G compute instance-templates describe "${TEMPLATE}" || $G compute instance-templates create "${TEMPLATE}" \
  --machine-type="${MACHINE_TYPE}" --image-family=debian-12 --image-project=debian-cloud \
  --boot-disk-size=10GB --boot-disk-type=pd-balanced \
  --network="${NETWORK}" --tags="${NETWORK_TAG}" \
  --service-account="${SA_EMAIL}" --scopes=cloud-platform \
  --metadata=app-bucket="${BUCKET}" --metadata-from-file=startup-script=startup.sh \
  --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring

step "Health check"
exists $G compute health-checks describe "${HEALTH_CHECK}" || $G compute health-checks create http "${HEALTH_CHECK}" \
  --port="${APP_PORT}" --request-path=/healthz --check-interval=10s --timeout=5s \
  --healthy-threshold=2 --unhealthy-threshold=3

step "Regional managed instance group (spread over zones)"
exists $G compute instance-groups managed describe "${MIG}" --region="${REGION}" || $G compute instance-groups managed create "${MIG}" \
  --region="${REGION}" --template="${TEMPLATE}" --size="${MIN_REPLICAS}" \
  --health-check="${HEALTH_CHECK}" --initial-delay=180
$G compute instance-groups managed set-named-ports "${MIG}" --region="${REGION}" --named-ports="http:${APP_PORT}"

step "Autoscaler: target ${CPU_TARGET} CPU, ${MIN_REPLICAS}-${MAX_REPLICAS} instances"
$G compute instance-groups managed set-autoscaling "${MIG}" --region="${REGION}" \
  --min-num-replicas="${MIN_REPLICAS}" --max-num-replicas="${MAX_REPLICAS}" \
  --target-cpu-utilization="${CPU_TARGET}" --cool-down-period="${COOL_DOWN}" \
  --scale-in-control=max-scaled-in-replicas=1,time-window=120

step "Global external HTTP load balancer"
exists $G compute addresses describe "${LB_IP_NAME}" --global || $G compute addresses create "${LB_IP_NAME}" --global --ip-version=IPV4
exists $G compute backend-services describe "${BACKEND}" --global || $G compute backend-services create "${BACKEND}" \
  --global --protocol=HTTP --port-name=http --health-checks="${HEALTH_CHECK}" --timeout=30s \
  --load-balancing-scheme=EXTERNAL_MANAGED
$G compute backend-services add-backend "${BACKEND}" --global \
  --instance-group="${MIG}" --instance-group-region="${REGION}" \
  --balancing-mode=UTILIZATION --max-utilization=0.8 2>/dev/null || true
exists $G compute url-maps describe "${URL_MAP}" || $G compute url-maps create "${URL_MAP}" --default-service="${BACKEND}"
exists $G compute target-http-proxies describe "${PROXY}" || $G compute target-http-proxies create "${PROXY}" --url-map="${URL_MAP}"
exists $G compute forwarding-rules describe "${FWD_RULE}" --global || $G compute forwarding-rules create "${FWD_RULE}" \
  --global --address="${LB_IP_NAME}" --target-http-proxy="${PROXY}" --ports=80 --load-balancing-scheme=EXTERNAL_MANAGED

IP="$($G compute addresses describe "${LB_IP_NAME}" --global --format='value(address)')"
step "Done. Instances take ~3 minutes to boot and pass health checks."
echo "App URL: http://${IP}/"
