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
