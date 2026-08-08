#!/usr/bin/env bash
# Verifies that every pinned component of the stack exists upstream and
# records the resolved digest / release so the rest of the repo can pin it.
#
# Usage: hack/preflight.sh [--write]   (--write regenerates docs/versions.md)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/docs/versions.md"
WRITE=false
[[ "${1:-}" == "--write" ]] && WRITE=true

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need docker
need gh
need helm
need jq

rows_img=()
rows_rel=()
rows_chart=()
rows_tool=()
fail=0

# image <name> <ref> [fallback-ref...]
image() {
  local name="$1"; shift
  local ref digest used=""
  for ref in "$@"; do
    if digest=$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest.Digest}}' 2>/dev/null | tr -d '"'); then
      used="$ref"; break
    fi
  done
  if [[ -z "$used" ]]; then
    echo "FAIL  image   $name  ($*)"; rows_img+=("| $name | \`$1\` | **not found** | - |"); fail=1; return
  fi
  local note="pinned"
  [[ "$used" != "$1" ]] && note="fallback (\`$1\` missing)"
  echo "OK    image   $name  $used@$digest"
  rows_img+=("| $name | \`$used\` | \`$digest\` | $note |")
}

# release <name> <owner/repo> <tag>
release() {
  local name="$1" repo="$2" tag="$3" published latest
  latest=$(gh api "repos/$repo/releases/latest" -q .tag_name 2>/dev/null || echo "?")
  if published=$(gh api "repos/$repo/releases/tags/$tag" -q .published_at 2>/dev/null); then
    echo "OK    release $name  $tag ($published, latest $latest)"
    rows_rel+=("| $name | \`$tag\` | ${published%%T*} | \`$latest\` |")
  elif gh api "repos/$repo/git/ref/tags/$tag" >/dev/null 2>&1; then
    echo "OK    tag     $name  $tag (tag only, latest $latest)"
    rows_rel+=("| $name | \`$tag\` | tag (no release object) | \`$latest\` |")
  else
    echo "FAIL  release $name  $tag (latest $latest)"
    rows_rel+=("| $name | \`$tag\` | **not found** | \`$latest\` |"); fail=1
  fi
}

# chart <repo-name> <repo-url> <chart> <app-version>
chart() {
  local rname="$1" url="$2" chart="$3" app="$4" ver
  helm repo add "$rname" "$url" --force-update >/dev/null 2>&1
  ver=$(helm search repo "$rname/$chart" --versions -o json 2>/dev/null \
    | jq -r --arg a "$app" '[.[] | select(.app_version == $a or .app_version == ("v"+$a) or (.app_version|ltrimstr("v")) == ($a|ltrimstr("v")))][0].version // empty')
  if [[ -n "$ver" ]]; then
    echo "OK    chart   $rname/$chart $ver (app $app)"
    rows_chart+=("| \`$rname/$chart\` | \`$ver\` | \`$app\` | $url |")
    return
  fi
  # No chart ships this exact app version: take the newest chart from the same
  # minor line and pin the image tag through values instead.
  local minor near
  minor=$(echo "${app#v}" | cut -d. -f1-2)
  near=$(helm search repo "$rname/$chart" --versions -o json \
    | jq -r --arg m "$minor" '[.[] | select((.app_version|ltrimstr("v")) | startswith($m + "."))][0] | select(.) | "\(.version) \(.app_version)"')
  if [[ -n "$near" ]]; then
    echo "OK    chart   $rname/$chart ${near% *} (app ${near#* }, image tag overridden to $app)"
    rows_chart+=("| \`$rname/$chart\` | \`${near% *}\` | \`$app\` (chart ships \`${near#* }\`, image tag overridden in values) | $url |")
  else
    local newest
    newest=$(helm search repo "$rname/$chart" -o json | jq -r '.[0] | "\(.version) (app \(.app_version))"')
    echo "FAIL  chart   $rname/$chart for app $app (newest $newest)"
    rows_chart+=("| \`$rname/$chart\` | **none for app $app** | newest: $newest | $url |"); fail=1
  fi
}

