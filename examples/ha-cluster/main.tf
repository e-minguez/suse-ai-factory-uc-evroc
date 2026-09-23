# Thin pass-through: every variable here has a matching one in the module,
# so this example's only job is to expose them as a terraform.tfvars surface.
# See variables.tf for the (lightly documented) list and
# modules/ai-factory-ha/variables.tf for the full explanation of each.
module "ai_factory" {
  source = "../../modules/ai-factory-ha"

  region  = var.region
  zones   = var.zones
  project = var.project

  elemental_image     = var.elemental_image
  admin_cidrs         = var.admin_cidrs
  root_password_hash  = var.root_password_hash
  ssh_authorized_keys = var.ssh_authorized_keys

  node_username           = var.node_username
  node_user_password_hash = var.node_user_password_hash
  permit_root_ssh         = var.permit_root_ssh

  appco_username             = var.appco_username
  appco_password             = var.appco_password
  appco_registry             = var.appco_registry
  suse_registration_code     = var.suse_registration_code
  suse_registry_password     = var.suse_registry_password
  nvidia_api_key             = var.nvidia_api_key
  components                 = var.components
  rancher_hostname           = var.rancher_hostname
  rancher_bootstrap_password = var.rancher_bootstrap_password

  cluster_name   = var.cluster_name
  vpc_cidr       = var.vpc_cidr
  subnet_newbits = var.subnet_newbits
  vpc_mtu        = var.vpc_mtu

  control_plane_count  = var.control_plane_count
  control_plane_flavor = var.control_plane_flavor

  gpu_pools = var.gpu_pools
  gpu_zones = var.gpu_zones

  jumphost_flavor   = var.jumphost_flavor
  jumphost_disk_gb  = var.jumphost_disk_gb
  jumphost_username = var.jumphost_username
  jumphost_image    = var.jumphost_image

  image_target_disk_gb = var.image_target_disk_gb
  node_disk_gb         = var.node_disk_gb

  control_plane_public_ip = var.control_plane_public_ip
  gpu_public_ip           = var.gpu_public_ip
  user_labels             = var.user_labels

  ingress_controller = var.ingress_controller
  ingress_cidrs      = var.ingress_cidrs

  api_host     = var.api_host
  api_vip_mode = var.api_vip_mode

  aif_version              = var.aif_version
  aif_release_manifest_url = var.aif_release_manifest_url
  core_platform_override   = var.core_platform_override
  sysext_image_overrides   = var.sysext_image_overrides
  image_disk_size          = var.image_disk_size
  fips                     = var.fips

  # image_ready sequences the two passes; deploy.sh sets it through
  # pass2.auto.tfvars.json (auto-loaded by Terraform), not by editing
  # terraform.tfvars. snapshot_ids is a separate, operator-set override
  # meaning "skip the build, adopt these EXTERNALLY-owned snapshots" -- never
  # point it at the snapshots this module built, which would destroy them out
  # from under the node disks. See deploy.sh and this example's README.
  #
  # retain_image_target_disks arrives the same way, from pass 3. It has to be
  # declared here even though nothing but deploy.sh ever sets it: a value in an
  # auto-loaded tfvars file for a variable the ROOT module does not declare is
  # a warning, not an error, and is silently ignored.
  image_ready               = var.image_ready
  snapshot_ids              = var.snapshot_ids
  retain_image_target_disks = var.retain_image_target_disks
  disk_create_timeout       = var.disk_create_timeout
  disk_delete_timeout       = var.disk_delete_timeout

  deploy_nodes = var.deploy_nodes

  image_build_timeout        = var.image_build_timeout
  verify_flavor_availability = var.verify_flavor_availability
}
