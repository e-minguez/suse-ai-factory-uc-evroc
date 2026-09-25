# Queried live from the platform API (see the data source's own docs) --
# unlike a hardcoded list, this reflects what evroc actually offers right now,
# in this project/region.
data "evroc_compute_profiles" "this" {}

locals {
  # One entry per flavor this module is about to request, keyed by a
  # human-readable label so a precondition failure names the actual consumer
  # rather than a variable name. gpu_pools contributes one entry per pool,
  # quoted with its key so two pools requesting the same bad flavor still
  # produce two distinct, individually readable errors.
  requested_flavors = merge(
    {
      "control-plane" = var.control_plane_flavor
      "jumphost"      = var.jumphost_flavor
    },
    {
      for k, v in var.gpu_pools :
      "gpu pool \"${k}\"" => v.flavor
    },
  )

  # The same data source carries a .details list with per-profile vcpus,
  # memory, gpu_model and gpu_quantity. Keyed by profile name so the GPU
  # arithmetic below can look a flavor up.
  compute_profile_details = {
    for d in data.evroc_compute_profiles.this.details : d.name => d
  }

  # THE GPU QUOTA IS COUNTED IN GPUs, NOT IN VMs, and the flavor size is the
  # GPU count: gn-l40s.s is 1 GPU, .m is 2, .l is 4. So a pool of count = 1 on
  # gn-l40s.m asks the admission webhook for TWO nvidia.com/AD102GL_L40S, and
  # on a project holding one it is denied at apply time with a message about a
  # number that appears nowhere in the tfvars. Nothing here can check the quota
  # -- the provider exposes no GPU quota data source -- but count * gpu_quantity
  # is knowable at plan time, and it is exactly the number the webhook compares.
  # Surfaced through the gpu_quota_request output so it shows up in the plan
  # diff, next to the pool that caused it.
  gpu_pool_demand = {
    for k, v in var.gpu_pools : k => {
      flavor = v.flavor
      model  = try(local.compute_profile_details[v.flavor].gpu_model, "unknown")
      gpus   = v.count * try(local.compute_profile_details[v.flavor].gpu_quantity, 0)
      vcpus  = v.count * try(local.compute_profile_details[v.flavor].vcpus, 0)
    }
  }

  # Summed per GPU model, because that is the granularity the quota is held at:
  # two pools on different L40S sizes draw down one shared AD102GL_L40S budget.
  gpu_demand_by_model = {
    for model in distinct([for d in local.gpu_pool_demand : d.model]) :
    model => sum([for d in local.gpu_pool_demand : d.gpus if d.model == model])
  }
}

# Preconditions must attach to a resource's own lifecycle block, and "a
# requested flavor is offered" isn't an attribute of any real resource here --
# hence this otherwise-pointless terraform_data, which exists solely to carry
# the check. One instance per requested flavor (rather than one check with a
# loop inside it) so a failure names precisely which consumer asked for what.
#
# Gated on var.verify_flavor_availability and evaluated at PLAN time: a typo'd
# flavor name then costs a few seconds of `terraform plan`, not a half-applied
# cluster with some nodes up and one flavor rejected partway through.
resource "terraform_data" "flavor_availability_check" {
  for_each = var.verify_flavor_availability ? local.requested_flavors : {}

  input = "${each.key}:${each.value}"

  lifecycle {
    precondition {
      condition     = contains(data.evroc_compute_profiles.this.profiles, each.value)
      error_message = "${each.key} requests flavor \"${each.value}\", which evroc is not currently offering. Available profiles: ${join(", ", data.evroc_compute_profiles.this.profiles)}"
    }
  }
}

# Org-wide compute and networking quota, with current usage. Unlike
# evroc_project_quota (object storage only) this carries the limits the
# admission webhooks actually enforce -- vCPU, memory, public IPs -- see
# PLATFORM-NOTES.md. Organization-level: a project's own quota can only be
# lower, so a cluster that does not fit here cannot fit the project either.
data "evroc_organization_quota" "this" {}

