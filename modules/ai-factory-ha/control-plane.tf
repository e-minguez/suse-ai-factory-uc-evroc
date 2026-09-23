# The control-plane VMs: one boot disk cloned from the built snapshot, one
# optional public IP, and the VM itself, keyed throughout by hostname so a
# growing pool never renumbers an existing node.
#
# Each node carries its own zone (locals.tf's control_plane_nodes assigns them
# round-robin across var.zones), and everything zonal about it follows from
# that one field: its disk is created in that zone, it clones THAT ZONE's
# snapshot, it attaches to that zone's subnet, and it joins that zone's
# placement group. Every zone's snapshot holds the same image -- built
# separately per zone because evroc snapshots cannot cross one, and checked for
# byte equality by scripts/wait-for-image.sh.

locals {
  # Gates whether ANY control-plane resource exists at all: var.deploy_nodes
  # is the operator's own on/off switch, and there is nothing to clone a boot
  # disk from before a snapshot exists.
  #
  # local.snapshot_expected, NOT local.effective_snapshot_ids[z] != null. Both
  # terms of this expression must be plan-known or the map below is unknown
  # and for_each cannot evaluate -- see snapshot.tf's comment on
  # snapshot_expected for the full failure, which takes `terraform destroy`
  # down with it.
  control_plane_deploy_gate = var.deploy_nodes && local.snapshot_expected

  # {} when the gate above is false -- otherwise every hostname in
  # local.control_plane_nodes. These KEYS are derived purely from
  # var.cluster_name and var.control_plane_count, both plan-known, and NEVER
  # from anything that touches the (apply-time) snapshot id -- the ID is a
  # resource ATTRIBUTE below, which is fine, but it must not reach this map.
  # That is what keeps for_each's key set stable across the
  # image-build/deploy sequencing: a plan taken before the snapshot exists
  # proposes CREATING these nodes once it does, rather than looking identical
  # to a plan taken after and then proposing to destroy and recreate the whole
  # control plane the moment something notices the difference.
  control_plane_nodes_map = local.control_plane_deploy_gate ? {
    for node in local.control_plane_nodes : node.hostname => node
  } : {}
}

resource "evroc_disk" "control_plane" {
  for_each = local.control_plane_nodes_map

  name = "${each.key}-boot"
  # Same zone as the VM below -- a VM can only boot a disk in its own zone.
  zone = each.value.zone
  # Indexed by the node's OWN zone, not a single cluster-wide snapshot: evroc
  # refuses to create a disk in zone X from a snapshot belonging to zone Y.
  snapshot = local.effective_snapshot_ids[each.value.zone]
  size     = var.node_disk_gb
  project  = var.project
  region   = var.region

  # build_labels: this disk is a CLONE of one build's snapshot, and the
  # snapshot it came from cannot be labelled at all (evroc_snapshot exposes no
  # user_labels -- see snapshot.tf), so this is where the image generation
  # becomes visible on a node's storage.
  user_labels = merge(local.build_labels, { "role" = "control-plane" })

  timeouts {
    create = var.disk_create_timeout
    delete = var.disk_delete_timeout
  }
}

resource "evroc_public_ip" "control_plane" {
  for_each = var.control_plane_public_ip ? local.control_plane_nodes_map : {}

  name    = "${each.key}-ip"
  project = var.project
  region  = var.region

  # common_labels, not build_labels: an address is not part of an image
  # generation, and it survives the node being rebuilt onto a newer one.
  user_labels = merge(local.common_labels, { "role" = "control-plane" })
}

resource "evroc_virtual_machine" "control_plane" {
  for_each = local.control_plane_nodes_map

  name    = each.key
  flavor  = var.control_plane_flavor
  zone    = each.value.zone
  project = var.project
  region  = var.region

  boot_disk       = evroc_disk.control_plane[each.key].name
  security_groups = [evroc_security_group.control_plane.fqid]
  # Both looked up by the node's own zone. The placement group constrains
  # placement WITHIN a zone (no two of this zone's members on one host); the
  # zone spread across nodes is what survives losing a zone outright. The
  # security group is regional and shared by every control-plane node.
  placement_group = evroc_placement_group.control_plane[each.value.zone].fqid
  subnet_ref      = evroc_subnet.this[each.value.zone].fqid
  public_ip       = try(evroc_public_ip.control_plane[each.key].name, null)

  # Per-node Ignition -- hostname, IS_INIT_NODE/NODETYPE -- see locals.tf's
  # node_runtime_ignition for what actually rides in here and why the node's
  # role is declared there and nowhere else.
  cloud_config_user_data = local.node_runtime_ignition[each.key]

  # THE elemental image is EFI-only: GRUB is installed into the ESP and
  # nothing anywhere writes a BIOS boot sector. Without this label the VM
  # boots BIOS instead, finds no bootloader to hand off to, and evroc reports
  # it as "Running" forever -- it never crashes, never reboots, and never
  # answers SSH, RKE2, or anything else. That reads exactly like a broken
  # image, not a missing platform flag, which is what makes it worth this
  # much comment.
  #
  # The "compute-experimental-features-" prefix means this is NOT a stable,
  # documented attribute -- it is a feature flag, and it can change or vanish
  # on a provider upgrade with no deprecation notice.
  #
  # Merged over build_labels rather than common_labels, so a node also carries
  # the image generation it was booted from. That is the fastest way to catch
  # the failure where a rebuild replaced the snapshot but some node was left
  # standing on the old one.
  user_labels = merge(local.build_labels, {
    "role"                               = "control-plane"
    "compute-experimental-features-UEFI" = "true"
  })

  lifecycle {
    precondition {
      # evroc caps cloud_config_user_data at 1 MB, because the VM is a KubeVirt
      # object and the user data is a field in it (confirmed 2026-09-22) --
      # local.user_data_max_bytes explains why the check sits under that rather
      # than at it. Node Ignition is ~15 KB today, so this is a guard against a
      # future template that inlines something large (a manifest, a values
      # file, a certificate bundle) rather than a limit anyone is near.
      #
      # A PRECONDITION, not a postcondition: a postcondition here would
      # reference `self`, and `self` is still evaluated when the VM fails to
      # create, which turns one real API error into three. See checks.tf.
      #
      # nonsensitive() on the length alone: the payload is built from sensitive
      # inputs so its byte count inherits that, and a count that cannot be
      # printed makes the error useless.
      condition     = length(local.node_runtime_ignition[each.key]) <= local.user_data_max_bytes
      error_message = "Rendered Ignition for ${each.key} is ${nonsensitive(length(local.node_runtime_ignition[each.key]))} bytes, over the ${local.user_data_max_bytes}-byte ceiling evroc's 1 MB user-data limit leaves once base64 expansion is accounted for."
    }
  }
}

locals {
  # The load balancer's own backend pool (loadbalancer.tf) reads this
  # directly as backend_refs. Empty list -- not an error -- on a
  # deploy_nodes = false or pre-snapshot plan.
  control_plane_fqids = [for vm in evroc_virtual_machine.control_plane : vm.fqid]
}
