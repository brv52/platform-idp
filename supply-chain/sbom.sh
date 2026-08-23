#!/usr/bin/env bash
# Generates CycloneDX 1.7 SBOMs for demo-api.
#
#   sbom.sh <image-ref> [outdir]
#
#   <outdir>/demo-api.module.cdx.json  Go module graph (cyclonedx-gomod), the
#                                      authoritative dependency list
#   <outdir>/demo-api.image.cdx.json   container image (syft): base image
#                                      packages + the Go binary's build info;
#                                      this one is attested to the image
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:?usage: sbom.sh <image-ref> [outdir]}"
OUT="${2:-${ROOT}/supply-chain/out}"
SPEC="1.7"
mkdir -p "${OUT}"

for bin in cyclonedx-gomod syft jq; do
  command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }
done

(cd "${ROOT}/services/demo-api" &&
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
    cyclonedx-gomod app -json -licenses -std -output-version "${SPEC}" \
    -main cmd/demo-api -output "${OUT}/demo-api.module.cdx.json" .)

# Per-file entries would add ~950 components of noise for a distroless image.
SYFT_FILE_METADATA_SELECTION=none SYFT_FILE_CONTENT_SKIP_FILES_ABOVE_SIZE=0 \
  syft scan "registry:${IMAGE}" -q -o "cyclonedx-json@${SPEC}=${OUT}/demo-api.image.cdx.json"

for f in "${OUT}"/demo-api.*.cdx.json; do
  printf '%-40s spec %s, %s components\n' "$(basename "$f")" \
    "$(jq -r .specVersion "$f")" "$(jq '.components | length' "$f")"
done