locals {
  flavor_vcpus = {
    for f in distinct([var.jumphost_flavor, var.control_plane_flavor]) :
    f => try(local.compute_profile_details[f].vcpus, 0)
  }

  # Memory in GB. The quota reports strings ("160GB", "48.0GB"), the profiles a
  # number plus a unit; a unit not in this map yields null and skips the memory
  # comparison rather than failing on a format the provider has not shown yet.
  memory_unit_gb = { MB = 0.001, GB = 1, TB = 1000 }
  flavor_memory_gb = {
    for f in distinct([var.jumphost_flavor, var.control_plane_flavor]) :
    f => try(local.compute_profile_details[f].memory_amount * local.memory_unit_gb[upper(local.compute_profile_details[f].memory_unit)], null)
  }
  quota_memory_gb = try(
    tonumber(regex("^([0-9.]+)", replace(data.evroc_organization_quota.this.compute_memory, " ", ""))[0])
    * local.memory_unit_gb[upper(regex("[A-Za-z]+$", data.evroc_organization_quota.this.compute_memory))],
    null
  )

  # What this cluster holds at the PEAK of each pass, ignoring everything else
  # in the org. Pass 1 is one build host per zone, all on jumphost_flavor; pass
  # 2 destroys the builders before any node is created (snapshot.tf), leaving
  # the jumphost plus the control plane. GPU workers are left out: their vCPUs
  # and memory are not drawn from this quota (PLATFORM-NOTES.md, GPU quota).
  quota_demand = {
    vcpus = max(
      length(var.zones) * local.flavor_vcpus[var.jumphost_flavor],
      local.flavor_vcpus[var.jumphost_flavor] + var.control_plane_count * local.flavor_vcpus[var.control_plane_flavor],
    )
    memory_gb = try(max(
      length(var.zones) * local.flavor_memory_gb[var.jumphost_flavor],
      local.flavor_memory_gb[var.jumphost_flavor] + var.control_plane_count * local.flavor_memory_gb[var.control_plane_flavor],
    ), null)
    # API VIP + jumphost always; per-node IPs only when asked for.
    public_ips = (
      2
      + (var.control_plane_public_ip ? var.control_plane_count : 0)
      + (var.gpu_public_ip ? length(local.gpu_nodes) : 0)
    )
  }
}

# Fails the plan when the cluster ALONE exceeds the org limit -- three a1a.l
# build hosts against 20 vCPU, control_plane_public_ip = true against 3 public
# IPs. Those can never fit, whatever else is running, and without this they
# fail partway through an apply at the admission webhook.
#
# Deliberately no check against limit minus usage. Usage includes this
# cluster's own existing VMs and IPs, and nothing at plan time says which
# those are, so a deployed cluster (16 vCPU in use, 16 demanded, 20 allowed)
# would warn on every plan. The quota_request output shows all three numbers
# instead; read the headroom off it before a first apply in a shared org.
resource "terraform_data" "quota_check" {
  count = var.verify_flavor_availability ? 1 : 0

  input = local.quota_demand

  lifecycle {
    precondition {
      condition     = local.quota_demand.vcpus <= data.evroc_organization_quota.this.compute_vcpus
      error_message = "This cluster needs ${local.quota_demand.vcpus} vCPU at its peak (pass 1: ${length(var.zones)} build hosts on ${var.jumphost_flavor}; pass 2: jumphost + ${var.control_plane_count} x ${var.control_plane_flavor}), over the organization's quota of ${data.evroc_organization_quota.this.compute_vcpus}. Use smaller flavors or ask evroc for a quota increase."
    }
    precondition {
      condition     = local.quota_demand.memory_gb == null || local.quota_memory_gb == null || coalesce(local.quota_demand.memory_gb, 0) <= coalesce(local.quota_memory_gb, 0)
      error_message = "This cluster needs ${coalesce(local.quota_demand.memory_gb, 0)} GB of memory at its peak, over the organization's quota of ${data.evroc_organization_quota.this.compute_memory}. Use smaller flavors or ask evroc for a quota increase."
    }
    precondition {
      condition     = local.quota_demand.public_ips <= data.evroc_organization_quota.this.networking_public_ips
      error_message = "This cluster needs ${local.quota_demand.public_ips} public IPs (API VIP + jumphost${var.control_plane_public_ip ? " + one per control plane" : ""}${var.gpu_public_ip ? " + one per GPU node" : ""}), over the organization's quota of ${data.evroc_organization_quota.this.networking_public_ips}. Set control_plane_public_ip / gpu_public_ip = false or ask evroc for a quota increase."
    }
  }
}
