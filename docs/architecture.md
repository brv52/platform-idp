# Architecture

Two tracks share one cluster: **SLO-gated GitOps delivery** decides *whether*
a release may replace the running one, and the **zero-trust supply chain**
decides *what* may run at all and *who* a workload is.

```
 developer ── git push ──► GitHub ──────────────────────────────┐
                              │                                 │ poll / refresh
                              ▼                                 ▼
                     ┌─ release.yml ──────────────┐     ┌─ Argo CD 3.5 ─────────────┐
                     │ test → build (by digest)    │     │ root app-of-apps          │
                     │ CycloneDX 1.7 SBOM          │     │  wave -2 spire-crds        │
                     │ cosign v3 sign + attest     │     │  wave -1 kyverno, rollouts,│
                     │ SLSA L3 provenance ─────────┼─┐   │          spire, prometheus │
                     │  (isolated generator)       │ │   │  wave  0 otel, policies    │
                     │ verify                      │ │   │  wave  1 tenants           │
                     └──────────────┬──────────────┘ │   └────────────┬──────────────┘
                                    ▼                │                │ apply
                         ghcr.io/brv52/demo-api      │                ▼
                         + .sig bundle (referrer)    │   ┌─ kube-apiserver 1.37 ─────────────┐
                         + .att (SLSA, SBOM)  ◄──────┘   │ mutating: Kyverno verifyImages     │
                                    ▲                    │   signature (SigstoreBundle)       │
                                    │ verify             │   SLSA provenance (Cosign)         │
                                    └────────────────────┤   tag → digest                     │
                                                         │ validating: Kyverno registry rule  │
                                                         │   CEL ValidatingAdmissionPolicy    │
                                                         └────────────────┬──────────────────┘
                                                                          ▼
   ┌─ demo namespace ─────────────────────────────────────────────────────────────────────┐
   │ Argo Rollouts canary 25 % → 50 % → 75 % → 100 %                                       │
   │   stable pods ◄── fortio 40 rps ──► canary pods        SPIRE agent ── CSI ── SVIDs    │
   │                                         │ /metrics                    (1h TTL)        │
   │                       Prometheus ◄──────┘ (hash label)   OTel Collector ◄── traces    │
   │                           │                                                         │
   │       AnalysisRun canary-slo: burn rate 14.4× (5m/30s), 6× (30m/150s), p99, restarts │
   │                           └── fail ×3 → abort → scale canary to 0, stable stays      │
   └─────────────────────────────────────────────────────────────────────────────────────┘
```

## Delivery: SLO-gated canaries

- **Desired state is git.** `gitops/root-app.yaml` is applied once by
  `clusters/local/bootstrap.sh`; everything else, including Argo CD's view
  of the platform, comes from the repository. Child apps are ordered with
  sync waves. Argo CD 3 no longer reports health for `Application`
  resources by default, so `clusters/local/argocd-values.yaml` restores it,
  otherwise waves would not wait. Diffs are computed server-side
  (`controller.diff.server.side`), which removes the classic permanent
  OutOfSync diffs on CRDs and StatefulSets.
- **A release is a commit.** Either the image digest in
  `gitops/tenants/demo-api/kustomization.yaml` or a key in `release.env`
  changes. kustomize renders `release.env` into a ConfigMap with a content
  hash in its name; `kustomizeconfig.yaml` teaches it to rewrite that name
  inside a `Rollout`. A new name means a new pod template, which means a new
  canary.
- **The canary is judged on its own pods only.** Argo Rollouts labels every
  revision's pods with `rollouts-pod-template-hash`, and the Prometheus job
  copies it to every series. All analysis queries filter on the canary hash.
  Without a traffic router, weights are replica ratios, so the canary gets
  ~25/50/75 % of the requests.
- **Multi-window, multi-burn-rate.** Two tiers from the SRE workbook with
  windows scaled by 1/12 to fit a five-minute canary: 14.4× over 5m/30s and 6×
  over 30m/150s against a 99.5 % availability SLO. A tier fails only when
  both windows burn too fast, which avoids flapping on single bad scrapes.
  p99 latency (< 300 ms) and restarts are separate metrics. Every query
  fails closed: a canary with no data does not pass.
- **Rollback is automatic.** Three failed measurements abort the rollout:
  the canary is scaled to zero and the stable ReplicaSet never stopped
  serving. `progressDeadlineAbort` covers canaries that never become ready.

## Supply chain: what may run

