# Pass 1 of the two-pass image build -- see var.image_ready's own description
# for the full sequence. This file stands up the build hosts, the blank disks
# they write the elemental raw image onto, and the hotswap attachments that
# make those disks visible to them. snapshot.tf picks up once the builds are
# confirmed complete and the attachments are gone.
#
# ONE COMPLETE BUILD PER ZONE. Not one build cloned outward: evroc_snapshot is
# zonal (it inherits the zone of its disk_ref, and disk-webhook.evroc.com
# rejects a disk created from a snapshot belonging to another zone), and the
# provider offers no snapshot-copy and no cross-zone disk clone. locals.tf's
# primary_zone carries the full reasoning and the quote from evroc's docs. So
# var.zones drives a fan-out here: a disk, a build host and (in snapshot.tf) a
# snapshot per zone. With zones = ["a"] every for_each below has one element
# and this is exactly the single-jumphost shape it has always been.
#
# The build hosts are split across TWO resources rather than one for_each:
#
#   evroc_virtual_machine.jumphost  -- zones[0] only, the one with a public IP,
#                                      the operator's bastion.
#   evroc_virtual_machine.builder   -- every other zone, no public IP, reached
#                                      only by tunnelling through the jumphost.
#
# That split is forced, not stylistic. The builders' security group has to
# admit SSH from the jumphost's private address, so it must read
# evroc_virtual_machine.jumphost. Were the builders instances of that same
# resource, the group would depend on the resource that depends on it --
# Terraform resolves dependencies between RESOURCES, not between individual
# for_each instances, so "jumphost[a] is fine, only jumphost[b] needs the
# group" is not a distinction it can make. It reports a cycle and refuses to
# plan. Two resources make the direction unambiguous.

# The disks the built images are written onto, one per zone. Deliberately NOT
# scratch space: these OUTLIVE the build hosts -- they are the media
# evroc_snapshot.ai_factory (snapshot.tf) is later taken from, so they have to
# still exist, holding the finished image, after the hosts and their hotswap
# attachments are gone. No image/snapshot argument: each starts out blank, and
# image-factory.sh dd's the raw image straight onto it.
#
# They outlive the build hosts, and by default they outlive the snapshots too.
# A snapshot does survive its source disk being deleted -- it stays Ready and
# still creates disks (verified 2026-09-22) -- but nothing has yet BOOTED a
# disk cloned from a snapshot whose source was gone, so 32 GB a zone buys a
# hedge against a dependency nobody has tested.
# var.retain_image_target_disks = false gives it up; read that variable's
# description first. `!var.image_ready` keeps the disk unconditionally while a
# build could still need somewhere to write, so a --rebuild gets its media back
# no matter what the flag says.
resource "evroc_disk" "image_target" {
  for_each = !var.image_ready || var.retain_image_target_disks ? toset(var.zones) : toset([])

  name = local.image_target_disk_names[each.key]
  # Same zone as the build host that writes it: evroc_hotswap_disk_attachment
  # only joins a disk to a VM in the same zone.
  zone    = each.key
  size    = var.image_target_disk_gb
  project = var.project
  region  = var.region

  # build_labels, not common_labels: what is ON this disk is one specific image
  # generation, and after a --rebuild the previous generation's disk may still
  # be around. The `build` label is the only thing that says which is which --
  # the disk NAME is stable across rebuilds (see local.image_target_disk_names)
  # precisely so the same disk is reused, so the name cannot carry it.
  user_labels = merge(local.build_labels, { "role" = "image-build" })

  timeouts {
    create = var.disk_create_timeout
    delete = var.disk_delete_timeout
  }
}

# The jumphost's own OS disk -- openSUSE Leap (local.jumphost_image), not the
# elemental image it builds for the cluster nodes. One, in zones[0].
#
# for_each over a single-element set rather than a plain resource so the state
# address stays evroc_disk.jumphost_boot["a"]. Dropping to an unkeyed address
# would read as "destroy the old one, create a new one" on every cluster that
# already exists -- and that disk is the jumphost's root filesystem, so the
# jumphost goes with it.
resource "evroc_disk" "jumphost_boot" {
  for_each = toset([local.primary_zone])

  name    = "${var.cluster_name}-jumphost-boot-${each.key}"
  zone    = each.key
  image   = local.jumphost_image
  size    = var.jumphost_disk_gb
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, { "role" = "jumphost" })

  timeouts {
    create = var.disk_create_timeout
    delete = var.disk_delete_timeout
  }
}

