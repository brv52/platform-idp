## Fallback decisions

| Component | Spec | Problem | Decision |
|---|---|---|---|
| kind node image | `kindest/node:v1.37.1` | kind has not published a v1.37.1 node image (newest prebuilt is `v1.37.0`). | `clusters/local/bootstrap.sh` builds `platform-idp/kind-node:v1.37.1` from the upstream v1.37.1 release binaries (`kind build node-image --type release v1.37.1`, ~4 min once, cached). Set `KIND_NODE_IMAGE=kindest/node:v1.37.0` to skip the build and use the prebuilt image. |
| SPIRE | 1.15.4 | Newest `spiffe/spire` chart (0.30.3) ships app 1.15.3. | Chart 0.30.3, `image.tag: 1.15.4` set for server and agent in values (spire-controller-manager keeps the chart default, it is versioned separately). |
| OTel Collector | 0.163.1 | No chart release ships 0.163.1; chart 0.177.0 ships 0.163.2. | Chart 0.177.0, `image.tag: 0.163.1` set in values. |
| Terraform / OpenTofu | 1.16.6 / 1.13.1 | Both exist. | Roots declare `required_version = ">= 1.13.0"` so either binary works; CI pins Terraform 1.16.6 and OpenTofu 1.13.1. |
| cosign | v3.1.3 | Exists; local CLI is v3.1.4 (same bundle format). | CI installs v3.1.3 explicitly via `sigstore/cosign-installer` with `cosign-release: v3.1.3`. |
| k6 | unpinned | Spec leaves it open. | Pinned to v2.3.0 (`grafana/k6:2.3.0`). |