| Stage | Where | What it guarantees |
|---|---|---|
| Build | `release.yml` build job | image pushed by digest; timestamps clamped to the commit (`rewrite-timestamp`), so rebuilds of a commit are comparable |
| SBOM | `supply-chain/sbom.sh` | CycloneDX 1.7 for the Go module graph and the final image, attested to the digest |
| Signature | `supply-chain/sign.sh` | keyless cosign v3: a Fulcio certificate bound to `release.yml@refs/heads/main` (or a `v*` tag), logged in Rekor. No keys to manage or leak |
| Provenance | `slsa-github-generator` v2.1.0 | SLSA Build L3: generated and signed in a reusable workflow the build steps cannot influence. Its identity is the generator, not this repo |
| Admission | `policies/kyverno/` | only `ghcr.io/brv52/`; signature by the release identity; provenance by the generator with our builder ID, source URI and entry point; tags rewritten to the verified digest |
| Pod hardening | `policies/vap/` | CEL `ValidatingAdmissionPolicy`, evaluated in the API server with no webhook hop: no privileged, hostPath, host namespaces, privilege escalation, root, missing seccomp or extra capabilities |

Two storage formats coexist on the registry and both had to be handled. This
was found by testing against the real release, not assumed:

- cosign v3 stores its signature as a **Sigstore bundle attached as an OCI
  referrer**. Kyverno's classic `Cosign` verifier does not find it; the
  `SigstoreBundle` verifier does.
- The SLSA generator still uses cosign v2.2.3 and stores provenance in the
  **legacy `.att` tag layout**. Only the `Cosign` verifier reads it, and
  cosign v3 CLI needs the deprecated `--new-bundle-format=false` to verify it.

Platform namespaces (`kube-system`, `argocd`, `kyverno`, `spire-*`,
`monitoring`, …) are excluded from both policy sets. Kyverno's own webhooks
exclude them too, so a broken policy cannot lock the platform out of
repairing itself.

## Identity: who a workload is

SPIRE 1.15 (server in `spire-server`, agents and the SPIFFE CSI driver in
`spire-system`) issues X.509-SVIDs such as
`spiffe://platform-idp.local/ns/demo/sa/demo-api` to pods in namespaces
labelled `platform-idp/spiffe: enabled` (`ClusterSPIFFEID`). Pods get the
Workload API socket through a read-only CSI volume, so tenant pods need no
hostPath and still pass the CEL policy.

demo-api serves its API on `:8443` with TLS 1.3 mutual authentication via
go-spiffe. The server authorises clients by trust domain, the client
authorises the server the same way, and both reload certificates from the
Workload API in place. SVIDs live 1h and rotate at half-life;
`bench/svid-rotation.sh` drops the TTL to 5m to show that rotation under
continuous traffic costs no failed handshakes.

## Observability

- Prometheus 3.15 scrapes demo-api pods (with the revision hash),
  kube-state-metrics (restarts) and itself.
- The OpenTelemetry Collector 0.163.1 receives OTLP traces from demo-api,
  enriches them with Kubernetes attributes and derives RED metrics with the
  `spanmetrics` connector, exposed to Prometheus.
- Logs are structured JSON on stdout. Collection and retention are out of
  scope here (see the gaps in the compliance map).

## Infrastructure

`infra/terraform` has `network`, `eks` and `aks` modules with the same
interface and two short-lived roots: `aws-dev` (eu-central-1, 2× t3.medium
spot, single NAT) and `azure-dev` (germanywestcentral, Standard_B2s_v2).
They are validated, linted and planned in CI; applying them is a manual,
time-boxed step (see `ACTIONS.md`). Everything in this document runs on
the local kind cluster (Kubernetes 1.37.1, one control plane and three
workers) without a cloud account.

## Optional extensions (not deployed)

- **Cilium** as CNI: `NetworkPolicy` / `CiliumNetworkPolicy` for namespace
  isolation and egress allowlists, Hubble for flow logs. This closes the
  segmentation gap in the compliance map. Its mutual-auth mode could reuse
  the same SPIRE server.
- **Istio Ambient** mesh: ztunnel gives L4 mTLS to every pod without
  sidecars, with SPIFFE identities from the mesh CA, or from SPIRE through
  its integration. Waypoint proxies would add L7 authorisation policies and
  real traffic splitting, so the canary could use exact weights through the
  Argo Rollouts traffic router instead of replica ratios.
- Either one would move transport security from the application (go-spiffe)
  into the platform. demo-api keeps its own mTLS here because it makes
  rotation observable at the handshake level, which is what the bench
  measures.
