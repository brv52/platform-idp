#!/usr/bin/env bash
# Runs bench/admission-k6.js against the cluster's API server.
#
# Creates namespace bench-admission (labelled as a tenant, so all admission
# policies apply), a ServiceAccount that may only create pods there and a
# one-hour token. Records the Kyverno admission replica layout next to the
# k6 results.
#
# Output: $BENCH_OUT/admission-k6.json (OUT_NAME overrides the file name)
# Usage:  VUS=500 HOLD=60s bench/admission.sh
#         SWEEP="50 100 200 500" bench/admission.sh   one run per VU level,
#                                  written to admission-k6-vus<N>.json
set -euo pipefail
# shellcheck source=bench/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl jq k6

if [[ -n "${SWEEP:-}" ]]; then
  for v in ${SWEEP}; do
    VUS="$v" OUT_NAME="admission-k6-vus${v}" SWEEP="" "$0" || true
    sleep 20
  done
  exit 0
fi

NS="bench-admission"
OUT_NAME="${OUT_NAME:-admission-k6}"
IMAGE="${SIGNED_IMAGE:-$(kubectl kustomize "${BENCH_ROOT}/gitops/tenants/demo-api" | awk '/image: ghcr.io/ {print $2; exit}')}"

k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    platform-idp/tenant: "true"
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: k6, namespace: ${NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: pod-creator, namespace: ${NS} }
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: k6-pod-creator, namespace: ${NS} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: pod-creator }
subjects:
  - { kind: ServiceAccount, name: k6, namespace: ${NS} }
YAML

API_URL=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')
TOKEN=$(k -n "$NS" create token k6 --duration 1h)
kyverno=$(k -n kyverno get pods -l app.kubernetes.io/component=admission-controller -o json |
  jq '[.items[] | select(.status.phase == "Running") | {pod: .metadata.name, node: .spec.nodeName}]')
log "admission load: ${VUS:-500} VUs against ${API_URL}, $(jq length <<<"$kyverno") Kyverno admission replicas"

# Warm Kyverno's image verification cache once so the run measures steady
# state, the way a cluster admitting the same release repeatedly behaves.
k -n "$NS" create --dry-run=server -o name -f - >/dev/null <<<"$(jq -n --arg img "$IMAGE" --arg ns "$NS" '{
  apiVersion: "v1", kind: "Pod", metadata: {generateName: "warm-", namespace: $ns},
  spec: {securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: "RuntimeDefault"}},
         containers: [{name: "app", image: $img, securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]}}')"

rc=0
API_URL="$API_URL" TOKEN="$TOKEN" NAMESPACE="$NS" IMAGE="$IMAGE" OUT="${BENCH_OUT}/${OUT_NAME}.raw.json" \
  k6 run --quiet --no-usage-report "${BENCH_ROOT}/bench/admission-k6.js" >/dev/null || rc=$?

jq --argjson kyverno "$kyverno" --arg image "$IMAGE" --argjson rc "$rc" \
  '. + {image: $image, kyverno_admission_replicas: $kyverno, k6_exit_code: $rc}' \
  "${BENCH_OUT}/${OUT_NAME}.raw.json" > "${BENCH_OUT}/${OUT_NAME}.json"
rm -f "${BENCH_OUT}/${OUT_NAME}.raw.json"
jq -r '"admission: p99 \(.latency_ms.p99 | floor) ms (p50 \(.latency_ms.p50 | floor) ms), \(.requests) requests at \(.rps) rps, \(.failed) failed, threshold ok: \(.threshold_ok)"' "${BENCH_OUT}/${OUT_NAME}.json"
