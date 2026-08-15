# Modules

`eks` and `aks` implement the same cluster contract so an environment root
(and anything downstream, e.g. CI that fetches a kubeconfig) does not care
which cloud it is talking to.

## Inputs (both modules)

| Variable | Type | Notes |
|---|---|---|
| `name` | `string` | Cluster name and resource prefix |
| `kubernetes_version` | `string` | Minor version (`"1.37"`); the cloud picks the patch |
| `node_subnet_ids` | `list(string)` | From the matching `network/<cloud>` module |
| `node_pools` | `map(object)` | See below. The key `system` is required |
| `api_allowed_cidrs` | `list(string)` | Source ranges allowed to reach the public API endpoint |
| `tags` | `map(string)` | Applied to every resource |

`aks` additionally takes `resource_group_name` and `location`.

```hcl
node_pools = {
  system = { size = "t3.medium", min = 1, max = 2, desired = 1, spot = true }
  bench  = { size = "t3.large",  min = 0, max = 2, desired = 0, spot = true,
             labels = { workload = "bench" } }
}
```

`size` is an EC2 instance type on EKS and a VM size on AKS. On AKS the
`system` pool is always on-demand because system pools cannot be spot.

## Outputs (both modules)

| Output | Notes |
|---|---|
| `cluster_name` | |
| `cluster_endpoint` | HTTPS URL of the API server |
| `cluster_ca_certificate` | PEM, base64-decoded |
| `oidc_issuer_url` | For workload identity federation (IRSA / Entra workload identity) and for cosign/SPIRE OIDC discovery experiments |
| `kubeconfig` | Exec-based kubeconfig; contains no static credentials |
| `node_pools` | Effective pool settings after cloud-specific adjustments |
