output "jumphost_public_ipv4" {
  description = "Public IPv4 of the jumphost/image factory -- the only inbound admin path into the cluster. null on a deploy_nodes = false plan before the jumphost has been created."
  value       = try(evroc_virtual_machine.jumphost.public_ipv4_address, null)
}

output "jumphost_ssh_login" {
  description = "SSH login for the jumphost: jumphost_username if set, root otherwise."
  value       = "${var.jumphost_username != "" ? var.jumphost_username : "root"}@${try(evroc_virtual_machine.jumphost.public_ipv4_address, "")}"
}

output "api_vip" {
  description = "The dedicated public IP address -- baked into every node's elemental config as network.apiVIP -- that fronts the Kubernetes API through this module's load balancer."
  value       = local.api_vip
}

output "api_host" {
  description = "DNS name for the Kubernetes API, baked in as network.apiHost and therefore present in the API server certificate's SANs. Defaults to rke2-<api_vip>.sslip.io."
  value       = local.api_host
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API endpoint, fronted by the load balancer at api_vip. Reachable once RKE2 is up and the load balancer has healthy backends."
  value       = "https://${local.api_vip}:6443"
}

output "ingress_endpoint" {
  description = "URL the cluster's Ingress resources are reachable on. evroc's single load balancer answers the ingress ports on the same address as the API -- see api_vip -- so this is that address with an https:// scheme. null when ingress_controller is \"none\"."
  value       = var.ingress_controller == "none" ? null : "https://${local.api_vip}"
}

output "rancher_hostname" {
  description = "Hostname Rancher's ingress is configured for -- var.rancher_hostname if set, otherwise rancher-<api_vip>.sslip.io. null when \"rancher\" is not in var.components -- nothing serves this hostname then."
  value       = contains(local.enabled_components, "rancher") ? local.rancher_hostname : null
}

output "rancher_url" {
  description = "Rancher's UI. Serves an ingress-generated self-signed certificate unless cert-manager was given a real issuer. null when \"rancher\" is not in var.components."
  value       = contains(local.enabled_components, "rancher") ? "https://${local.rancher_hostname}" : null
}

output "rancher_bootstrap_password" {
  description = "Rancher's initial admin bootstrap password -- var.rancher_bootstrap_password if set, otherwise a generated one. null when \"rancher\" is not in var.components."
  value       = contains(local.enabled_components, "rancher") ? local.rancher_bootstrap_password : null
  sensitive   = true
}

output "rke2_token" {
  description = "Shared RKE2 join token baked into every node's kubernetes/config/{server,agent}.yaml."
  value       = random_password.token.result
  sensitive   = true
}

output "snapshot_ids" {
  description = "The evroc snapshot each zone's nodes were (or will be) provisioned from, keyed by zone -- either the ones this module built or var.snapshot_ids if that override was set. One per zone because evroc snapshots are zonal and a node disk cannot clone one belonging to another zone. Values are null before a build completes."
  value       = local.effective_snapshot_ids
}

output "image_target_disk_names" {
  description = "Name of the blank disk each zone's build host writes the elemental image onto, and which that zone's evroc_snapshot is taken from, keyed by zone. The NAME, not a claim the disk exists: with retain_image_target_disks = false these are reclaimed once the snapshots are made, and a later rebuild recreates them under the same names."
  value       = local.image_target_disk_names
}

output "builder_private_ips" {
  description = "VPC addresses of the non-primary build hosts, keyed by zone. These have no public IP -- reach one with `ssh -J <jumphost_ssh_login> <jumphost_username>@<ip>`. Empty in three cases: a single-zone cluster, which has no builders; any plan before they are created; and, normally, AFTER pass 2, which destroys them to free vCPU quota for the nodes."
  value       = { for z, vm in evroc_virtual_machine.builder : z => vm.private_ipv4_address }
}

# Every node resource below is for_each'd by hostname, not count'd, so these
# iterate with a `for` expression rather than a [*] splat. The splat form is
# not merely wrong style here -- applied to a for_each resource it is an error,
# and wrapping it in try() does not surface that error, it swallows it and
# hands back the fallback. Written that way these outputs would be empty
# forever, on a fully deployed cluster, with nothing to indicate why.
#
# sort() keeps the ordering stable across plans: for_each yields map order,
# and the hostnames are zero-padded (cp-01, cp-02, ...) so lexical order is
# also numeric order.
output "control_plane_names" {
  description = "Names of the control-plane VMs. Empty on a deploy_nodes = false plan."
  value       = sort([for vm in evroc_virtual_machine.control_plane : vm.name])
}

