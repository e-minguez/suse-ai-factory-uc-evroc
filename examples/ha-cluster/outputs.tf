output "jumphost_public_ipv4" {
  description = "Public IPv4 of the jumphost/image factory -- the only inbound admin path into the cluster."
  value       = module.ai_factory.jumphost_public_ipv4
}

output "jumphost_ssh_login" {
  description = "SSH login for the jumphost: jumphost_username if set, root otherwise."
  value       = module.ai_factory.jumphost_ssh_login
}

output "api_vip" {
  description = "The dedicated public IP fronting the Kubernetes API through the load balancer."
  value       = module.ai_factory.api_vip
}

output "api_host" {
  description = "DNS name for the Kubernetes API, present in the API server certificate's SANs."
  value       = module.ai_factory.api_host
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API endpoint, fronted by the load balancer at api_vip."
  value       = module.ai_factory.kubernetes_api_endpoint
}

output "ingress_endpoint" {
  description = "URL the cluster's Ingress resources are reachable on. Shares api_vip -- there is no separate ingress address. null when ingress_controller is \"none\"."
  value       = module.ai_factory.ingress_endpoint
}

output "rancher_hostname" {
  description = "Hostname Rancher's ingress is configured for. null when \"rancher\" is not in components."
  value       = module.ai_factory.rancher_hostname
}

output "rancher_url" {
  description = "Rancher's UI. null when \"rancher\" is not in components."
  value       = module.ai_factory.rancher_url
}

output "rancher_bootstrap_password" {
  description = "Rancher's initial admin bootstrap password. null when \"rancher\" is not in components."
  value       = module.ai_factory.rancher_bootstrap_password
  sensitive   = true
}

output "rke2_token" {
  description = "Shared RKE2 join token baked into every node's config."
  value       = module.ai_factory.rke2_token
  sensitive   = true
}

output "snapshot_ids" {
  description = "The evroc snapshot each zone's nodes were (or will be) provisioned from, keyed by zone -- one per zone, because evroc snapshots cannot be cloned across zones. Values are null before a build completes."
  value       = module.ai_factory.snapshot_ids
}

output "image_target_disk_names" {
  description = "Name of the blank disk each zone's build host writes the elemental image onto, keyed by zone."
  value       = module.ai_factory.image_target_disk_names
}

output "builder_private_ips" {
  description = "VPC addresses of the non-primary build hosts, keyed by zone, while they exist -- pass 2 destroys them to free vCPU quota for the nodes. Empty for a single-zone cluster. Reach one with `ssh -J $(terraform output -raw jumphost_ssh_login) <jumphost_username>@<ip>`."
  value       = module.ai_factory.builder_private_ips
}

output "control_plane_names" {
  description = "Names of the control-plane VMs. Empty on a deploy_nodes = false plan."
  value       = module.ai_factory.control_plane_names
}

output "control_plane_fqids" {
  description = "FQIDs of the control-plane VMs, as referenced by the load balancer's backend pool."
  value       = module.ai_factory.control_plane_fqids
}

output "control_plane_private_ips" {
  description = "VPC addresses of the control-plane nodes."
  value       = module.ai_factory.control_plane_private_ips
}

output "control_plane_public_ips" {
  description = "Public IPv4 addresses of the control-plane nodes, when control_plane_public_ip is true."
  value       = module.ai_factory.control_plane_public_ips
}

output "gpu_node_names" {
  description = "Names of the GPU worker VMs, across every pool in gpu_pools."
  value       = module.ai_factory.gpu_node_names
}

output "gpu_node_private_ips" {
  description = "VPC addresses of the GPU worker nodes, across every pool."
  value       = module.ai_factory.gpu_node_private_ips
}

output "gpu_node_public_ips" {
  description = "Public IPv4 addresses of the GPU worker nodes that have one."
  value       = module.ai_factory.gpu_node_public_ips
}

output "gpu_quota_request" {
  description = "GPUs and vCPUs the configured gpu_pools will request, per pool and summed per GPU model. Known at plan time, so it shows in the plan diff before the apply that would be denied."
  value       = module.ai_factory.gpu_quota_request
}

output "vpc_cidr" {
  description = "CIDR of the cluster VPC."
  value       = module.ai_factory.vpc_cidr
}

output "subnet_cidrs" {
  description = "CIDR of each zone's subnet, keyed by zone."
  value       = module.ai_factory.subnet_cidrs
}

output "node_zones" {
  description = "Zone each node was placed in, keyed by hostname. Confirms the control plane spans the zones it was meant to."
  value       = module.ai_factory.node_zones
}

output "security_group_names" {
  description = "Names of every security group this module creates."
  value       = module.ai_factory.security_group_names
}

