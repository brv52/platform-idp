#!/usr/bin/env bash
# Ships clean releases through GitOps and checks that every one is promoted
# (no false rollbacks). Records commit-to-promotion lead time, which includes
# the Argo CD refresh, the canary steps (25% 3m, 50% 1m, 75% 1m) and the
# analysis that runs alongside them.
#
# Output: $BENCH_OUT/clean-releases.json
# Usage:  bench/clean-releases.sh [count]   (default 5)
set -euo pipefail
# shellcheck source=bench/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl jq git

COUNT="${1:-5}"
TIMEOUT="${TIMEOUT:-900}"
RUN="$(date +%Y%m%d%H%M%S)"

gitops_begin "clean-${RUN}"

results=()
for i in $(seq 1 "$COUNT"); do
  log "clean release ${i}/${COUNT}"
  old=$(stable_hash)
  t_commit=$(release_push "clean release ${i}" "RELEASE_ID=clean-${RUN}-${i}")
  r=$(rollout_track "$old" "$TIMEOUT")
  r=$(jq --argjson i "$i" --argjson t_commit "$t_commit" '{release: $i, expected: "promoted", t_commit: $t_commit} + . + {
        lead_s: (if .outcome == "promoted" then ((.t_end - $t_commit) * 10 | round / 10) else null end),
        false_rollback: (.outcome == "aborted")}' <<<"$r")
  log "  -> $(jq -r '"\(.outcome), lead time \(.lead_s)s"' <<<"$r")"
  results+=("$r")
  if [[ "$(jq -r .outcome <<<"$r")" != "promoted" ]]; then
    # Get back to a known state before the next release.
    release_push "reset after release ${i}" >/dev/null
    rollout_wait_healthy 600 || die "rollout did not recover"
  fi
done

printf '%s\n' "${results[@]}" | jq -s '{
  bench: "clean-releases", generated_at: (now | todate), releases: .,
  summary: {
    total: length,
    promoted: map(select(.outcome == "promoted")) | length,
    false_rollbacks: map(select(.false_rollback)) | length,
    p50_lead_s: (map(.lead_s | select(. != null)) | sort | if length == 0 then null elif length % 2 == 1 then .[length/2|floor] else ((.[length/2-1] + .[length/2]) / 2) end)
  }
}' > "${BENCH_OUT}/clean-releases.json"
jq -r '.summary | "clean releases: \(.promoted)/\(.total) promoted, \(.false_rollbacks) false rollbacks, p50 lead \(.p50_lead_s)s"' "${BENCH_OUT}/clean-releases.json"
