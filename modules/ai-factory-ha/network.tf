# One VPC for the whole cluster -- evroc_vpc is REGIONAL, so a single VPC
# spans every zone in var.zones and the per-zone subnets below all hang off it.
# The regional/zonal split: VPC, load balancer, backend pool, public IP and
# security group are regional; subnet, disk, VM, placement group and -- despite
# a schema that says otherwise -- SNAPSHOT are zonal. That last one is why
# image-build.tf builds the image once per zone rather than once; see
# locals.tf's primary_zone.
resource "evroc_vpc" "this" {
  name             = "${var.cluster_name}-vpc"
  ipv4_cidr_blocks = [var.vpc_cidr]
  project          = var.project
  region           = var.region
  user_labels      = merge(local.common_labels, { "role" = "network" })
}

# One subnet per zone. evroc_subnet is zonal -- a subnet belongs to exactly one
# zone and a VM can only attach to a subnet in its own zone -- so spanning
# zones necessarily means one subnet each, not one subnet stretched across
# them. CIDRs come from local.subnet_cidrs (locals.tf), carved out of vpc_cidr
# by cidrsubnet() so they cannot overlap or leave a gap.
#
# for_each over the zone list rather than count: the key is the zone name, so
# reordering var.zones does not renumber and therefore replace subnets that did
# not change. Removing a zone from the list destroys that zone's subnet (and
# everything in it), which is the intended meaning of removing it.
resource "evroc_subnet" "this" {
  for_each = toset(var.zones)

  name            = "${var.cluster_name}-subnet-${each.key}"
  vpc_ref         = evroc_vpc.this.fqid
  zone            = each.key
  ipv4_cidr_block = local.subnet_cidrs[each.key]
  project         = var.project
  region          = var.region
  user_labels     = merge(local.common_labels, { "role" = "network" })
}

# The load balancer's address -- and therefore the Kubernetes API VIP -- is a
# standalone resource rather than an attribute the load balancer computes for
# itself. That is what makes the whole build sequence work: the VIP exists,
# with a known value, before the load balancer, the control-plane nodes, or
# the elemental image do. The image's RKE2 config bakes in the VIP as
# api_host/tls-san, so if the VIP were only known after the load balancer (and
# the load balancer only after its backends) building the image would need
# nodes that need the image -- a cycle. Allocating the address up front breaks
# it: this resource has no dependencies at all, so it can be created first,
# read by everything else, and never has to wait on anything downstream.
resource "evroc_public_ip" "cluster" {
  name    = "${var.cluster_name}-api-vip"
  project = var.project
  region  = var.region

  # role = api-vip, not "loadbalancer": this address is allocated before the
  # load balancer exists and is the one object in the module that outlives a
  # load balancer being torn down and rebuilt. Anyone hunting a stray public IP
  # against the project's 3-address quota needs to see which one is the VIP.
  user_labels = merge(local.common_labels, { "role" = "api-vip" })
}

# "spread" keeps control-plane VMs off the same physical host, so a single
# hardware failure cannot take out an etcd quorum majority.
#
# ONE PER ZONE, because a placement group is zonal and can only constrain VMs
# within its own zone. The two mechanisms stack rather than overlap: zones
# protect against losing a datacentre, the placement group protects against
# losing a host inside one. Neither substitutes for the other, and on the
# default 3-nodes-over-3-zones layout each group holds exactly one VM and does
# nothing -- it earns its keep the moment control_plane_count exceeds the zone
# count and two members land in the same zone.
resource "evroc_placement_group" "control_plane" {
  for_each = toset(var.zones)

  name        = "${var.cluster_name}-control-plane-pg-${each.key}"
  strategy    = "spread"
  zone        = each.key
  project     = var.project
  region      = var.region
  user_labels = merge(local.common_labels, { "role" = "control-plane" })
}

# GPU placement groups, one per (pool, zone) pair actually in use, and only for
# pools that asked for one -- gpu_pools[*].placement_strategy, null by default.
#
# Per pool, not module-wide: an inference pool wants "spread" so a host failure
# costs one replica, while a training pool wants "cluster" so collective
# operations stay on the fastest interconnect available. Those are opposite
# constraints, and a cluster can reasonably run both at once.
#
# The key is "<pool>/<zone>". Both halves are plan-known (they come from
# var.gpu_pools and var.zones, never from a resource attribute), so this map's
# key set is stable across the image-build sequencing the same way the node
# maps are -- see control-plane.tf for why that matters.
resource "evroc_placement_group" "gpu" {
  for_each = local.gpu_placement_groups

  name     = "${var.cluster_name}-${each.value.pool}-pg-${each.value.zone}"
  strategy = each.value.strategy
  zone     = each.value.zone
  project  = var.project
  region   = var.region

  # `pool` as well as `role`, here and on every other per-pool object: a
  # cluster can run several GPU pools with opposite placement strategies, and
  # "which pool is this group constraining" is not answerable from role alone.
  user_labels = merge(local.common_labels, {
    "role" = "gpu"
    "pool" = each.value.pool
  })
}