output "control_plane_fqids" {
  description = "FQIDs of the control-plane VMs -- the load balancer's own backend pool references these. Empty on a deploy_nodes = false plan."
  value       = local.control_plane_fqids
}

output "control_plane_private_ips" {
  description = "VPC addresses of the control-plane nodes. Empty on a deploy_nodes = false plan."
  value       = sort([for vm in evroc_virtual_machine.control_plane : vm.private_ipv4_address])
}

# compact() over a null-to-"" conversion written as an explicit conditional, NOT
# as coalesce(x, ""). coalesce rejects empty strings as well as nulls, so on a
# node with no public IP -- where the provider returns "" rather than null --
# BOTH arguments are invalid and it fails the whole apply with "no non-null,
# non-empty-string arguments". It fails at output-evaluation time, after every
# resource has been created, which makes it look like a deployment failure when
# nothing is actually wrong with the cluster.
output "control_plane_public_ips" {
  description = "Public IPv4 addresses of the control-plane nodes, when var.control_plane_public_ip is true. Empty when it is false or on a deploy_nodes = false plan."
  value       = sort(compact([for vm in evroc_virtual_machine.control_plane : vm.public_ipv4_address == null ? "" : vm.public_ipv4_address]))
}

output "gpu_node_names" {
  description = "Names of the GPU worker VMs, across every pool in var.gpu_pools. Empty when no pool is configured or on a deploy_nodes = false plan."
  value       = sort([for vm in evroc_virtual_machine.gpu : vm.name])
}

output "gpu_node_private_ips" {
  description = "VPC addresses of the GPU worker nodes, across every pool. Empty when no pool is configured or on a deploy_nodes = false plan."
  value       = sort([for vm in evroc_virtual_machine.gpu : vm.private_ipv4_address])
}

output "gpu_node_public_ips" {
  description = "Public IPv4 addresses of the GPU worker nodes that have one. Empty when var.gpu_public_ip is false, when no pool is configured, or on a deploy_nodes = false plan."
  value       = sort(compact([for vm in evroc_virtual_machine.gpu : vm.public_ipv4_address == null ? "" : vm.public_ipv4_address]))
}

output "gpu_quota_request" {
  description = "What the GPU pools will ask the admission webhook for, known at PLAN time: per pool the flavor, GPU model, total GPUs (count * the flavor's gpu_quantity) and total vCPUs, plus the per-model totals the quota is actually held against. The quota itself is not queryable, so compare these numbers with the project's GPU allowance before applying -- exceeding it is an apply-time denial after the boot disks already exist."
  value = {
    by_pool  = local.gpu_pool_demand
    by_model = local.gpu_demand_by_model
  }
}

output "vpc_cidr" {
  description = "CIDR of the cluster VPC."
  value       = local.vpc_cidr
}

output "subnet_cidrs" {
  description = "CIDR of each zone's subnet, keyed by zone. Derived from vpc_cidr and subnet_newbits rather than supplied, so this is the readable form of what that arithmetic produced."
  value       = local.subnet_cidrs
}

output "node_zones" {
  description = "Zone each node was placed in, keyed by hostname -- control-plane nodes round-robin across var.zones, GPU nodes either pinned by their pool or round-robin the same way. Empty on a deploy_nodes = false plan. Read this to confirm the control plane actually spans the zones it was meant to before trusting the cluster to survive losing one."
  value = merge(
    { for vm in evroc_virtual_machine.control_plane : vm.name => vm.zone },
    { for vm in evroc_virtual_machine.gpu : vm.name => vm.zone },
  )
}

output "security_group_names" {
  description = "Names of every security group this module creates: jumphost and control-plane always, builder only in a multi-zone cluster, gpu only when at least one pool in var.gpu_pools exists."
  value = concat(
    [evroc_security_group.jumphost.name, evroc_security_group.control_plane.name],
    evroc_security_group.builder[*].name,
    evroc_security_group.gpu[*].name,
  )
}

