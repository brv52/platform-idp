# infra/terraform

Short-lived cloud environments built from cloud-agnostic module contracts.

```
modules/
  network/aws     VPC, 2 AZs, single NAT gateway (or none), S3 gateway endpoint
  network/azure   VNet + node subnet + NSG
  eks             EKS, spot managed node groups, IRSA OIDC provider, access entries
  aks             AKS free tier, Entra ID + Azure RBAC only, workload identity, Cilium dataplane
envs/
  aws-dev         eu-central-1, 2x t3.medium spot
  azure-dev       germanywestcentral, 1x Standard_B2s_v2
```

The `eks` and `aks` modules share one input/output contract, described in
[`modules/README.md`](modules/README.md).

## Tooling

Terraform 1.16.6 is the reference binary: CI runs it and the committed
`.terraform.lock.hcl` files are generated with it for linux_amd64, darwin_amd64
and darwin_arm64:

```sh
terraform providers lock -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64
```

OpenTofu >= 1.13 works as well (`required_version = ">= 1.13.0"`), but writes
providers under `registry.opentofu.org`, so `tofu init` will add its own
entries to the lock file. Don't commit those.

## Checks

```sh
terraform fmt -check -recursive
(cd envs/aws-dev && terraform init -backend=false && terraform validate)
(cd envs/azure-dev && terraform init -backend=false && terraform validate)
tflint --init --config "$(pwd)/.tflint.hcl" && tflint --recursive --config "$(pwd)/.tflint.hcl"
```

## Lifecycle

These environments exist to prove the modules apply cleanly and to capture
evidence (`docs/evidence/`). Apply, capture, destroy on the same day; the
runbook and cost estimate are in the untracked `ACTIONS.md`.
