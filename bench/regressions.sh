#!/usr/bin/env bash
# Ships bad releases through GitOps and checks that the SLO analysis aborts
# every one of them. Each case is a release.env change on a scratch branch;
# after the abort the change is reverted and the rollout must return to the
# previous stable revision.
#
#   error-20        20% HTTP 500         fast + slow burn tiers
#   error-5          5% HTTP 500         slow tier only (10x burn < 14.4x)
#   latency-400ms   +400 ms on all req.  latency-p99 > 300 ms
#   latency-tail     +1 s on 5% of req.  latency-p99 > 300 ms
#   crash-loop      exit after 45 s      canary-restarts
#
# Output: $BENCH_OUT/regressions.json
# Usage:  bench/regressions.sh [case ...]
set -euo pipefail
# shellcheck source=bench/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl jq git

declare -A CASES=(
  [error-20]="FAULT_ERROR_PERCENT=20"
  [error-5]="FAULT_ERROR_PERCENT=5"
  [latency-400ms]="FAULT_LATENCY=400ms FAULT_LATENCY_PERCENT=100"
  [latency-tail]="FAULT_LATENCY=1s FAULT_LATENCY_PERCENT=5"
  [crash-loop]="FAULT_CRASH_AFTER=45s"
)
ORDER=(error-20 error-5 latency-400ms latency-tail crash-loop)
(( $# )) && ORDER=("$@")
TIMEOUT="${TIMEOUT:-600}"

gitops_begin "regressions-$(date +%Y%m%d%H%M%S)"

results=()
for name in "${ORDER[@]}"; do
  [[ -n "${CASES[$name]:-}" ]] || die "unknown case: $name"
  log "bad release: ${name} (${CASES[$name]})"
  old=$(stable_hash)
  # shellcheck disable=SC2086 # word splitting of the KEY=VALUE list is intended
  t_commit=$(release_push "regression ${name}" "RELEASE_ID=bad-${name}" ${CASES[$name]})
  r=$(rollout_track "$old" "$TIMEOUT")
  log "  -> $(jq -r '"\(.outcome) after \(.canary_to_end_s)s, failed: \([.analysis[] | select(.phase == "Failed") | .metric] | join(","))"' <<<"$r")"
  results+=("$(jq --arg name "$name" --arg env "${CASES[$name]}" --argjson t_commit "$t_commit" \
    '{case: $name, fault: $env, expected: "aborted", t_commit: $t_commit} + . + {detected: (.outcome == "aborted")}' <<<"$r")")

  log "reverting ${name}"
  release_push "revert ${name}" >/dev/null
  rollout_wait_healthy 600 || die "rollout did not return to Healthy after reverting ${name}"
  [[ "$(stable_hash)" == "$old" ]] || warn "stable revision changed after revert"
  # Let the reverted canary's series age out of the short burn windows so
  # the next case starts from a clean baseline.
  sleep "${SETTLE:-60}"
done

printf '%s\n' "${results[@]}" | jq -s '{
  bench: "regressions", generated_at: (now | todate), cases: .,
  summary: {
    total: length,
    detected: map(select(.detected)) | length,
    median_detect_s: (map(select(.detected) | .canary_to_end_s) | sort | if length == 0 then null elif length % 2 == 1 then .[length/2|floor] else ((.[length/2-1] + .[length/2]) / 2) end)
  }
}' > "${BENCH_OUT}/regressions.json"
jq -r '.summary | "regressions: \(.detected)/\(.total) aborted, median detection \(.median_detect_s)s"' "${BENCH_OUT}/regressions.json"
