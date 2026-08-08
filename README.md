# platform-idp

An internal developer platform reference built around two ideas:

1. **SLO-gated delivery.** Every release of a service goes out as an Argo Rollouts canary
   that is promoted or aborted by multi-window burn-rate analysis on canary-only metrics.
2. **Zero-trust supply chain.** Nothing runs in the cluster unless it was built by the
   expected pipeline: keyless cosign v3 signatures, SLSA Build L3 provenance and a CycloneDX
   SBOM are verified at admission by Kyverno, pod hardening is enforced by native
   `ValidatingAdmissionPolicy`, and workloads authenticate to each other with short-lived
   SPIFFE X.509-SVIDs.

The controls are mapped to the Czech NIS2 transposition and to DORA in
[`docs/compliance/nis2-dora-map.md`](docs/compliance/nis2-dora-map.md), and every number in
[`docs/results.md`](docs/results.md) is produced by a script under [`bench/`](bench/).

## Layout

| Path | What lives there |
|---|---|
| `infra/terraform/` | `network`, `eks`, `aks` modules with a shared interface; short-lived `aws-dev` / `azure-dev` roots |
| `clusters/local/` | kind config and `bootstrap.sh` |
| `gitops/` | Argo CD app-of-apps, platform components, tenant workloads |
| `services/demo-api/` | Go service with OpenTelemetry, SPIFFE mTLS and runtime fault injection |
| `rollouts/analysis/` | burn-rate `AnalysisTemplate`s |
| `policies/` | Kyverno image verification, CEL pod security policies |
| `supply-chain/` | SBOM, signing and provenance scripts |
| `bench/` | rollback, admission latency, attack replay and SVID rotation benchmarks |
| `docs/` | architecture, results, versions, compliance mapping |

## Quick start

```sh
make preflight   # check pinned versions
make bootstrap   # kind cluster + Argo CD + platform apps
make bench       # populate metrics.json and docs/results.md
```

Pinned versions and the reasoning behind every fallback are in [`docs/versions.md`](docs/versions.md).
