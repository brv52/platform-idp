# NIS2 / DORA traceability matrix

This maps every technical control in this repository to the provisions it
helps satisfy. It is an engineering traceability aid, not a compliance
opinion. Most provisions also require organisational measures (policies,
roles, risk assessments, reviews) that a code repository cannot provide.
Those are marked as gaps at the end.

## Sources and how they were checked

Every article, section and point number below was checked against the text
of the act on 2026-10-23. Nothing was cited from memory.

| Act | Short name here | Text read |
|---|---|---|
| Zákon č. 264/2025 Sb., o kybernetické bezpečnosti (ze dne 11. června 2025, účinnost od 1. 11. 2025) | **ZKB** | consolidated text at <https://www.zakonyprolidi.cz/cs/2025-264>; official: <https://www.e-sbirka.cz/sb/2025/264> |
| Vyhláška č. 409/2025 Sb., o bezpečnostních opatřeních poskytovatele regulované služby v režimu vyšších povinností (ze dne 26. září 2025, účinnost od 1. 11. 2025) | **Vyhl. 409** | <https://www.zakonyprolidi.cz/cs/2025-409>; official: <https://www.e-sbirka.cz/sb/2025/409> |
| Commission Implementing Regulation (EU) 2024/2690 | **EU 2024/2690** | CELEX 32024R2690 via the Publications Office (`http://publications.europa.eu/resource/celex/32024R2690`), same text as <https://eur-lex.europa.eu/eli/reg_impl/2024/2690/oj> |
| Commission Delegated Regulation (EU) 2024/1774 (DORA RTS on the ICT risk management framework) | **DORA RTS** | CELEX 32024R1774 via the Publications Office, same text as <https://eur-lex.europa.eu/eli/reg_del/2024/1774/oj> |

Scope notes, taken from the acts themselves:

- **ZKB § 13 odst. 3** empowers the Office (NÚKIB) to set the content of
  security measures by decree. Vyhl. 409 says in its preamble that it is
  issued under that provision. It applies to providers in the *higher
  obligations* regime (§ 1). The areas it details are the ones listed in
  **ZKB § 14 odst. 1**: písm. a) organisational measures, points 1–14, and
  písm. b) technical measures, points 1–11.
- **EU 2024/2690 Article 2(1)**: the Annex sets out the technical and
  methodological requirements of the measures in *Article 21(2), points (a)
  to (j), of Directive (EU) 2022/2555*. Under Article 1 it applies to the
  digital-infrastructure and digital-provider entity types it lists, such as
  cloud computing, managed service and managed security service providers.
  For other entities it is a useful reference, not a binding text.
- **DORA RTS** specifies elements of the ICT risk management framework *in
  accordance with Article 15 of Regulation (EU) 2022/2554* (recital 1). The
  articles cited below are in Title II (the full framework). Title III is the
  simplified framework.
- The Czech texts were read from the zakonyprolidi.cz consolidated mirror.
  Before relying on this matrix formally, re-check the cited headings against
  e-Sbírka.

## Controls

Evidence column: *CI* = enforced on every push in `.github/workflows/`,
*admission* = enforced by the cluster at pod admission, *bench* =
measured by `bench/` (results in [`docs/results.md`](../results.md)).

| ID | Control | Implementation | Evidence |
|---|---|---|---|
| C1 | SLSA Build L3 provenance | `release.yml` calls `slsa-github-generator` v2.1.0 `generator_container_slsa3.yml` (isolated reusable workflow). `supply-chain/provenance.sh` verifies it. | CI (verify job), admission (`verify-slsa-provenance` checks builder ID, source URI and entry point) |
| C2 | CycloneDX 1.7 SBOM | `supply-chain/sbom.sh`: module SBOM (cyclonedx-gomod) and image SBOM (syft), attested to the image digest with cosign | CI (verify job checks the attestation), SBOM artifacts on every release |
| C3 | Keyless signature, verified at admission, digest pinning | `supply-chain/sign.sh` (cosign v3, Fulcio/Rekor, GitHub OIDC). `policies/kyverno/verify-images.yaml` accepts only the `release.yml` identity on `main` or `v*` tags; `mutateDigest` pins tags to verified digests | admission; bench: attacks `unsigned`, `tag-swapped`, `foreign-builder` rejected |
| C4 | Registry allowlist | `policies/kyverno/restrict-registries.yaml`: tenant pods may only use `ghcr.io/brv52/` | admission; CI (`kyverno test policies/tests`) |
| C5 | Pod security baseline in CEL | `policies/vap/`: ValidatingAdmissionPolicy denies privileged containers, hostPath, host namespaces, privilege escalation, root, missing seccomp, added capabilities other than NET_BIND_SERVICE | admission (in-process in the API server); CI; bench: attacks `privileged`, `host-path` rejected |
| C6 | Workload identity and mTLS | SPIRE 1.15.4 issues `spiffe://platform-idp.local/ns/<ns>/sa/<sa>` X.509-SVIDs via the CSI driver. demo-api serves TLS 1.3 mTLS and authorises peers by trust domain (`internal/identity`) | bench: rotation run, every request mutually authenticated |
| C7 | Short-lived, automatically rotated credentials | SVID TTL 1h (`gitops/platform/spire/values.yaml`), renewed at half-life and reloaded in place by go-spiffe; no static secrets for service-to-service auth | bench: `svid-rotation.sh` at TTL 5m, 0 failed handshakes |
| C8 | Monitoring, metrics and tracing | Prometheus 3.15 scrapes demo-api by pod-template hash; OTel Collector 0.163.1 exports traces and span metrics; structured JSON logs | running in the cluster; queries in `rollouts/analysis/canary-slo.yaml` |
| C9 | SLO-gated canary with automatic rollback | Argo Rollouts canary (25/50/75 %) with background analysis: multi-window multi-burn-rate error budget (14.4× and 6×), p99 latency, restarts. Fails closed on missing data; aborts and returns to the stable revision | bench: `regressions.sh` (bad releases aborted), `clean-releases.sh` (no false rollbacks) |
| C10 | GitOps change management | Every cluster change comes from git through Argo CD (auto-sync, self-heal, prune). Releases are commits; history is the change log | git history; Argo CD sync history |
| C11 | Automated vulnerability scanning of dependencies | `govulncheck` on every push (failed the build on GO-2026-6612/-6617/-6809/-6613, fixed in `28d598e`); SBOM per release for later matching | CI |
| C12 | Policy tests and attack replay | `policies/tests/` (offline Kyverno CLI tests, positive and negative); `bench/attacks/` replays five attacks against the live admission chain, with a baseline pod that must be admitted | CI; bench |

