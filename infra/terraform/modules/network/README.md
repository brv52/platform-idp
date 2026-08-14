# network

Two implementations behind the same shape of interface, one per cloud, so an
environment root only ever configures the provider it uses.

| | `aws/` | `azure/` |
|---|---|---|
| Address space | VPC `cidr` | VNet `cidr` |
| Cluster subnets | private subnets in `az_count` AZs | one node subnet |
| Egress | `nat_mode = "single"` (one NAT GW) or `"none"` (nodes in public subnets) | AKS-managed load balancer outbound |
| Output used by clusters | `node_subnet_ids` | `node_subnet_ids` |

Both modules output `network_id`, `node_subnet_ids` and `cidr`.