# tool <name> <expected-substring> <version-cmd...>
tool() {
  local name="$1" want="$2"; shift 2
  local got
  if ! command -v "$1" >/dev/null; then
    echo "WARN  tool    $name not installed (want $want)"; rows_tool+=("| $name | $want | not installed |"); return
  fi
  got=$("$@" 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo "INFO  tool    $name $got (want $want)"
  rows_tool+=("| $name | $want | $got |")
}

echo "== container images"
image "kind node (Kubernetes 1.37.1)"   kindest/node:v1.37.1 kindest/node:v1.37.0
image "k3s (Kubernetes 1.37.1)"         rancher/k3s:v1.37.1-k3s1 rancher/k3s:v1.37.1-k3s2
image "Go build image"                  golang:1.27-alpine
image "distroless runtime"              gcr.io/distroless/static-debian13:nonroot gcr.io/distroless/static-debian12:nonroot
image "Argo CD"                         quay.io/argoproj/argocd:v3.5.5
image "Argo Rollouts"                   quay.io/argoproj/argo-rollouts:v1.10.1
image "Kyverno"                         reg.kyverno.io/kyverno/kyverno:v1.19.1 ghcr.io/kyverno/kyverno:v1.19.1
image "SPIRE server"                    ghcr.io/spiffe/spire-server:1.15.4
image "SPIRE agent"                     ghcr.io/spiffe/spire-agent:1.15.4
image "Prometheus"                      quay.io/prometheus/prometheus:v3.15.0
image "OTel Collector (contrib)"        otel/opentelemetry-collector-contrib:0.163.1 ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.163.1
image "k6"                              grafana/k6:2.3.0
image "local registry"                  registry:3 registry:2

echo "== upstream releases"
release "Kubernetes"             kubernetes/kubernetes               v1.37.1
release "Terraform"              hashicorp/terraform                 v1.16.6
release "OpenTofu"               opentofu/opentofu                   v1.13.1
release "Argo CD"                argoproj/argo-cd                    v3.5.5
release "Argo Rollouts"          argoproj/argo-rollouts              v1.10.1
release "Kyverno"                kyverno/kyverno                     v1.19.1
release "cosign"                 sigstore/cosign                     v3.1.3
release "slsa-github-generator"  slsa-framework/slsa-github-generator v2.1.0
release "SPIRE"                  spiffe/spire                        v1.15.4
release "Prometheus"             prometheus/prometheus               v3.15.0
release "OTel Collector"         open-telemetry/opentelemetry-collector-releases v0.163.1
release "CycloneDX spec"         CycloneDX/specification             1.7.2
release "cyclonedx-gomod"        CycloneDX/cyclonedx-gomod           "$(gh api repos/CycloneDX/cyclonedx-gomod/releases/latest -q .tag_name)"
release "k6"                     grafana/k6                          v2.3.0
release "kind"                   kubernetes-sigs/kind                "$(kind version 2>/dev/null | awk '{print $2}')"

echo "== helm charts"
chart argo         https://argoproj.github.io/argo-helm              argo-cd                 v3.5.5
chart argo         https://argoproj.github.io/argo-helm              argo-rollouts           v1.10.1
chart kyverno      https://kyverno.github.io/kyverno                 kyverno                 v1.19.1
chart spiffe       https://spiffe.github.io/helm-charts-hardened     spire                   1.15.4
chart prometheus-community https://prometheus-community.github.io/helm-charts prometheus     v3.15.0
chart open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts opentelemetry-collector 0.163.1

echo "== local toolchain"
tool go        1.27     go version
tool kubectl   1.37.1   kubectl version --client
tool kind      any      kind version
tool helm      3.x      helm version --short
tool tofu      1.13.1   tofu version
tool terraform 1.16.6   terraform version
tool tflint    latest   tflint --version
tool cosign    3.1.3    cosign version
tool syft      latest   syft version
tool k6        latest   k6 version
tool kyverno   1.19.1   kyverno version

if $WRITE; then
  {
    echo "# Pinned versions"
    echo
    echo "Generated by \`hack/preflight.sh --write\` on $(date -u +%Y-%m-%d). Re-run before bumping anything."
    echo
    echo "## Container images"
    echo
    echo "| Component | Reference | Digest | Note |"
    echo "|---|---|---|---|"
    printf '%s\n' "${rows_img[@]}"
    echo
    echo "## Upstream releases"
    echo
    echo "| Component | Pinned | Published | Latest upstream |"
    echo "|---|---|---|---|"
    printf '%s\n' "${rows_rel[@]}"
    echo
    echo "## Helm charts"
    echo
    echo "| Chart | Chart version | App version | Repository |"
    echo "|---|---|---|---|"
    printf '%s\n' "${rows_chart[@]}"
    echo
    echo "## Local toolchain (at generation time)"
    echo
    echo "| Tool | Wanted | Found |"
    echo "|---|---|---|"
    printf '%s\n' "${rows_tool[@]}"
    echo
    cat "${ROOT}/hack/fallbacks.md"
  } > "$OUT"
  echo "wrote $OUT"
fi

exit "$fail"