# The builders' OS disks -- same image, same size, separate resource.
#
# SEPARATE BECAUSE THEY HAVE A DIFFERENT LIFETIME, and sharing one resource
# with the jumphost's disk silently gave them the jumphost's. They were keyed
# on toset(var.zones) like the disk above, so pass 2 destroyed every builder
# VM and left its boot disk behind: three zones meant two orphaned Leap disks
# per cluster, named after a jumphost they were never attached to, charged for
# and counted against disk quota until someone noticed and deleted them by
# hand. Keyed on builder_zones_active they are torn down with the VMs that boot
# them, in the same apply.
#
# Nothing on them is worth keeping -- a stock Leap root filesystem. What the
# build produced lives on evroc_disk.image_target, which is a different
# resource with a deliberately longer life, and by the time these are destroyed
# that image has already been captured as a snapshot.
resource "evroc_disk" "builder_boot" {
  for_each = local.builder_zones_active

  name    = "${var.cluster_name}-builder-boot-${each.key}"
  zone    = each.key
  image   = local.jumphost_image
  size    = var.jumphost_disk_gb
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, { "role" = "builder" })

  timeouts {
    create = var.disk_create_timeout
    delete = var.disk_delete_timeout
  }
}

# Exactly one, for the primary build host, no matter how many zones are
# configured. A default evroc project allows three public IPs and the API VIP
# already holds one; giving every build host its own would put a three-zone
# cluster over the limit before a single node exists. The builders do not need
# one -- evroc VPCs give every VM outbound internet access without it, which is
# all `podman pull` requires.
resource "evroc_public_ip" "jumphost" {
  name    = "${var.cluster_name}-jumphost-ip"
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, { "role" = "jumphost" })
}

# Locals so the size preconditions below can read them -- a precondition can't
# reliably read back the resource's own config attribute.
#
# Per zone, because local.factory_script is per zone. Split in two because the
# jumphost and the builders differ in how they take part in status reporting:
# the jumphost RUNS the status relay (templates/status-relay.py) and publishes
# to it on localhost; a builder publishes to it across the VPC, so it has to be
# told the jumphost's private address. That address can only come from
# evroc_virtual_machine.jumphost, and the jumphost reads its own user_data, so
# the two cannot be one map: the whole map would depend on the jumphost VM,
# and Terraform would report a cycle. The builders' half may depend on it
# freely -- they are a different resource.
locals {
  build_host_user_data_vars = {
    files               = local.elemental_files
    config_dir          = local.config_dir
    ssh_authorized_keys = var.ssh_authorized_keys
    jumphost_username   = var.jumphost_username
    status_relay_port   = var.status_relay_port
  }

  jumphost_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", merge(local.build_host_user_data_vars, {
    factory_script      = local.factory_script[local.primary_zone]
    status_relay_script = file("${path.module}/templates/status-relay.py")
    # Only VPC addresses may publish; the operator's side of the relay is
    # read-only. 127.0.0.0/8 is the jumphost's own build.
    status_relay_push_cidrs = "${var.vpc_cidr} 127.0.0.0/8"
    status_relay_zones      = join(" ", var.zones)
    status_url              = ""
  }))

  builder_user_data = {
    for z in local.builder_zones : z => templatefile("${path.module}/templates/cloud-init.yaml.tftpl", merge(local.build_host_user_data_vars, {
      factory_script          = local.factory_script[z]
      status_relay_script     = ""
      status_relay_push_cidrs = ""
      status_relay_zones      = ""
      status_url              = "http://${evroc_virtual_machine.jumphost.private_ipv4_address}:${var.status_relay_port}/zones"
    }))
  }

  # The zones whose build host is a builder rather than the jumphost. Derived
  # from var.zones, so these for_each keys are plan-known.
  builder_zones = toset(slice(var.zones, 1, length(var.zones)))

  # The builders that should EXIST right now, as opposed to the zones that have
  # one at all. Empty on pass 2: see evroc_virtual_machine.builder for why they
  # are torn down there rather than left standing.
  builder_zones_active = var.image_ready ? toset([]) : local.builder_zones
}

