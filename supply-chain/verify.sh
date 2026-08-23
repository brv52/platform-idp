#!/usr/bin/env bash
# Verifies everything admission control relies on, outside the cluster:
#   1. image signature from release.yml (main or a v* tag)
#   2. CycloneDX SBOM attestation from release.yml
#   3. SLSA v0.2 provenance from slsa-github-generator v2.1.0, built from
#      this repository
#
#   verify.sh <registry/repo@sha256:...>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=supply-chain/identities.env
source "${HERE}/identities.env"
REF="${1:?usage: verify.sh <image@digest>}"

echo "== signature"
cosign verify "${REF}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  --certificate-identity-regexp "${RELEASE_IDENTITY_REGEXP}" >/dev/null
echo "ok"

echo "== sbom attestation"
cosign verify-attestation "${REF}" --type cyclonedx \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  --certificate-identity-regexp "${RELEASE_IDENTITY_REGEXP}" >/dev/null
echo "ok"

"${HERE}/provenance.sh" "${REF}"
