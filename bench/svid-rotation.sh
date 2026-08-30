#!/usr/bin/env bash
# Zero-downtime SVID rotation under continuous mTLS traffic.
#
# FOR THE DURATION OF THIS TEST the SPIRE Server default X.509-SVID TTL is
# lowered from 1h to 5m (gitops/platform/spire/values-rotation-test.yaml), so
# agents rotate every workload's SVID about every 2.5 minutes (half-life).
# The demo-api pods are restarted to pick up short-lived SVIDs right away,
# then an in-cluster client with its own SPIFFE identity calls the demo-api
# mTLS port (TLS 1.3, both sides verified against the SPIRE trust bundle)
# for DURATION. Both sides reload certificates from the Workload API in
# place; any handshake failure fails the test. Afterwards the TTL is
# restored by re-enabling the root app, which reverts the spire Application
# to git.
#
# Output: $BENCH_OUT/svid-rotation.json
# Usage:  DURATION=15m bench/svid-rotation.sh
set -euo pipefail
# shellcheck source=bench/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl jq

DURATION="${DURATION:-15m}"
RPS="${RPS:-20}"
NS="${ROLLOUT_NS}"
JOB="svid-rotation-client"
# shellcheck disable=SC2016 # literal Argo CD $values reference
OVERLAY='$values/gitops/platform/spire/values-rotation-test.yaml'

restore() {
  local rc=$?
  log "restoring SPIRE TTL (root app reverts the spire Application to git)"
  k -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null || true
  root_autosync on || true
  app_refresh root || true
  return "$rc"
}

ttl() { k -n spire-server get configmap spire-server -o json | jq -r '.data["server.conf"] | fromjson | .server.default_x509_svid_ttl'; }

root_autosync off
trap restore EXIT

log "lowering default X.509-SVID TTL to 5m"
k -n argocd patch application spire --type json \
  -p "[{\"op\":\"add\",\"path\":\"/spec/sources/0/helm/valueFiles/-\",\"value\":\"${OVERLAY}\"}]" >/dev/null
app_refresh spire
deadline=$(( $(date +%s) + 300 ))
until [[ "$(ttl)" == "5m" ]]; do
  (( $(date +%s) < deadline )) || die "spire-server config did not change"
  sleep 3
done
k -n spire-server rollout status statefulset/spire-server --timeout=300s >/dev/null
app_wait_synced spire 300 || true
log "spire-server running with default_x509_svid_ttl=$(ttl)"

log "restarting demo-api pods so their SVIDs are issued with the short TTL"
restart_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
k -n "$NS" patch rollout "${ROLLOUT_NAME}" --type merge -p "{\"spec\":{\"restartAt\":\"${restart_at}\"}}" >/dev/null
deadline=$(( $(date +%s) + 600 ))
until [[ "$(k -n "$NS" get pods -l app.kubernetes.io/name=demo-api -o json | jq --arg t "$restart_at" \
  '[.items[] | select(.metadata.deletionTimestamp == null)] | (length > 0) and all(.metadata.creationTimestamp >= $t and ([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1))')" == "true" ]]; do
  (( $(date +%s) < deadline )) || die "demo-api pods were not restarted"
  sleep 5
done
servers=$(k -n "$NS" get pods -l app.kubernetes.io/name=demo-api --no-headers | wc -l)

# Same signed image as the server (admission policies apply to this pod too).
IMAGE=$(k -n "$NS" get pods -l app.kubernetes.io/name=demo-api -o jsonpath='{.items[0].spec.containers[0].image}')
log "client: ${RPS} req/s for ${DURATION} against ${servers} demo-api pods"
k -n "$NS" delete job "$JOB" --ignore-not-found >/dev/null
k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: { name: rotation-client, namespace: ${NS} }
---
apiVersion: batch/v1
kind: Job
metadata: { name: ${JOB}, namespace: ${NS} }
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { app.kubernetes.io/name: svid-rotation-client }
    spec:
      serviceAccountName: rotation-client
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: client
          image: ${IMAGE}
          args: [client, --duration=${DURATION}, --rps=${RPS}, --concurrency=4, --report-interval=60s]
          env:
            - { name: SPIFFE_ENDPOINT_SOCKET, value: "unix:///spiffe-workload-api/spire-agent.sock" }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: spiffe-workload-api, mountPath: /spiffe-workload-api, readOnly: true }
      volumes:
        - name: spiffe-workload-api
          csi: { driver: csi.spiffe.io, readOnly: true }
YAML

secs=$(( $(sed -E 's/m$/*60/; s/s$//; s/h$/*3600/' <<<"$DURATION") ))
k -n "$NS" wait --for=condition=Complete --for=condition=Failed "job/${JOB}" --timeout="$(( secs + 300 ))s" >/dev/null || true
logs=$(k -n "$NS" logs "job/${JOB}")
result=$(awk '/^\{$/ { buf = ""; on = 1 } on { buf = buf $0 "\n" } END { printf "%s", buf }' <<<"$logs")
[[ -n "$result" ]] || { printf '%s\n' "$logs" | tail -20 >&2; die "client produced no result"; }
job_ok=$(k -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}')

jq --arg ttl 5m --arg duration "$DURATION" --argjson servers "$servers" --arg job_ok "${job_ok:-0}" '{
  bench: "svid-rotation", generated_at: (now | todate),
  svid_ttl: $ttl, duration: $duration, server_pods: $servers, client: .,
  summary: {
    requests, handshake_failures, failures: (.handshake_failures + .http_errors + .other_errors),
    client_rotations, distinct_server_svids,
    server_rotations: (.distinct_server_svids - $servers),
    zero_failed_handshakes: (.handshake_failures == 0 and .other_errors == 0 and $job_ok == "1"),
    rotations_observed: (.client_rotations >= 2 and .distinct_server_svids > $servers)
  }
}' <<<"$result" > "${BENCH_OUT}/svid-rotation.json"
jq -r '.summary | "rotation: \(.requests) requests, \(.handshake_failures) failed handshakes, \(.client_rotations) client + \(.server_rotations) server SVID rotations"' "${BENCH_OUT}/svid-rotation.json"
