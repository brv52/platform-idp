#!/usr/bin/env bash
# Replays five attacks against admission control and expects every one to be
# rejected, by the control that is supposed to catch it. A baseline pod
# (signed image, hardened spec) must be admitted, so a deny-all webhook
# cannot pass this test.
#
#   unsigned          image never signed                       Kyverno verify-signature
#   tag-swapped       tag moved to a tampered digest           Kyverno verify-signature
#   foreign-builder   signed by another workflow, forged SLSA  Kyverno verify-signature
#                     predicate claiming the official builder  (+ verify-slsa-provenance)
#   privileged        signed image, privileged: true           CEL ValidatingAdmissionPolicy
#   host-path         signed image, hostPath / mount           CEL ValidatingAdmissionPolicy
#
# Requests are server-side dry runs: the full admission chain runs, nothing
# is persisted. Attack images come from .github/workflows/attack-fixtures.yml.
#
# Output: $BENCH_OUT/attacks.json
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bench/lib.sh
source "${HERE}/../lib.sh"
need kubectl jq

NS="${ATTACK_NS:-bench-attacks}"
REPO="${IMAGE_REPO:-ghcr.io/brv52/demo-api}"
# The signed release the tenant runs, so the pod-security attacks get past
# image verification and are judged on their spec alone.
SIGNED="${SIGNED_IMAGE:-$(kubectl kustomize "${BENCH_ROOT}/gitops/tenants/demo-api" | awk '/image: ghcr.io/ {print $2; exit}')}"
[[ "$SIGNED" == *@sha256:* ]] || die "could not determine the signed image digest"

k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
k label namespace "$NS" platform-idp/tenant=true --overwrite >/dev/null

pod() { # image [jq filter]
  sed -e "s|__NS__|${NS}|" -e "s|__IMAGE__|$1|" "${HERE}/pod.tmpl.json" | jq "${2:-.}"
}

results=()
attempt() { # name expect(admit|deny) blocker-regexp pod-json
  local name="$1" expect="$2" want="$3" out rc=0 got verdict
  out=$(k create --dry-run=server -o name -f - <<<"$4" 2>&1) || rc=$?
  out=$(tr -s '\n' ' ' <<<"$out")
  if (( rc == 0 )); then got="admitted"; else got="denied"; fi
  if [[ "$expect" == "admit" ]]; then
    [[ "$got" == "admitted" ]] && verdict=pass || verdict=fail
  else
    [[ "$got" == "denied" ]] && grep -Eq "$want" <<<"$out" && verdict=pass || verdict=fail
  fi
  log "$(printf '%-16s %-9s %s' "$name" "$got" "$verdict")"
  results+=("$(jq -n --arg name "$name" --arg expect "$expect" --arg got "$got" --arg verdict "$verdict" \
    --arg control "$want" --arg message "${out:0:600}" \
    '{attack: $name, expected: $expect, result: $got, verdict: $verdict, expected_control: $control, message: $message}')")
}

attempt baseline admit "" "$(pod "$SIGNED")"
attempt unsigned deny "verify-supply-chain.*verify-signature" "$(pod "${REPO}:attack-unsigned")"
attempt tag-swapped deny "verify-supply-chain.*verify-signature" "$(pod "${REPO}:attack-swapped")"
# Precondition: the foreign image really is validly signed (by
# attack-fixtures.yml) and carries a predicate claiming the official builder,
# so its rejection is down to the signer identity alone.
foreign_signed="unchecked"
if command -v cosign >/dev/null; then
  foreign_signed=false
  cosign verify "${REPO}:attack-foreign" --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github\.com/brv52/platform-idp/\.github/workflows/attack-fixtures\.yml@' \
    >/dev/null 2>&1 && foreign_signed=true
  log "foreign image validly signed by attack-fixtures.yml: ${foreign_signed}"
fi
attempt foreign-builder deny "verify-supply-chain.*verify-signature" "$(pod "${REPO}:attack-foreign")"
attempt privileged deny "platform-idp-pod-security.*privileged containers" \
  "$(pod "$SIGNED" '.spec.containers[0].securityContext += {privileged: true, allowPrivilegeEscalation: true}')"
attempt host-path deny "platform-idp-pod-security.*hostPath" \
  "$(pod "$SIGNED" '.spec.volumes = [{name: "host", hostPath: {path: "/"}}] | .spec.containers[0].volumeMounts = [{name: "host", mountPath: "/host"}]')"

printf '%s\n' "${results[@]}" | jq -s --arg signed "$SIGNED" --arg foreign_signed "$foreign_signed" '{
  bench: "attacks", generated_at: (now | todate), signed_image: $signed, results: .,
  summary: {
    attacks: map(select(.expected == "deny")) | length,
    blocked: map(select(.expected == "deny" and .verdict == "pass")) | length,
    baseline_admitted: (map(select(.attack == "baseline"))[0].verdict == "pass"),
    foreign_image_validly_signed_by_other_identity: $foreign_signed
  }
}' > "${BENCH_OUT}/attacks.json"
jq -r '.summary | "attacks: \(.blocked)/\(.attacks) blocked, baseline admitted: \(.baseline_admitted)"' "${BENCH_OUT}/attacks.json"
