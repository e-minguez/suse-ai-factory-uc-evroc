# GPU nodes on evroc are ordinary VMs (evroc_virtual_machine) and take
# security groups like any other. So every node in the cluster -- control
# plane, jumphost, GPU alike -- sits behind one of the groups below; there is
# no node this module has to leave unprotected.

# --- shared rule fragments -----------------------------------------------
#
# Built as data (maps of rule attributes), then rendered with a single
# `dynamic "rule"` per direction per group, so the port lists read like a
# table instead of N copy-pasted rule blocks.

locals {
  # Identical on jumphost, control-plane and gpu: admins reach port 22 on
  # every node type from the same set of CIDRs.
  admin_ssh_rules = {
    for cidr in var.admin_cidrs :
    "ssh-${replace(cidr, "/", "_")}" => {
      protocol  = "TCP"
      port      = 22
      end_port  = null
      remote_ip = cidr
    }
  }

  # SSH from the jumphost, for the control-plane and gpu groups only -- NOT
  # for the jumphost's own group, which would turn any node into a foothold
  # back into the bastion.
  #
  # This is what makes the jumphost an actual bastion rather than just the
  # first host anyone happens to log into. Without it, the only SSH sources for
  # a node are var.admin_cidrs, which are the operator's own public prefixes;
  # the jumphost dials a node from INSIDE the VPC, so its source address is a
  # private one out of vpc_cidr and no admin_cidrs entry will ever match it.
  #
  # That gap is invisible while nodes carry public IPs and becomes total the
  # moment they do not: with control_plane_public_ip = false there is no
  # reachable SSH path to any node at all, and the failure looks like a broken
  # node rather than a missing rule.
  #
  # The jumphost's own /32, not vpc_cidr: the narrower rule says exactly what
  # is intended ("the bastion may SSH to nodes") and does not additionally
  # permit node-to-node SSH. The value is only known after the jumphost is
  # created, which is fine -- it is a rule VALUE, not a for_each key, so it may
  # be unknown at plan time without making the rule set itself unknown. The key
  # is the static string below precisely so that stays true.
  #
  # No cycle: the control-plane and gpu groups gain a dependency on the
  # jumphost VM, which depends on the JUMPHOST group, the subnet and its own
  # disk -- none of which reference these two groups.
  jumphost_ssh_rule = {
    "ssh-jumphost" = {
      protocol  = "TCP"
      port      = 22
      end_port  = null
      remote_ip = "${evroc_virtual_machine.jumphost.private_ipv4_address}/32"
    }
  }

  # Egress is wide open on every group: nothing in this module tries to
  # constrain outbound traffic, only inbound.
  egress_all_rules = {
    tcp = { protocol = "TCP", port = 0, end_port = null, remote_ip = "0.0.0.0/0" }
    udp = { protocol = "UDP", port = 0, end_port = null, remote_ip = "0.0.0.0/0" }
  }

  # RKE2's own intra-cluster ports: etcd client+peer+metrics, kubelet, the
  # canal/flannel VXLAN overlay, and the NodePort range. These are needed
  # between control-plane members, and between control-plane and gpu nodes
  # (kubelet/vxlan/nodeport only -- gpu nodes run no etcd).
  #
  # The natural expression would be `remote_security_group` pointing at the
  # OTHER group -- gpu's rules citing control_plane's fqid and vice versa.
  # That does not work here: a security group cannot reference its own fqid
  # from within its own rule set (every rule in local.control_plane_rules_all
  # below is an argument of evroc_security_group.control_plane itself, so
  # "from the control-plane group itself" is a self-reference, which
  # Terraform cannot resolve -- a resource's config cannot depend on its own
  # computed attribute). And having control_plane cite gpu.fqid WHILE gpu
  # cites control_plane.fqid is a two-resource cycle in the dependency graph,
  # which Terraform rejects outright regardless of how the provider models
  # rules.
  #
  # So these cite var.vpc_cidr instead: it references a variable, not a
  # resource, so neither a self-reference nor a cross-group cycle is possible.
  #
  # vpc_cidr, NOT the per-zone subnet CIDRs. The nodes are spread across one
  # subnet per zone now (network.tf), so no single subnet range covers the
  # cluster, and a rule per (port, zone) would be the literal translation --
  # four rules becoming twelve, and every one of them re-derived whenever the
  # zone list changes. The supernet is the same statement in one rule: every
  # subnet this module creates is carved out of vpc_cidr by construction
  # (locals.tf's subnet_cidrs), so "from anywhere in the VPC" and "from any of
  # our subnets" differ only by the unallocated remainder of the range -- which
  # has no addresses in it, because nothing but these subnets is allocated from
  # it. The rules stay private to the VPC either way; this does not widen them
  # toward the internet.
  intra_cluster_rules = {
    etcd     = { protocol = "TCP", port = 2379, end_port = 2381, remote_ip = var.vpc_cidr }
    kubelet  = { protocol = "TCP", port = 10250, end_port = null, remote_ip = var.vpc_cidr }
    vxlan    = { protocol = "UDP", port = 8472, end_port = null, remote_ip = var.vpc_cidr }
    nodeport = { protocol = "TCP", port = 30000, end_port = 32767, remote_ip = var.vpc_cidr }
  }

  # gpu nodes need the same four rules minus etcd (they run no etcd member).
  gpu_intra_cluster_rules = {
    for k, v in local.intra_cluster_rules : k => v if k != "etcd"
  }
}

