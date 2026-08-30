# shellcheck shell=bash
# Shared helpers for bench/*.sh. Sourced, not executed.
#
# Releases are shipped the GitOps way: each bench run commits release.env
# changes to a scratch branch bench/<run-id> on origin, points the tenants
# Application at it and waits for Argo CD and Argo Rollouts. On exit the
# tenants app is pointed back at main and the branch is deleted.
#
# Environment:
#   CLUSTER_NAME   kind cluster name                (platform-idp)
#   KUBE_CONTEXT   kubectl context                  (kind-$CLUSTER_NAME)
#   BENCH_OUT      directory for JSON results       (bench/out)
#   GIT_REMOTE     remote the tenants app reads     (origin)

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-platform-idp}"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
BENCH_OUT="${BENCH_OUT:-${BENCH_ROOT}/bench/out}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
mkdir -p "${BENCH_OUT}"

log() { printf '\033[1;34m==>\033[0m [%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }

need() {
  local bin
  for bin in "$@"; do command -v "$bin" >/dev/null || die "$bin is required"; done
}

# --- Argo CD ---------------------------------------------------------------

# Stop the root app from reverting changes made to child Applications.
root_autosync() {
  case "$1" in
    off) k -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null ;;
    on)  k -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null ;;
  esac
}

# What a git webhook would do: ask Argo CD to re-read the repo now instead of
# at the next 60 s poll.
app_refresh() {
  k -n argocd annotate application "$1" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

app_wait_synced() { # app timeout_s
  local app="$1" deadline=$(( $(date +%s) + ${2:-300} )) s
  while (( $(date +%s) < deadline )); do
    s=$(k -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}')
    [[ "$s" == "Synced/Healthy" ]] && return 0
    sleep 3
  done
  warn "$app not Synced/Healthy after ${2:-300}s (last: $s)"
  return 1
}

# --- scratch release branch ------------------------------------------------

RELEASE_ENV_PATH="gitops/tenants/demo-api/release.env"

gitops_begin() { # run-id
  need git
  BENCH_BRANCH="bench/$1"
  BENCH_WT="$(mktemp -d)"
  git -C "${BENCH_ROOT}" fetch -q "${GIT_REMOTE}" main
  git -C "${BENCH_ROOT}" worktree add -q -b "${BENCH_BRANCH}" "${BENCH_WT}" "${GIT_REMOTE}/main"
  git -C "${BENCH_WT}" push -q "${GIT_REMOTE}" "${BENCH_BRANCH}"
  BASE_RELEASE_ENV="$(cat "${BENCH_WT}/${RELEASE_ENV_PATH}")"
  trap gitops_end EXIT
  root_autosync off
  k -n argocd patch application tenants --type merge \
    -p "{\"spec\":{\"source\":{\"targetRevision\":\"${BENCH_BRANCH}\"}}}" >/dev/null
  app_refresh tenants
  app_wait_synced tenants 300 || die "tenants app did not settle on ${BENCH_BRANCH}"
  rollout_wait_healthy 600 || die "demo-api is not Healthy before the bench"
  log "releases go to ${GIT_REMOTE}/${BENCH_BRANCH}"
}

gitops_end() {
  local rc=$?
  [[ -n "${BENCH_BRANCH:-}" ]] || return "$rc"
  log "restoring tenants app to main"
  k -n argocd patch application tenants --type merge -p '{"spec":{"source":{"targetRevision":"main"}}}' >/dev/null || true
  root_autosync on || true
  app_refresh tenants || true
  git -C "${BENCH_ROOT}" worktree remove --force "${BENCH_WT}" || true
  git -C "${BENCH_ROOT}" branch -q -D "${BENCH_BRANCH}" || true
  git -C "${BENCH_ROOT}" push -q "${GIT_REMOTE}" --delete "${BENCH_BRANCH}" || true
  BENCH_BRANCH=""
  return "$rc"
}

# release_push <message> [KEY=VALUE ...]
# Writes release.env as the baseline plus the given keys, commits, pushes and
# triggers a refresh. Prints the commit's unix time.
release_push() {
  local msg="$1"; shift
  {
    printf '%s\n' "${BASE_RELEASE_ENV}"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "${BENCH_WT}/${RELEASE_ENV_PATH}"
  git -C "${BENCH_WT}" add "${RELEASE_ENV_PATH}"
  git -C "${BENCH_WT}" commit -q -m "bench: ${msg}"
  git -C "${BENCH_WT}" push -q "${GIT_REMOTE}" "${BENCH_BRANCH}"
  app_refresh tenants
  git -C "${BENCH_WT}" log -1 --format=%ct
}

# --- Argo Rollouts ---------------------------------------------------------

ROLLOUT_NS="${ROLLOUT_NS:-demo}"
ROLLOUT_NAME="${ROLLOUT_NAME:-demo-api}"

rollout_json() { k -n "${ROLLOUT_NS}" get rollout "${ROLLOUT_NAME}" -o json; }

rollout_wait_healthy() { # timeout_s
  local deadline=$(( $(date +%s) + ${1:-600} )) j
  while (( $(date +%s) < deadline )); do
    j=$(rollout_json)
    if [[ $(jq -r '[.status.phase, (.status.abort // false), (.status.stableRS == .status.currentPodHash)] | @tsv' <<<"$j") == $'Healthy\tfalse\ttrue' ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# rollout_track <old-stable-hash> <timeout_s>
# Waits for a new revision to appear, then for promotion or abort. Prints a
# JSON object: outcome, canary hash, timestamps and the AnalysisRun verdicts.
rollout_track() {
  local old="$1" timeout="$2" t_start t_canary="" t_end="" outcome="timeout" hash="" j
  t_start=$(now)
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    j=$(rollout_json)
    local cur phase abort stable
    IFS=$'\t' read -r cur phase abort stable < <(jq -r '[.status.currentPodHash, .status.phase, (.status.abort // false), .status.stableRS] | @tsv' <<<"$j")
    if [[ -z "$t_canary" && "$cur" != "$old" ]]; then
      t_canary=$(now); hash="$cur"
      log "canary ${hash} started"
    fi
    if [[ -n "$t_canary" ]]; then
      if [[ "$abort" == "true" ]]; then outcome="aborted"; t_end=$(now); break; fi
      if [[ "$phase" == "Healthy" && "$stable" == "$hash" ]]; then outcome="promoted"; t_end=$(now); break; fi
    fi
    sleep 2
  done
  [[ -n "$t_end" ]] || t_end=$(now)
  local analysis='[]'
  if [[ -n "$hash" ]]; then
    analysis=$(k -n "${ROLLOUT_NS}" get analysisrun -l "rollouts-pod-template-hash=${hash}" -o json |
      jq '[.items[].status.metricResults[]? | {metric: .name, phase, failed: (.failed // 0), last: (.measurements[-1].value // null)}]')
  fi
  jq -n --arg outcome "$outcome" --arg hash "$hash" \
    --argjson t_start "$t_start" --argjson t_canary "${t_canary:-null}" --argjson t_end "$t_end" \
    --argjson analysis "$analysis" '{
      outcome: $outcome, canary_hash: $hash,
      t_start: $t_start, t_canary: $t_canary, t_end: $t_end,
      canary_to_end_s: (if $t_canary then (($t_end - $t_canary) * 10 | round / 10) else null end),
      analysis: $analysis
    }'
}

stable_hash() { rollout_json | jq -r .status.stableRS; }

