terraform {
  # Nothing in this module's own files needs a feature newer than 1.3
  # (optional() attribute defaults on var.gpu_pools), but variables.tf's
  # cross-variable validation (e.g. var.subnet_newbits checked against
  # var.vpc_cidr and var.zones) is only legal from 1.9 onward -- earlier releases hard-error
  # with "Invalid reference in variable validation". Pinned at the module
  # boundary so every file agrees on the floor.
  required_version = ">= 1.9"

  required_providers {
    # The cloud itself: VPC/subnet/security groups/load balancer/VMs.
    #
    # 0.9.4 is a HARD FLOOR, not a preference: it is the first release where
    # evroc_loadbalancer accepts a backend_network block, and without that the
    # load balancer attaches to the default VPC and silently forwards nothing
    # (loadbalancer.tf says more). An older provider fails the plan on an
    # unsupported block, which is the outcome we want.
    #
    # ~> still holds us inside the 0.9 series so a breaking 0.10 (this provider
    # has shipped breaking changes inside a minor bump before -- see 0.8.0's
    # removal of evroc_permission_set) requires a deliberate bump rather than
    # landing on a bare `terraform init -upgrade`.
    evroc = {
      source  = "evroc-oss/evroc"
      version = "~> 0.9.4"
    }

    # random_password (the RKE2 join token, the Rancher bootstrap password)
    # lives in locals.tf, not here -- but the module-wide provider pin belongs
    # in one place.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    # time_static pins the snapshot/build-id timestamp at create time;
    # timestamp() would re-evaluate on every plan and force a perpetual diff.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }

    # data.http fetches the AI Factory release manifest at PLAN time, purely so
    # its body can be hashed into the build id -- the jumphost fetches its own
    # copy at build time. Consequence worth knowing: `terraform plan` needs
    # outbound access to aif_release_manifest_url, and an unreachable URL fails
    # the plan rather than the apply.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