# --- jumphost --------------------------------------------------------------
#
# The sole public admin entrypoint. SSH from admin_cidrs in, everything out.
resource "evroc_security_group" "jumphost" {
  name        = "${var.cluster_name}-jumphost"
  vpc_ref     = evroc_vpc.this.fqid
  project     = var.project
  region      = var.region
  user_labels = merge(local.common_labels, { "role" = "jumphost" })

  dynamic "rule" {
    for_each = local.admin_ssh_rules
    content {
      name      = rule.key
      direction = "Ingress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}

# --- builders --------------------------------------------------------------
#
# The non-primary build hosts (image-build.tf's evroc_virtual_machine.builder),
# one per zone after the first. They have no public IP, so unlike the jumphost
# they get NO admin_ssh_rules: an operator's own prefix can never be the source
# address of a connection to them. The only way in is a tunnel through the
# jumphost, and this group says exactly that and nothing more.
#
# Egress is still wide open -- a builder has to podman-pull the elemental image
# like any other build host, and evroc gives it outbound internet access
# without a public IP.
#
# This is a SEPARATE group from the jumphost's, and it has to be. The rule
# below reads evroc_virtual_machine.jumphost, and the builders read this group;
# folding the builders into evroc_virtual_machine.jumphost as extra for_each
# instances would make that one resource both depend on and be depended on by
# one security group. Terraform tracks those edges per RESOURCE, not per
# instance, so it sees a cycle and refuses to plan -- see the header comment in
# image-build.tf.
resource "evroc_security_group" "builder" {
  count = length(local.builder_zones) > 0 ? 1 : 0

  name        = "${var.cluster_name}-builder"
  vpc_ref     = evroc_vpc.this.fqid
  project     = var.project
  region      = var.region
  user_labels = merge(local.common_labels, { "role" = "builder" })

  rule {
    name      = "ssh-jumphost"
    direction = "Ingress"
    protocol  = "TCP"
    port      = 22
    end_port  = null
    remote_ip = "${evroc_virtual_machine.jumphost.private_ipv4_address}/32"
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}

# --- control plane -----------------------------------------------------
locals {
  # 6443/9345 are open to the internet because that is exactly what the load
  # balancer needs: it health-checks and forwards to these ports from outside
  # the VPC, and evroc has no "allow from this load balancer only" selector to
  # narrow it further.
  control_plane_lb_rules = {
    kube_api   = { protocol = "TCP", port = 6443, end_port = null, remote_ip = "0.0.0.0/0" }
    supervisor = { protocol = "TCP", port = 9345, end_port = null, remote_ip = "0.0.0.0/0" }
  }

  # The ingress controller's own hostPorts (80/443, opened to ingress_cidrs
  # rather than the world) plus the load balancer's dedicated ingress
  # health-check port. 8080 has to be open to 0.0.0.0/0, not just
  # ingress_cidrs, because the health checker itself dials it -- see
  # loadbalancer.tf for why the check uses 8080 instead of 80/443 directly.
  control_plane_ingress_rules = var.ingress_controller == "none" ? {} : merge(
    {
      for cidr in var.ingress_cidrs :
      "http-${replace(cidr, "/", "_")}" => { protocol = "TCP", port = 80, end_port = null, remote_ip = cidr }
    },
    {
      for cidr in var.ingress_cidrs :
      "https-${replace(cidr, "/", "_")}" => { protocol = "TCP", port = 443, end_port = null, remote_ip = cidr }
    },
    {
      "ingress-lb-health-check" = { protocol = "TCP", port = 8080, end_port = null, remote_ip = "0.0.0.0/0" }
    },
  )

  control_plane_ingress_rules_all = merge(
    local.admin_ssh_rules,
    local.jumphost_ssh_rule,
    local.control_plane_lb_rules,
    local.intra_cluster_rules,
    local.control_plane_ingress_rules,
  )
}

resource "evroc_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  vpc_ref     = evroc_vpc.this.fqid
  project     = var.project
  region      = var.region
  user_labels = merge(local.common_labels, { "role" = "control-plane" })

  dynamic "rule" {
    for_each = local.control_plane_ingress_rules_all
    content {
      name      = rule.key
      direction = "Ingress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}

# --- gpu -------------------------------------------------------------------
#
# Only created when there is at least one pool to attach it to; gpu-nodes.tf
# (owned elsewhere) is expected to reference it as
# `one(evroc_security_group.gpu[*].fqid)`.
locals {
  gpu_ingress_rules_all = merge(
    local.admin_ssh_rules,
    local.jumphost_ssh_rule,
    local.gpu_intra_cluster_rules,
  )
}

resource "evroc_security_group" "gpu" {
  count = length(var.gpu_pools) > 0 ? 1 : 0

  name    = "${var.cluster_name}-gpu"
  vpc_ref = evroc_vpc.this.fqid
  project = var.project
  region  = var.region

  # No `pool` label: this is ONE group shared by every GPU pool in the cluster
  # (count = 1, not one per pool), so naming a pool here would be a lie.
  user_labels = merge(local.common_labels, { "role" = "gpu" })

  dynamic "rule" {
    for_each = local.gpu_ingress_rules_all
    content {
      name      = rule.key
      direction = "Ingress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}