## Mapping

Point numbers are the acts' own (e.g. EU 2024/2690 Annex point 6.4.2; DORA
RTS Article 17(1)(e)). Headings are quoted as published.

| ID | ZKB 264/2025 Sb. § 14 odst. 1 (area) | Vyhl. 409/2025 Sb. | EU 2024/2690 Annex | DORA RTS 2024/1774 |
|---|---|---|---|---|
| C1 | a) bod 10 *akvizice, vývoj a údržba* | § 12 *Akvizice, vývoj a údržba*, odst. 1 písm. c), d) (security requirements built into development) | 6.2 *Secure development life cycle* (6.2.1); 5.1 *Supply chain security policy* (5.1.2(a): suppliers' secure development procedures) | Art. 16 *ICT systems acquisition, development, and maintenance*, (1)(c) (mitigate unintentional alteration or intentional manipulation during development, maintenance and deployment) and (7) (integrity of source code) |
| C2 | a) bod 5 *řízení aktiv*; a) bod 7 *řízení dodavatelů* | § 24 *Aplikační bezpečnost*, odst. 4 (vulnerability scanning; SBOM is the inventory it runs against) | 6.10 *Vulnerability handling and disclosure* (6.10.1); 5.1 | Art. 10 *Vulnerability and patch management*, (2)(d)(i) (track third-party libraries, including open-source) |
| C3 | b) bod 5 *detekce kybernetických bezpečnostních událostí*; a) bod 10 | § 21 *Detekce kybernetických bezpečnostních událostí*, odst. 2 písm. d) (*řízení oprávnění ke spouštění kódu*) | 6.9 *Protection against malicious and unauthorised software* (6.9.1, 6.9.2); 6.2 | Art. 11 *Data and system security*, (2)(c) (only authorised software is installed); Art. 16(1)(c) |
| C4 | b) bod 5 | § 21 odst. 2 písm. d) | 6.9 (6.9.2) | Art. 11(2)(c) |
| C5 | a) bod 11 *řízení přístupu*; b) bod 8 *aplikační bezpečnost* | § 13 *Řízení přístupu*; § 24 odst. 3 (protection of applications against unauthorised activity) | 6.3 *Configuration management* (6.3.1: establish, document, implement and monitor security configurations) | Art. 11(2)(b) (secure configuration baseline and regular verification that it is deployed) |
| C6 | b) bod 3 *správa a ověřování identit*; b) bod 2 *bezpečnost komunikačních sítí*; b) bod 9 *kryptografické algoritmy* | § 19 *Správa a ověřování identit*, odst. 1 (identity of administrators, users **and technical assets**, verified before activity); § 18 *Bezpečnost komunikačních sítí*, písm. g) (confidentiality and integrity in transit using algorithms per § 25); § 25 *Kryptografické algoritmy*, odst. 1 písm. a) | 9 *Cryptography* (9.2(a), (b)); 11.5 *Identification* (11.5.1); 11.6 *Authentication* (11.6.1) | Art. 6 *Encryption and cryptographic controls*, (2)(a), (c) (in transit, internal network connections); Art. 14 *Securing information in transit*, (1)(a); Art. 20 *Identity management*, (1) (unique identification and authentication of natural persons **and systems**); Art. 13 *Network security management*, (e) |
| C7 | b) bod 9 | § 25 odst. 3 písm. b) bod 1 (key and certificate management tool covering generation, distribution, changes, *omezení platnosti*, revocation) | 9.2(c) (key management: (ii) issuing certificates, (iii) distributing, (v) changing or updating keys) | Art. 7 *Cryptographic key management*, (1) (whole lifecycle incl. renewing), (5) (*prompt renewal of certificates in advance of their expiration*) |
| C8 | b) bod 5; b) bod 6 *zaznamenávání událostí*; b) bod 7 *vyhodnocování kybernetických bezpečnostních událostí* | § 22 *Zaznamenávání událostí*; § 23 *Vyhodnocování kybernetických bezpečnostních událostí*; § 26 *Zajišťování dostupnosti regulované služby* | 3.2 *Monitoring and logging* (3.2.1, 3.2.2: automated monitoring that minimises false positives and false negatives, 3.2.3) | Art. 12 *Logging*; Art. 23 *Anomalous activities detection…*, (2)(b) (tools generating alerts); Art. 9 *Capacity and performance management*, (1)(c) |
| C9 | a) bod 9 *řízení změn*; b) bod 10 *zajišťování dostupnosti regulované služby* | § 11 *Řízení změn*, odst. 2 písm. e) (*testování před uvedením do provozu*) and písm. f) (*možnost navrácení do původního stavu*); § 26 | 6.4 *Change management, repairs and maintenance* (6.4.2: changes tested and assessed for impact before being implemented); 3.2.2 | Art. 17 *ICT change management*, (1)(c)(iii) (changes tested and finalised in a controlled manner), (1)(e) (fall-back procedures, *aborting changes or recovering from changes not successfully implemented*) |
| C10 | a) bod 9 | § 11 odst. 2 písm. a) (*dokumentuje jejich řízení*), písm. d) | 6.4 (6.4.1, 6.4.2: changes documented); 6.3 (6.3.1) | Art. 17(1)(d) (documentation and communication of change details) |
| C11 | b) bod 8 *aplikační bezpečnost* | § 24 odst. 1 (apply approved security updates), odst. 4 písm. a), b) (regular vulnerability scanning, results fed into risk management) | 6.10 (6.10.1); 6.6 *Security patch management* (6.6.1) | Art. 10(2)(b) (*automated vulnerability scanning and assessments*); Art. 16(4) (security testing of software packages no later than the integration phase) |
| C12 | a) bod 9; a) bod 14 *provádění auditu kybernetické bezpečnosti* (supporting evidence only) | § 11 odst. 2 písm. e) | 6.5 *Security testing* (6.5.1); 7 *Policies and procedures to assess the effectiveness of cybersecurity risk-management measures* (7.1) | Art. 16(2) (testing and approval of ICT systems before use) |

