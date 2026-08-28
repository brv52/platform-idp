#!/usr/bin/env bash
# Verifies the SLSA Build L3 provenance that slsa-github-generator attached to
# an image and prints the fields the admission policy checks.
#
#   provenance.sh <registry/repo@sha256:...>
#
# Provenance itself is produced in CI by the reusable workflow
# slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.1.0
# (see .github/workflows/release.yml). It runs in an isolated job we do not
# control, which is what makes it L3: our build steps cannot forge it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supply-chain/identities.env
source "${HERE}/identities.env"
REF="${1:?usage: provenance.sh <image@digest>}"

echo "== slsa provenance"
# The generator pins cosign v2.2.3, which stores provenance in the legacy
# layout (<digest>.att tag, DSSE envelope + Rekor bundle annotations). By
# default cosign v3 only looks at Sigstore bundles attached as OCI
# referrers, so the legacy reader has to be selected explicitly. The flag is
# deprecated but still the only way in v3.1 to read pre-v3 attestations.
cosign verify-attestation "${REF}" --type slsaprovenance --new-bundle-format=false \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  --certificate-identity "${SLSA_BUILDER_ID}" \
  | jq -r '.payload | @base64d | fromjson | .predicate
           | "builder:     \(.builder.id)",
             "source:      \(.invocation.configSource.uri)",
             "entryPoint:  \(.invocation.configSource.entryPoint)",
             "commit:      \(.invocation.configSource.digest.sha1)"' | tee /dev/stderr \
  | grep -q "source:      git+https://${SOURCE_REPO}@" || { echo "provenance source is not ${SOURCE_REPO}" >&2; exit 1; }

if command -v slsa-verifier >/dev/null; then
  slsa-verifier verify-image "${REF}" --source-uri "${SOURCE_REPO}" >/dev/null && echo "slsa-verifier: ok"
fi
echo "ok"
