# A GPU flavor used to require spec.source.diskImageRef on its boot disk, which
# a snapshot clone cannot carry, so every VM below failed to create with
#
#   Ready: disk is missing DiskImageRef (ProvisioningFailed)
#
# evroc lifted that on 2026-09-23 and a gn-l40s.s node now boots this module's
# own snapshot. Recorded because the code is unchanged either way -- if this
# error ever comes back, it is a platform-side rule and not something to debug
# in here. Building GPU workers from a stock image and joining them to RKE2
# separately was considered as a workaround and deliberately NOT implemented:
# it would have been a second, permanent node path outside the immutable
# elemental image. PLATFORM-NOTES.md has the detail.
#
# GPU worker VMs, across every pool in var.gpu_pools -- same shape as
# control-plane.tf (boot disk cloned from the built snapshot, a public IP, the
# VM), with two differences in how they are placed.
#
# ZONE. A pool either pins one (gpu_pools[*].zone) or spreads round-robin
# across var.zones like the control plane does. Pinning is the common case in
# practice: GPU stock for a given flavor tends to exist in one zone, and
# leaving it unpinned surfaces that as an out-of-capacity failure on whichever
# nodes happened to land elsewhere.
#
# PLACEMENT GROUP. Optional and per pool (gpu_pools[*].placement_strategy),
# where the control plane always gets "spread". There is no single right answer
# for GPU workers -- an inference pool wants anti-affinity, a training pool
# wants the opposite -- so the default is no group at all, which leaves the
# scheduler unconstrained rather than imposing a guess.
#
# PUBLIC IP. Toggled by var.gpu_public_ip, separately from the control plane's
# own toggle, because the two are not equivalent. This design has no NAT
# gateway (locals.tf's own comment on that), so a public IP is the only route
# out a node has -- and a GPU node needs one more than most, since the GPU
# operator's driver containers are pulled at runtime. A control-plane node
# denied a public IP is still reachable through the load balancer; a GPU node
# denied one is reachable only from inside the VPC. Both lose egress.

locals {
  # Same gate as control-plane.tf, for the same reason: nothing to clone a
  # boot disk from before a snapshot exists, and var.deploy_nodes is the
  # operator's own on/off switch for provisioning nodes at all.
  #
  # snapshot_expected rather than a test on the snapshot id itself -- see
  # snapshot.tf for why that distinction decides whether this configuration
  # can be planned (or destroyed) at all.
  gpu_nodes_deploy_gate = var.deploy_nodes && local.snapshot_expected

  # {} when the gate above is false -- otherwise every hostname in
  # local.gpu_nodes. Keyed by hostname, never by index or pool position, for
  # the same reason as control_plane_nodes_map: these keys come only from
  # var.cluster_name/var.gpu_pools (plan-known), never from the snapshot id,
  # so a plan taken before the snapshot exists proposes CREATING these nodes
  # once it does, not replacing them.
  gpu_nodes_map = local.gpu_nodes_deploy_gate ? {
    for node in local.gpu_nodes : node.hostname => node
  } : {}
}

resource "evroc_disk" "gpu" {
  for_each = local.gpu_nodes_map

  name = "${each.key}-boot"
  # Same zone as the VM below -- a VM can only boot a disk in its own zone.
  zone = each.value.zone
  # Indexed by the node's OWN zone, not a single cluster-wide snapshot: evroc
  # refuses to create a disk in zone X from a snapshot belonging to zone Y.
  snapshot = local.effective_snapshot_ids[each.value.zone]
  size     = var.node_disk_gb
  project  = var.project
  region   = var.region

  # build_labels plus the pool -- same reasoning as control-plane.tf's boot
  # disk, with `pool` added because several pools' disks are otherwise
  # indistinguishable once cloned.
  user_labels = merge(local.build_labels, {
    "role" = "gpu"
    "pool" = each.value.pool
  })

  timeouts {
    create = var.disk_create_timeout
    delete = var.disk_delete_timeout
  }
}

resource "evroc_public_ip" "gpu" {
  for_each = var.gpu_public_ip ? local.gpu_nodes_map : {}

  name    = "${each.key}-ip"
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, {
    "role" = "gpu"
    "pool" = each.value.pool
  })
}

resource "evroc_virtual_machine" "gpu" {
  for_each = local.gpu_nodes_map

  name    = each.key
  flavor  = each.value.flavor
  zone    = each.value.zone
  project = var.project
  region  = var.region

  boot_disk = evroc_disk.gpu[each.key].name
  # one(): evroc_security_group.gpu exists (count = 1) exactly when
  # var.gpu_pools is non-empty (security-groups.tf) -- which is also the only
  # time gpu_nodes_map is non-empty, so this is never evaluated against an
  # absent group.
  security_groups = [one(evroc_security_group.gpu[*].fqid)]
  subnet_ref      = evroc_subnet.this[each.value.zone].fqid
  # try(): the IP resource only exists when var.gpu_public_ip is true, and
  # null is the provider's "no public IP" -- same shape as control-plane.tf.
  public_ip = try(evroc_public_ip.gpu[each.key].name, null)

  # null -- the provider's "no placement group" -- for a pool that set no
  # strategy, which is the default. The lookup key is rebuilt from this node's
  # own pool and zone, matching how locals.tf's gpu_placement_groups keyed the
  # map; try() rather than a conditional on placement_strategy because the map
  # is already filtered by exactly that condition, so a missing key and a
  # strategy-less pool are the same state expressed once.
  placement_group = try(evroc_placement_group.gpu["${each.value.pool}/${each.value.zone}"].fqid, null)

  # Per-node Ignition only -- see locals.tf's node_runtime_ignition. THIS is
  # the entire reason a GPU node behaves like one: nothing in this resource
  # itself marks it as a GPU worker. The flavor and security group it got at
  # create time follow from which pool it belongs to, but its ROLE --
  # NODETYPE=agent, no IS_INIT_NODE -- comes from runtime.env, delivered the
  # same way for every node in the cluster regardless of type.
  #
  # Ordinary VMs: a GPU worker sits behind a security group exactly like any
  # other node -- there is nothing about the flavor that exempts it from that
  # model.
  cloud_config_user_data = local.node_runtime_ignition[each.key]

  # Same UEFI requirement and the same failure mode as control-plane.tf's own
  # copy of this label -- see that file's comment for the full explanation, and
  # for why the base here is build_labels rather than common_labels.
  # Duplicated rather than factored into a shared local: the two resources
  # differ enough elsewhere (placement group, security group, flavor source,
  # and the `pool` label below) that a shared "node defaults" local would
  # obscure more than it saves.
  user_labels = merge(local.build_labels, {
    "role"                               = "gpu"
    "pool"                               = each.value.pool
    "compute-experimental-features-UEFI" = "true"
  })

  lifecycle {
    precondition {
      # See the identical check on evroc_virtual_machine.control_plane.
      condition     = length(local.node_runtime_ignition[each.key]) <= local.user_data_max_bytes
      error_message = "Rendered Ignition for ${each.key} is ${nonsensitive(length(local.node_runtime_ignition[each.key]))} bytes, over the ${local.user_data_max_bytes}-byte ceiling evroc's 1 MB user-data limit leaves once base64 expansion is accounted for."
    }
  }
}
