#!/usr/bin/env bash
# Signs an image digest and attests its SBOM with cosign v3, keyless.
#
#   sign.sh <registry/repo@sha256:...> <image-sbom.cdx.json>
#
# cosign v3 writes Sigstore protobuf bundles attached as OCI referrers by
# default (the v2 --new-bundle-format opt-in is now a hidden, deprecated
# flag that defaults to true). Run where an OIDC token is available: GitHub Actions with
# id-token: write, GitLab with an id_tokens entry (aud: sigstore), or
# interactively (browser flow).
set -euo pipefail

REF="${1:?usage: sign.sh <image@digest> <sbom>}"
SBOM="${2:?usage: sign.sh <image@digest> <sbom>}"
[[ "${REF}" == *@sha256:* ]] || { echo "sign by digest, not tag: ${REF}" >&2; exit 1; }

cosign version 2>/dev/null | grep -q 'GitVersion:\s*v3\.' || { echo "cosign v3 required" >&2; exit 1; }

cosign sign --yes "${REF}"
cosign attest --yes --type cyclonedx --predicate "${SBOM}" "${REF}"
