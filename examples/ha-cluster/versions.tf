terraform {
  # terraform_data (used by the module's flavor-availability checks) shipped
  # in 1.4; the module's subnet_cidr validation cross-references vpc_cidr,
  # which needs 1.9.
  required_version = ">= 1.9"

  required_providers {
    # 0.9.4 is the first release with evroc_loadbalancer.backend_network --
    # see the module's own versions.tf.
    evroc = {
      source  = "evroc-oss/evroc"
      version = "~> 0.9.4"
    }
  }
}

# Empty on purpose: the provider reads ~/.evroc/config.yaml, written by
# `evroc login`. There is no API-key environment variable to export here.
# region, zone and project are module variables (defaulting to null, i.e.
# "whatever the CLI context says") rather than provider arguments, so one
# provider block can serve any project/region this example is pointed at.
provider "evroc" {}
