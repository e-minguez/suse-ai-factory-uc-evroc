# Pass 2 of the two-pass image build. image-build.tf's
# evroc_hotswap_disk_attachment.image_target holds the exclusive write access
# image-factory.sh needs on pass 1; this file picks up once var.image_ready
# confirms those attachments are gone and the disks hold finished images.
#
# One snapshot per zone, because evroc_snapshot is zonal -- it takes the zone
# of the disk its disk_ref names, and a disk cannot be created from another
# zone's snapshot. See locals.tf's primary_zone for the webhook error and the
# quote from evroc's docs.

# Identity for one build: anything that actually lands on the image renumbers
# it, so a stale snapshot is never read back for a configuration it no longer
# matches.
#
# Hashes the RENDERED config -- local.elemental_files, the release manifest
# body, the FILTERED sysext overrides -- not the *.tftpl sources and not the
# raw variables. A change to a variable's value has to show up here even when
# no template file itself changed, and an override for an extension nothing
# enables must NOT renumber the build (see effective_sysext_overrides' own
# comment in locals.tf for why that filtering exists at all).
#
# time_static, not timestamp(): timestamp() re-evaluates on every plan, which
# would drift the build id -- and with it the jumphost's own ForceNew user
# data -- on every single plan regardless of whether anything actually
# changed.
resource "time_static" "build" {
  triggers = {
    cluster  = var.cluster_name
    endpoint = local.api_vip
    image    = var.elemental_image # not part of elemental_files; only reaches the factory script
    config   = sha256(jsonencode(local.elemental_files))
    manifest = sha256(data.http.aif_release_manifest.response_body)
    sysexts  = sha256(jsonencode(local.effective_sysext_overrides))
  }
}

locals {
  # e.g. "suse-ai-factory-20260914-143512", UTC -- time_static records a "Z"
  # instant and formatdate does no conversion.
  #
  # ONE build id across every zone. The zones run the same build against the
  # same inputs, so a per-zone id would assert a difference that does not exist
  # -- and would stop the sentinel check in wait-for-image.sh from being a
  # single comparison. The zone appears only in the snapshot NAME, which does
  # have to be unique.
  # "/compute/projects/<project>/regions/<region>/disks/" -- every disk fqid in
  # this project and region is this prefix plus the disk's name. Read off a
  # real disk rather than composed from var.project/var.region because
  # var.project defaults to null and the PROVIDER supplies the value, so the
  # module does not reliably know its own project id. See disk_ref below for
  # what needs it.
  disk_fqid_prefix = trimsuffix(
    evroc_disk.jumphost_boot[local.primary_zone].fqid,
    evroc_disk.jumphost_boot[local.primary_zone].name,
  )

  build_id = "${var.cluster_name}-${formatdate("YYYYMMDD-hhmmss", time_static.build.rfc3339)}"
  snapshot_names = {
    for z in var.zones : z => "${local.build_id}-snapshot-${z}"
  }
}

