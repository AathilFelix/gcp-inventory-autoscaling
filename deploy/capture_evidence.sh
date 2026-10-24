#!/usr/bin/env bash
# Dumps the state of every resource to docs/evidence/<label>.txt (used for the report annexure).
# usage: ./capture_evidence.sh <label>
set -uo pipefail
cd "$(dirname "$0")"
source ./config.sh
LABEL="${1:-snapshot}"
OUT="../docs/evidence/${LABEL}.txt"
mkdir -p ../docs/evidence
G="gcloud --project=${PROJECT_ID}"

{
  echo "# Captured $(date -u +%Y-%m-%dT%H:%M:%SZ)  project=${PROJECT_ID}  region=${REGION}"
  echo; echo "## Managed instance group"
  $G compute instance-groups managed list --format="table(name,location,baseInstanceName,size,targetSize,instanceTemplate.basename())"
  $G compute instance-groups managed list-instances "${MIG}" --region="${REGION}"
  echo; echo "## Autoscaler policy"
  curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "https://compute.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${REGION}/autoscalers" |
    python3 -c "import sys,json
for a in json.load(sys.stdin).get('items',[]):
    p=a['autoscalingPolicy']
    print('name:', a['name'], ' status:', a['status'])
    print('min/max replicas:', p['minNumReplicas'], '/', p['maxNumReplicas'])
    print('cpu target:', p['cpuUtilization']['utilizationTarget'], ' cool-down(s):', p['coolDownPeriodSec'])
    print('scale-in control:', p.get('scaleInControl'))"
  echo; echo "## Load balancer backend health"
  $G compute backend-services get-health "${BACKEND}" --global --format="json" |
    python3 -c "import sys,json
for g in json.load(sys.stdin):
    for h in g.get('status',{}).get('healthStatus',[]):
        print(h['instance'].split('/')[-1], h['healthState'])"
  echo; echo "## Instances (zone, type, internal/external IP)"
  $G compute instances list --filter="name~^${MIG}" --format="table(name,zone.basename(),machineType.basename(),status,networkInterfaces[0].networkIP:label=INTERNAL_IP,networkInterfaces[0].accessConfigs[0].natIP:label=EXTERNAL_IP)"
  echo; echo "## Load balancer"
  $G compute forwarding-rules list --format="table(name,IPAddress,target.basename(),portRange,loadBalancingScheme)"
  $G compute backend-services list --format="table(name,protocol,loadBalancingScheme,healthChecks[0].basename():label=HEALTH_CHECK)"
  $G compute url-maps list
  echo; echo "## Firewall rules"
  $G compute firewall-rules list --format="table(name,direction,sourceRanges.list():label=SOURCES,allowed[].map().firewall_rule().list():label=ALLOW,targetTags.list())"
  echo; echo "## Service account and roles"
  $G projects get-iam-policy "${PROJECT_ID}" --flatten="bindings[].members" --filter="bindings.members:${SA_EMAIL}" --format="table(bindings.role)"
  echo; echo "## Firestore"
  $G firestore databases describe --format="yaml(name,locationId,type,freeTier)"
  echo; echo "## Cloud Storage"
  $G storage ls -l "gs://${BUCKET}/"
} >"${OUT}" 2>&1
echo "wrote ${OUT}"