## Gaps (not covered by this repository)

- **Organisational measures.** ISMS and management requirements (ZKB § 14
  odst. 1 písm. a) body 1–4, Vyhl. 409 §§ 3–6; EU 2024/2690 points 1–2), risk
  assessment (Vyhl. 409 § 8; EU 2024/2690 2.1), supplier register and
  contract clauses (Vyhl. 409 § 9 incl. příloha č. 5; EU 2024/2690 5.2),
  human resources and training (Vyhl. 409 § 10; EU 2024/2690 8, 10).
- **Incident reporting.** ZKB §§ 15–16: initial report within 24 hours of
  detection (§ 16 odst. 1); for significant incidents, a notification within
  72 hours and a final report within 30 days of that notification (§ 16
  odst. 3 písm. a), c)). Also the DORA
  incident-reporting chain. Alerts here stop at Prometheus; nothing reports
  to NÚKIB, Národní CERT or a competent authority.
- **Segregation of duties for changes.** DORA RTS Art. 17(1)(b) requires the
  functions that approve changes to be independent of those that request and
  implement them. This is a single-maintainer repository; a real deployment
  needs protected branches with required reviews, plus CODEOWNERS for
  `policies/` and `gitops/`.
- **Network segmentation and egress control.** Vyhl. 409 § 18 písm. a), b),
  e), EU 2024/2690 6.8 and DORA RTS Art. 13(a) are not implemented. There are
  no NetworkPolicies; Cilium or Istio Ambient would be the extension (see
  [architecture](../architecture.md)).
- **Logging retention and protection.** Vyhl. 409 § 22 odst. 5 requires
  protection of log integrity and confidentiality, a centralised collection
  tool and retention of at least 18 months. DORA RTS Art. 12(2)(a) also
  requires retention and protection. Neither is configured: logs stay on the
  nodes and Prometheus keeps metrics only for its local retention.
- **Penetration testing** (Vyhl. 409 § 24 odst. 5) and **business
  continuity / backup** (Vyhl. 409 § 15; EU 2024/2690 4; DORA RTS Arts. 24–26)
  are out of scope.
- **Signing trust root.** Public-good Sigstore (Fulcio/Rekor) is a third
  party. A regulated entity would assess it as an ICT third-party service
  (DORA) or significant supplier (Vyhl. 409 § 2 písm. h), § 9).
