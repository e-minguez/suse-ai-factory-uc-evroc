# Mirrors modules/ai-factory-ha's public surface so terraform.tfvars has
# something to set. Descriptions here are short pointers, not the full
# explanation -- the module's own variables.tf carries the validations and
# the "why", and is the authoritative reference.

variable "region" {
  type        = string
  default     = null
  description = "evroc region. null defers to the provider's own configured region."
}

variable "zones" {
  type        = list(string)
  default     = ["a", "b", "c"]
  description = "evroc zones the cluster spans. One subnet and one control-plane placement group per zone; control-plane nodes are assigned round-robin across the list. The jumphost and the image-target disk stay in zones[0]. Use a single-element list for a single-AZ cluster."
}

variable "project" {
  type        = string
  default     = null
  description = "evroc project. null defers to the provider's own configured project."
}

variable "elemental_image" {
  type        = string
  default     = "registry.suse.com/beta/uc/elemental:3.1.0-6.5"
  description = "Container image `podman run ... customize` runs on the jumphost."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the jumphost on 22/tcp, and on status_relay_port during pass 1. Must include the address terraform runs from. No default."
}

variable "root_password_hash" {
  type        = string
  sensitive   = true
  description = "Root password hash baked into the image (e.g. `openssl passwd -6`)."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "Public keys injected onto every node's SSH-capable account."
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login on every elemental node (no sudo -- use `su -`)."
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Password hash for node_username. Must differ from root_password_hash."
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Whether sshd on elemental nodes accepts root logins."
}

variable "appco_username" {
  type        = string
  sensitive   = true
  description = "SUSE Application Collection username."
}

variable "appco_password" {
  type        = string
  sensitive   = true
  description = "SUSE Application Collection password/token."
}

variable "appco_registry" {
  type        = string
  default     = "dp.apps.rancher.io"
  description = "Registry host the local-path-provisioner image pull secret authenticates against."
}

variable "suse_registration_code" {
  type        = string
  sensitive   = true
  description = "SUSE registration code (used as the SUSE registry \"username\")."
}

variable "suse_registry_password" {
  type        = string
  sensitive   = true
  description = "Password paired with suse_registration_code."
}

variable "nvidia_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NVIDIA NGC API key. null omits the nvidia: credentials block entirely."
}

# Leave both at null until SUSE publishes SLES 16.1 precompiled drivers under
# registry.suse.com/third-party/nvidia. null takes the module's default: an
# experimental OBS build of branch 615, the only driver known to load on these
# nodes' 16.1 kernel. See the top-level README.
variable "gpu_driver_repository" {
  type        = string
  default     = null
  description = "GPU operator driver.repository. Do not change until a supported SLES 16.1 driver is released; null uses the module's experimental default."
}

variable "gpu_driver_version" {
  type        = string
  default     = null
  description = "GPU operator driver.version. Do not change until a supported SLES 16.1 driver is released; null uses the module's default (615)."
}

variable "components" {
  type        = list(string)
  default     = ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
  description = "SUSE AI Factory Helm charts to enable. Changing this rebuilds the image."
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Rancher ingress hostname. null defaults to rancher-<api_vip>.sslip.io."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin password. null generates one."
}

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix for resource labels and node hostnames."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "IPv4 CIDR of the cluster VPC. Must not overlap RKE2's cluster/service CIDRs."
}

variable "subnet_newbits" {
  type        = number
  default     = 4
  description = "Bits added to vpc_cidr's prefix when carving one subnet per zone: zones[i] gets cidrsubnet(vpc_cidr, subnet_newbits, i). The default turns a /16 VPC into /20 subnets. See the subnet_cidrs output for the result."
}

variable "vpc_mtu" {
  type        = number
  default     = 8900
  description = "MTU on the VPC network adapters. 8900 is what evroc actually hands out. Pod veth MTU follows as vpc_mtu - 50."
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of control-plane VM nodes. Must stay odd and at least 3."
}

variable "control_plane_flavor" {
  type        = string
  default     = "c1a.m"
  description = "evroc compute profile for control-plane VMs."
}

variable "jumphost_flavor" {
  type        = string
  default     = "a1a.m"
  description = "evroc compute profile for every build host -- the jumphost and, on a multi-zone cluster, one builder per remaining zone. Multiplies by the zone count, so it is sized against a default project's 20 vCPU quota; see the module variable of the same name."
}

variable "gpu_pools" {
  type = map(object({
    flavor             = string
    count              = optional(number, 1)
    zone               = optional(string)
    placement_strategy = optional(string)
  }))
  default     = {}
  description = "GPU worker pools, keyed by pool name. Empty by default (control-plane-only cluster). Optionally per pool: zone pins the pool to one zone (default: round-robin across the GPU-capable zones in gpu_zones, which today means zone a alone), and placement_strategy is \"spread\" (anti-affinity, for inference) or \"cluster\" (affinity, for training collectives) -- omitted means no placement group at all. GPU quota is counted per GPU MODEL and a default project holds one; count above that fails at apply time, not at plan."
}

variable "gpu_zones" {
  type        = list(string)
  default     = ["a"]
  description = "Zones where evroc permits GPU VMs at all -- its virtualmachine-webhook rejects the rest outright (\"GPU VMs are currently only supported on zone a\"). Unpinned gpu_pools are spread over these zones only. Widen it when evroc does."
}

variable "jumphost_disk_gb" {
  type        = number
  default     = 200
  description = "Size, in GB, of the jumphost's own boot disk."
}

