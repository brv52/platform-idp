#!/usr/bin/env bash
# Creates the local kind cluster, a local registry, installs Argo CD and hands
# the rest of the platform to Argo CD through gitops/root-app.yaml.
# Safe to re-run: every step checks before it acts.
#
# Environment:
#   CLUSTER_NAME      kind cluster name                       (platform-idp)
#   KIND_NODE_IMAGE   node image                              (platform-idp/kind-node:v1.37.1, built if missing)
#   K8S_VERSION       version built when the default image is missing   (v1.37.1)
#   REGISTRY_PORT     host port of the local registry         (5001)
#   SKIP_ROOT_APP     set to 1 to stop after installing Argo CD
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

CLUSTER_NAME="${CLUSTER_NAME:-platform-idp}"
K8S_VERSION="${K8S_VERSION:-v1.37.1}"
DEFAULT_NODE_IMAGE="platform-idp/kind-node:${K8S_VERSION}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-${DEFAULT_NODE_IMAGE}}"
REGISTRY_NAME="kind-registry"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_IMAGE="registry:3@sha256:01cd312e67026f06f5d89c3e133a4a9adc7cb9eeb9b1194e0b2954dfd770efd2"
ARGOCD_CHART_VERSION="10.11.0" # Argo CD v3.5.5
KCTX="kind-${CLUSTER_NAME}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "${KCTX}" "$@"; }

preflight() {
  for bin in docker kind kubectl helm; do
    command -v "$bin" >/dev/null || die "$bin is required"
  done
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"

  local mem_gb
  mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
  if (( mem_gb < 11 )); then
    warn "docker sees ${mem_gb} GiB; the full platform needs ~10 GiB free (see ACTIONS.md section 0)."
  fi

  local watches
  watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  if (( watches < 524288 )); then
    warn "fs.inotify.max_user_watches=${watches}; multi-node kind may fail with 'too many open files'."
  fi
}

node_image() {
  if docker image inspect "${KIND_NODE_IMAGE}" >/dev/null 2>&1; then
    return
  fi
  if [[ "${KIND_NODE_IMAGE}" == "${DEFAULT_NODE_IMAGE}" ]]; then
    # kind has not published a node image for this version; build it from
    # the upstream release binaries (see docs/versions.md).
    log "building ${KIND_NODE_IMAGE} from Kubernetes ${K8S_VERSION} release binaries (one-off, ~4 min)"
    kind build node-image --type release "${K8S_VERSION}" --image "${KIND_NODE_IMAGE}"
  else
    log "pulling ${KIND_NODE_IMAGE}"
    docker pull "${KIND_NODE_IMAGE}"
  fi
}

registry() {
  if [[ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != "true" ]]; then
    docker rm -f "${REGISTRY_NAME}" >/dev/null 2>&1 || true
    log "starting local registry on 127.0.0.1:${REGISTRY_PORT}"
    docker run -d --restart=always --name "${REGISTRY_NAME}" \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" "${REGISTRY_IMAGE}" >/dev/null
  fi
}

# kind config, plus a kubelet override when the host is still on cgroup v1.
# Since Kubernetes 1.35 the kubelet refuses to start on cgroup v1 unless
# failCgroupV1 is false. WSL2 defaults to v1; the real fix is cgroup v2
# (ACTIONS.md section 0), this only keeps the cluster usable meanwhile.
kind_config() {
  local cfg="${HERE}/kind.yaml"
  if [[ "$(docker info --format '{{.CgroupVersion}}')" == "1" ]]; then
    warn "docker runs on cgroup v1; starting kubelets with failCgroupV1=false (deprecated mode)"
    local tmp
    tmp="$(mktemp)"
    cat "${cfg}" > "${tmp}"
    printf '%s\n' '' 'kubeadmConfigPatches:' '  - |' '    kind: KubeletConfiguration' '    failCgroupV1: false' >> "${tmp}"
    cfg="${tmp}"
  fi
  echo "${cfg}"
}

cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "cluster ${CLUSTER_NAME} already exists"
  else
    log "creating cluster ${CLUSTER_NAME} (${KIND_NODE_IMAGE})"
    kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" \
      --config "$(kind_config)" --wait 120s
  fi

  # Wire the registry into the kind network and every node's containerd.
  if ! docker network inspect kind -f '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "${REGISTRY_NAME}"; then
    docker network connect kind "${REGISTRY_NAME}"
  fi
  local dir="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    docker exec "${node}" mkdir -p "${dir}"
    printf '[host."http://%s:5000"]\n' "${REGISTRY_NAME}" | docker exec -i "${node}" cp /dev/stdin "${dir}/hosts.toml"
  done

  # Advertise the registry (KEP-1755) so tools like tilt/skaffold find it.
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

argocd() {
  log "installing Argo CD (chart ${ARGOCD_CHART_VERSION})"
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm --kube-context "${KCTX}" upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --version "${ARGOCD_CHART_VERSION}" \
    --values "${HERE}/argocd-values.yaml" \
    --wait --timeout 10m >/dev/null

  for d in argocd-server argocd-repo-server argocd-applicationset-controller; do
    k -n argocd rollout status deploy/"$d" --timeout=300s >/dev/null
  done
  k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null
}

root_app() {
  if [[ "${SKIP_ROOT_APP:-0}" == "1" ]]; then
    log "SKIP_ROOT_APP=1, not applying the root application"
    return
  fi
  local app="${ROOT}/gitops/root-app.yaml"
  if [[ ! -f "${app}" ]]; then
    warn "${app} not found; Argo CD is installed but manages nothing yet"
    return
  fi
  log "applying gitops/root-app.yaml"
  k apply -n argocd -f "${app}"
}

summary() {
  local pw
  pw=$(k -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
  cat <<EOF

Cluster ${CLUSTER_NAME} is up (context ${KCTX}).

  Argo CD UI     http://localhost:8080   user: admin   password: ${pw:-<already rotated>}
  Registry       localhost:${REGISTRY_PORT}  (docker push localhost:${REGISTRY_PORT}/demo-api:<tag>)
  Nodes          $(k get nodes --no-headers | wc -l) ($(k version -o json | sed -n 's/.*"gitVersion": "\(v[^"]*\)".*/\1/p' | tail -1))

Watch the platform converge:  kubectl --context ${KCTX} -n argocd get applications -w
EOF
}

preflight
node_image
registry
cluster
argocd
root_app
summary