# Terraform-owned, unlike a snapshot created by hand or by a script calling
# the platform API directly: `terraform destroy` reclaims this along with
# everything else the module created. disk_ref points at the very disk
# image-build.tf's hotswap attachment writes through, and count here is gated
# on var.image_ready -- which is exactly what sequences "attachment destroyed
# (and therefore the disk detached)" before "snapshot created". Taking a
# snapshot of a disk still attached to a running VM would risk capturing it
# mid-write.
#
# The ordering holds in practice but is not guaranteed by anything, and this
# is the one place the module can fail an apply and recover on a re-run.
# Flipping var.image_ready to true destroys the hotswap attachment AND creates
# this snapshot in the SAME apply, and Terraform's ordering between "destroy
# resource A" and "create unrelated resource B" is not something depends_on
# states cleanly: the documented meaning of depends_on runs the other way,
# ordering A's destroy AFTER its dependents. It is declared below anyway -- it
# is the strongest hint available and it cannot introduce a cycle -- but it is
# a hint, not a guarantee. Every pass-2 apply run to date has detached first.
#
# If evroc ever rejects the snapshot because the disk is still attached, the
# apply fails having already destroyed the attachment, so simply running the
# same apply again succeeds. Nothing is lost and nothing is half-built; the
# disk still holds the image either way. If the race does start biting, the
# deterministic fix is for deploy.sh's second pass to detach in its own
# `terraform apply -target=...evroc_hotswap_disk_attachment.image_target`
# before the full apply.
#
# evroc_virtual_machine.builder is in the depends_on list for a second,
# unrelated reason: QUOTA. Pass 2 destroys the builders (image-build.tf) and
# creates the control-plane nodes, and a default evroc project's 20 vCPU does
# not hold both at once. Everything downstream of a snapshot -- every node disk,
# every node -- is therefore ordered behind the builders going away. Without
# this edge Terraform is free to create nodes in parallel with the teardown and
# collect a 403 from virtualmachine-webhook.evroc.com for a cluster that fits
# perfectly well once the apply settles.
# NO user_labels, and not by choice: evroc_snapshot is the ONE resource type
# this module creates that the provider gives no user_labels attribute at all
# (`terraform providers schema -json` lists only system_labels on it, alongside
# evroc_service_account_credential and evroc_think_api_key). So a snapshot
# cannot be filtered by cluster, role or build the way everything else can, and
# its NAME is the only handle there is -- which is why local.snapshot_names
# builds it out of the cluster name, the build timestamp and the zone rather
# than something shorter. Add user_labels here the day the provider grows it.
resource "evroc_snapshot" "ai_factory" {
  for_each = length(var.snapshot_ids) == 0 && var.image_ready ? toset(var.zones) : toset([])

  depends_on = [
    evroc_hotswap_disk_attachment.image_target,
    evroc_virtual_machine.builder,
  ]

  # try(), because evroc_disk.image_target has no instances once
  # var.retain_image_target_disks reclaims them -- and a reference to a missing
  # for_each key is a plan-time "Invalid index", not a null. The fallback has
  # to produce the IDENTICAL string the real attribute did: a different value
  # is a diff on an immutable field, and Terraform's answer to that is to
  # destroy the snapshot and recreate it from a disk that no longer exists.
  # Hence deriving the prefix from a sibling disk's own fqid rather than
  # assembling it out of var.project (null by default -- the provider fills it
  # in, so the module cannot spell the fqid itself). jumphost_boot is the right
  # sibling: same type, same project, same region, and it outlives everything
  # here.
  #
  # Keeping the reference inside try() rather than always using the constructed
  # string is what preserves the graph edge that orders disk-create before
  # snapshot-create.
  disk_ref = try(evroc_disk.image_target[each.key].fqid, "${local.disk_fqid_prefix}${local.image_target_disk_names[each.key]}")
  name     = local.snapshot_names[each.key]
  project  = var.project
  region   = var.region

  lifecycle {
    # Belt and braces on the above. The derivation is exact by construction,
    # but the cost of it ever being wrong is not a failed plan -- it is
    # Terraform deleting the snapshot every node's boot disk was cloned from,
    # then failing to recreate it. disk_ref is immutable on the platform
    # anyway, so there is no legitimate change here to suppress.
    ignore_changes = [disk_ref]
  }
}

locals {
  # Zone -> the snapshot a node in that zone clones its boot disk from. A MAP,
  # not a single id: a node disk may only be created from a snapshot in its own
  # zone, so "the snapshot" is not a thing this module has -- control-plane.tf
  # and gpu-nodes.tf index this by each node's own zone.
  #
  # Explicit conditional, NOT coalesce(): with snapshot_ids unset and
  # image_ready still false, both branches are null, and coalesce() errors on
  # all-null arguments instead of returning null -- and null is the right
  # answer there, since nothing has been snapshotted yet.
  #
  # The VALUES here are unknown at plan time on the apply that creates the
  # snapshots -- evroc assigns the fqids -- so nothing that decides whether a
  # resource EXISTS may be derived from them. The KEYS are var.zones and stay
  # plan-known, which is what keeps this indexable from a for_each'd resource.
  # See snapshot_expected below.
  effective_snapshot_ids = {
    for z in var.zones : z => (
      length(var.snapshot_ids) > 0
      ? var.snapshot_ids[z]
      : try(evroc_snapshot.ai_factory[z].fqid, null)
    )
  }

  # "Will a snapshot exist by the end of this apply?", answered WITHOUT
  # looking at the snapshot. This is the gate the node resources use, and the
  # distinction is not a nicety -- it is the difference between a module that
  # plans and one that cannot even be destroyed.
  #
  # The obvious formulation, `local.effective_snapshot_ids[z] != null`, is a
  # trap. On the apply that creates the snapshots the fqids are unknown, so the
  # comparison is unknown, so the ternary picking between {} and the node map
  # is unknown, so the whole MAP is unknown -- not just its values, its KEYS.
  # for_each then fails with "map includes keys derived from resource
  # attributes that cannot be determined until apply", on every node resource
  # at once. It fails on `terraform destroy` too, since destroy still has to
  # evaluate for_each to know what it is destroying, which leaves the
  # configuration wedged with no Terraform-native way out.
  #
  # Both terms below are plan-known for the same reason: they are variables.
  # And the condition is exactly equivalent -- evroc_snapshot.ai_factory is
  # created when `length(var.snapshot_ids) == 0 && var.image_ready`, so
  # snapshots exist iff snapshot_ids was supplied or image_ready is set.
  snapshot_expected = length(var.snapshot_ids) > 0 || var.image_ready
}