variable "image_target_disk_gb" {
  type        = number
  default     = 32
  description = "Size, in GB, of the blank disk the raw elemental image is built onto."
}

variable "node_disk_gb" {
  type        = number
  default     = 200
  description = "Size, in GB, of the boot disk cloned from the snapshot for every node."
}

variable "image_ready" {
  type        = bool
  default     = false
  description = "Sequencing flag for the two-pass apply -- set by deploy.sh, not by hand."
}

variable "retain_image_target_disks" {
  type        = bool
  default     = true
  description = "Whether to keep the image-target disks once their snapshots exist. Set to false by deploy.sh's pass 3, in an apply of its own -- not by hand, and never in the same apply that creates the snapshots."
}

variable "disk_create_timeout" {
  type        = string
  default     = "30m"
  description = "How long to wait for any evroc_disk to report Ready. The provider defaults to 10 minutes, which a 200 GB disk in a busy zone has been seen to exceed -- and a timeout taints the disk, so the next apply pays the provisioning time again from scratch."
}

variable "disk_delete_timeout" {
  type        = string
  default     = "20m"
  description = "How long to wait for an evroc_disk to be deleted. Same 10-minute provider default as create, and the disk most likely to need longer is one that got wedged during provisioning."
}

variable "control_plane_public_ip" {
  type        = bool
  default     = false
  description = "Whether each control-plane node also gets its own public IP. Not needed for anything: the API and ingress arrive via the load balancer VIP, and egress works without one through evroc's shared NAT gateways. Public IPs are also quota'd at 3 on a default project, two of which this module already spends on the VIP and the jumphost."
}

variable "gpu_public_ip" {
  type        = bool
  default     = false
  description = "Whether each GPU worker node gets its own public IP. Same as control_plane_public_ip: egress works without one, and a GPU node with no address is reachable only from inside the VPC."
}

variable "user_labels" {
  type        = map(string)
  default     = {}
  description = "Extra labels merged onto every resource this module creates, on top of the cluster/managed-by/module/created set and the per-resource role it applies anyway. Merged last, so a key here overrides the module's own. Kubernetes label syntax -- no colons, 63 characters max."
}

variable "jumphost_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login on the jumphost, with passwordless sudo. \"\" for root-only."
}

variable "jumphost_image" {
  type        = string
  default     = null
  description = "evroc disk image for the jumphost's boot disk. null defaults to openSUSE Leap 15.6."
}

variable "ingress_controller" {
  type        = string
  default     = "traefik"
  description = "RKE2's ingress-controller setting: \"traefik\", \"ingress-nginx\" or \"none\"."
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress listeners (80/443) on the load balancer."
}

variable "api_host" {
  type        = string
  default     = null
  description = "DNS name for the Kubernetes API, added to the server certificate's SANs."
}

variable "api_vip_mode" {
  type        = string
  default     = "external"
  description = "Elemental network.apiVIPMode: \"external\" (this module's load balancer) or \"managed\"."
}

variable "aif_version" {
  type        = string
  default     = "2.2.0"
  description = "SUSE AI Factory version, resolved to the SUSE/aif tag aif-operator-<version>."
}

variable "aif_release_manifest_url" {
  type        = string
  default     = null
  description = "Overrides aif_version entirely with a manifest URL of your own."
}

# Mirrors the module's own default rather than defaulting to null, because
# main.tf passes this straight through: a null here would override the module
# default and put the build back on AIF 2.2's GA 16.0 OS image, whose
# elemental3ctl ignores initrdExtensions and yields a node with no Kubernetes.
variable "core_platform_override" {
  type = object({
    os_image_base      = string
    os_image_iso       = string
    kubernetes_version = string
    kubernetes_image   = string
  })
  default = {
    os_image_base      = "registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2"
    os_image_iso       = "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-73.3"
    kubernetes_version = "v1.35.6+rke2r1"
    kubernetes_image   = "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1"
  }
  description = "Pins OS/Kubernetes images directly instead of following the release manifest's corePlatform.image. The default is the beta 16.1 OS image; see the module variable for why that is not optional."
}

variable "sysext_image_overrides" {
  type = map(string)
  default = {
    suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13"
  }
  description = "Per-extension OCI image overrides applied to the release manifest before the build."
}

variable "image_disk_size" {
  type        = string
  default     = "8G"
  description = "install.yaml raw.diskSize -- size of the built raw image, not the running node's disk."
}

variable "fips" {
  type        = bool
  default     = false
  description = "Whether install.yaml sets cryptoPolicy: fips."
}

variable "snapshot_ids" {
  type        = map(string)
  default     = {}
  description = "Override: use already-existing evroc snapshots instead of building any. Keyed by zone, with an entry for every zone in var.zones -- evroc snapshots are zonal, so there is no single id that serves a multi-zone cluster. Only for adopting snapshots this module did not build; deploy.sh never writes it."
}

variable "deploy_nodes" {
  type        = bool
  default     = true
  description = "Whether to provision the control-plane and GPU nodes."
}

variable "image_build_timeout" {
  type        = number
  default     = 5400
  description = "Seconds the image-build wait will poll before giving up."
}

variable "status_relay_port" {
  type        = number
  default     = 8080
  description = "Port of the build-status relay on the jumphost, which the image-build wait polls. Open to admin_cidrs during pass 1 only."
}

variable "verify_flavor_availability" {
  type        = bool
  default     = true
  description = "Whether to pre-flight-check requested flavors against the live evroc API during plan."
}