# openSUSE Leap, the build host's own OS -- not the elemental image it builds.
# No UEFI label here, unlike the elemental nodes (control-plane.tf,
# gpu-nodes.tf): this boots a stock evroc image, and whatever firmware path
# evroc's own stock images expect is already what their boot disks carry.
#
# The primary build host, in zones[0]. Also the cluster's bastion: the only
# machine in the VPC with an inbound path from the operator, and the hop every
# other SSH session in this module goes through.
resource "evroc_virtual_machine" "jumphost" {
  name   = "${var.cluster_name}-jumphost"
  flavor = var.jumphost_flavor
  # Same zone as its image_target disk, which the hotswap attachment requires.
  zone    = local.primary_zone
  project = var.project
  region  = var.region

  boot_disk       = evroc_disk.jumphost_boot[local.primary_zone].name
  security_groups = [evroc_security_group.jumphost.fqid]
  public_ip       = evroc_public_ip.jumphost.name
  subnet_ref      = evroc_subnet.this[local.primary_zone].fqid
  ssh_keys        = var.ssh_authorized_keys

  cloud_config_user_data = local.jumphost_user_data

  # role = jumphost, not build-host: this VM is both, but it OUTLIVES the build
  # -- with control_plane_public_ip = false it stays the only inbound path into
  # the VPC. The builders alongside it are torn down on pass 2, and the label
  # is what makes "the one that should still be here" obvious afterwards.
  user_labels = merge(local.common_labels, { "role" = "jumphost" })

  lifecycle {
    precondition {
      # DELIBERATELY FAR UNDER THE REAL LIMIT, which evroc confirmed on
      # 2026-09-22 as 1 MB (the VM is a KubeVirt object and user data is a
      # field in it; local.user_data_max_bytes has the details). 32 KiB is
      # ~2x a known-good payload and ~1/24 of what the platform would reject,
      # because what this is actually for is catching a template bug that
      # renders the elemental config directory twice -- which the platform
      # would happily accept. Node VMs are checked against the real ceiling
      # instead; build hosts carry the whole config dir gz+base64'd, so they
      # are where a size explosion shows up first.
      #
      # nonsensitive() on the length only: user_data is built from sensitive
      # inputs, so its byte count inherits that -- and the count has to be
      # visible for the error to be actionable.
      condition     = length(local.jumphost_user_data) <= 32768
      error_message = "Rendered jumphost user_data is ${nonsensitive(length(local.jumphost_user_data))} bytes, over the 32 KiB tripwire (evroc's own limit is 1 MB, so this is the module's, not the platform's). Check the comment strip in locals.tf still covers both local.elemental_files and local.factory_script, then look for a template rendering something twice, unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}

# The remaining build hosts, one per zone after the first. Identical to the
# jumphost above except for the three things that make them not-the-bastion: no
# public IP, their own security group, and their own zone's subnet and disks.
#
# These exist only for the length of a build. They are not part of the
# cluster's availability story and nothing routes through them afterwards --
# they are here because a zone's snapshot can only be produced by a disk
# written in that zone.
#
# WHICH IS WHY PASS 2 DESTROYS THEM, via local.builder_zones_active. Their work
# is finished the moment their image_target disk holds a verified image, and a
# default evroc project has 20 vCPU: three build hosts and three control-plane
# nodes do not fit in it simultaneously. Freeing the builders is what makes room
# for the nodes -- snapshot.tf's depends_on is what guarantees the freeing
# happens FIRST, rather than Terraform creating nodes in parallel with hosts it
# is still tearing down and hitting virtualmachine-webhook.evroc.com's quota
# check on the way.
#
# evroc_disk.builder_boot is keyed on the same local, so the boot disks go in
# the same apply -- Terraform orders the disk delete after the VM delete
# because the VM references it. Deleting a VM and its boot disk together is one
# of the few teardowns where a disk-in-use error is even conceivable; if one
# ever appears, re-running the apply is the fix, since the VM is gone by then.
#
# The jumphost is deliberately NOT torn down with them: with
# control_plane_public_ip = false it is the only inbound path into the VPC, so
# it goes on being the bastion long after it has stopped being a build host.
#
# The cost of this: if pass 2 fails partway, the builders are already gone and
# the images on their disks are unreachable for inspection. Recovering means
# --rebuild, not a retry. That trade is only worth taking because the images
# have already been confirmed complete -- every zone has reported "done" with
# the current build id -- before pass 2 is allowed to start.
resource "evroc_virtual_machine" "builder" {
  for_each = local.builder_zones_active

  name    = "${var.cluster_name}-builder-${each.key}"
  flavor  = var.jumphost_flavor
  zone    = each.key
  project = var.project
  region  = var.region

  boot_disk       = evroc_disk.builder_boot[each.key].name
  security_groups = [evroc_security_group.builder[0].fqid]
  subnet_ref      = evroc_subnet.this[each.key].fqid
  ssh_keys        = var.ssh_authorized_keys

  # No public_ip. Outbound still works -- see evroc_public_ip.jumphost above.

  cloud_config_user_data = local.builder_user_data[each.key]
  user_labels            = merge(local.common_labels, { "role" = "builder" })

  lifecycle {
    precondition {
      condition     = length(local.builder_user_data[each.key]) <= 32768
      error_message = "Rendered builder user_data for zone ${each.key} is ${nonsensitive(length(local.builder_user_data[each.key]))} bytes, over the 32 KiB tripwire (evroc's own limit is 1 MB). See the same precondition on evroc_virtual_machine.jumphost for what to check."
    }
  }
}

# THE HINGE OF THE WHOLE TWO-PASS DESIGN.
#
# On pass 1 (var.image_ready = false), one attachment per zone: this joins each
# blank image_target disk to that zone's build host so image-factory.sh has a
# device to dd the raw image onto. evroc_disk carries no attachment of its own
# -- without this resource a build host never sees its disk at all.
#
# On pass 2, once the operator knows the builds finished (via
# terraform_data.image_written below, on a prior apply) and flips
# var.image_ready to true, the for_each goes empty and Terraform DESTROYS these
# resources. That destruction IS the detach: evroc's hotswap-attachment model
# ties a disk's visibility to a VM to this resource existing at all, so
# removing it is the only way to free image_target. And detaching is a
# precondition for evroc_snapshot.ai_factory (snapshot.tf) -- a disk still
# attached to a running VM cannot be snapshotted with consistent contents,
# since the host (or some process on it) could still be mid-write.
#
# So the two values of var.image_ready select between two entirely different
# jobs for this one resource: false ATTACHES (to allow writing), true DESTROYS
# (to allow reading). There is no state in this design where both a snapshot
# exists and its attachment does -- that ordering is the entire point of the
# variable, not an incidental side effect of it.
resource "evroc_hotswap_disk_attachment" "image_target" {
  for_each = var.image_ready ? toset([]) : toset(var.zones)

  name = "${var.cluster_name}-image-target-attach-${each.key}"
  disk = evroc_disk.image_target[each.key].name
  # The jumphost owns zones[0]; every other zone is a builder.
  virtual_machine = each.key == local.primary_zone ? evroc_virtual_machine.jumphost.name : evroc_virtual_machine.builder[each.key].name
  project         = var.project
  region          = var.region

  user_labels = merge(local.common_labels, { "role" = "image-build" })
}

# Blocks the apply until every zone's image-factory.sh has reported, through
# the status relay on the jumphost, that the CURRENT build id was written onto
# that zone's image_target -- or until any zone reports it failed, or
# image_build_timeout runs out. count = 0 only when var.snapshot_ids overrides
# the build entirely -- there is no build to wait for at all then.
#
# ONE resource covering ALL zones, not one per zone. The script polls every
# target in a single pass, so N zones share one timeout budget and one stream
# of progress output instead of racing N provisioners that each report only
# their own slice -- and so a zone that never finishes fails the apply as one
# timeout rather than N.
#
# Deliberately NOT also gated on !var.image_ready, which would be the obvious
# reading of "pass 2 has nothing left to wait for". It usually hasn't, and on
# the normal path this resource simply persists across pass 2 untouched,
# costing nothing. What the gate would throw away is the ONE case that
# matters: an image-affecting variable edited BETWEEN pass 1 and pass 2.
#
# That changes local.build_id, so the images sitting on the image_target disks
# were built from configuration that no longer exists -- and pass 2 would
# cheerfully snapshot them anyway, under names derived from a build id that
# never touched those disks, producing a cluster running an image the operator
# already replaced. Nothing else in the module would notice: the disks have
# valid contents, the GPT check passed, every zone reported "done".
#
# Keeping this resource alive makes that visible. A changed build_id shows up
# in the pass-2 plan as "terraform_data.image_written must be replaced",
# directly above the snapshots being created, which is the operator's chance to
# stop. Approve it anyway and the provisioner re-runs, sees IMAGE_READY=true
# -- there is no build it could be waiting for -- and fails at once, loudly,
# rather than succeeding quietly with the wrong bytes.
#
# deploy.sh does not hit this: it runs both passes back to back against one
# config. It is hand-editing between passes -- or a bare `terraform apply`
# after an edit -- that gets here.
resource "terraform_data" "image_written" {
  count = length(var.snapshot_ids) == 0 ? 1 : 0

  depends_on = [
    evroc_virtual_machine.jumphost,
    evroc_virtual_machine.builder,
    evroc_hotswap_disk_attachment.image_target,
  ]

  # triggers_replace, not just `input`: local-exec fires only on create, and a
  # changed `input` merely updates in place. Without this, a rebuild (a new
  # build_id) would skip the wait entirely and let a later apply read devices
  # that were never (re)written for the current build.
  triggers_replace = [local.build_id, join(",", var.zones)]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      # The relay on the jumphost, dialled on its PUBLIC address: the only
      # one reachable from the operator's machine. Plain GETs, no SSH -- the
      # builders publish to the relay across the VPC, so nothing has to reach
      # them from outside. security-groups.tf opens the port to
      # var.admin_cidrs only, and only while a build can be running.
      STATUS_URL = "http://${evroc_public_ip.jumphost.ip_address}:${var.status_relay_port}/zones"
      ZONES      = join(" ", var.zones)

      BUILD_ID        = local.build_id
      TIMEOUT_SECONDS = var.image_build_timeout
      POLL_SECONDS    = 30

      # true only in the edited-between-passes case described above: the
      # relay port is closed and nothing is building, so the script fails
      # fast instead of waiting out the timeout.
      IMAGE_READY = tostring(var.image_ready)
    }
  }
}
