variable "region" {
  type        = string
  default     = null
  description = "evroc region to deploy into. Left null by default so the provider's own configured region wins; set it here only to pin a region explicitly for this module instance, independent of the provider block."
}

variable "zones" {
  type        = list(string)
  default     = ["a", "b", "c"]
  description = <<-EOT
    evroc zones, within region, that the cluster spans. Control-plane nodes are
    assigned round-robin across this list in order, so three zones and the
    default control_plane_count = 3 puts exactly one etcd member in each --
    which is the point: a placement group only protects against a single host
    failing, while a zone is the unit evroc loses as a whole.

    Every zonal resource is created per zone: one subnet each (their CIDRs are
    derived from vpc_cidr, see subnet_newbits), one control-plane placement
    group each, and each node's disk alongside the VM it boots. Only the
    genuinely regional resources -- VPC, load balancer, backend pool, public
    IPs, security groups -- are created once and shared, which is what lets a
    single load balancer front backends in every zone.

    WHAT THIS LIST COSTS, and the one thing worth knowing before raising it:
    evroc SNAPSHOTS ARE ZONAL. A disk cannot be created from a snapshot whose
    source disk lived in another zone -- the provider schema hides this (there
    is only a `region` attribute) but disk-webhook.evroc.com enforces it, and
    evroc's docs are explicit: "If you need disks in different zones, you would
    need to create separate snapshots from disks in those respective zones."

    There is no snapshot-copy or cross-zone clone in the provider, so the image
    cannot be built once and fanned out. Each zone gets its OWN build host, its
    own image-target disk and its own snapshot, and each runs a full elemental
    build. Three zones therefore means three concurrent builds and three
    temporary build hosts rather than one. They run in parallel, so wall-clock
    build time is roughly unchanged; the cost is compute, not waiting.

    Only zones[0]'s build host gets a public IP -- a default evroc project
    allows three and the API VIP holds one. The rest reach the internet through
    the VPC's own outbound path and are reached by tunnelling through that one
    host. See locals.tf's primary_zone.

    Those builds are independent, and nothing verifies they produced the same
    software: an OCI tag that moves mid-build hands one zone something
    different, silently. Comparing the built images cannot detect it -- an
    elemental raw is not reproducible, so the sums always differ. Pin
    elemental_image, core_platform_override and sysext_image_overrides to
    digests rather than tags if that matters, which PREVENTS the divergence
    instead of detecting it. See scripts/wait-for-image.sh.

    Set this to a single zone (e.g. ["a"]) for a single-AZ cluster: one build
    host, one snapshot, no independent-build concern at all, and the
    round-robin degenerates to "everything in that zone". That is the cheaper shape and it is the right
    one if a zone loss is not in scope. Note also that RKE2's etcd is
    latency-sensitive: evroc's zones are close enough for spreading to be the
    better trade, but a deployment that cares more about write latency than
    about surviving a zone loss should say so with a one-element list.
  EOT

  validation {
    condition     = length(var.zones) > 0
    error_message = "zones must list at least one zone."
  }

  validation {
    condition     = length(distinct(var.zones)) == length(var.zones)
    error_message = "zones must not repeat a zone -- each entry gets its own subnet and placement group, and a duplicate would collide on both names."
  }

  validation {
    condition     = alltrue([for z in var.zones : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", z))])
    error_message = "Every zone must be 1-16 characters of lowercase alphanumerics and hyphens, not starting or ending with a hyphen -- it becomes part of a subnet and placement-group name. evroc's zones are \"a\", \"b\" and \"c\"."
  }
}

variable "project" {
  type        = string
  default     = null
  description = "evroc project to create resources in. Left null by default so the provider's own configured project wins."
}

variable "elemental_image" {
  type        = string
  default     = "registry.suse.com/beta/uc/elemental:3.1.0-6.5"
  description = "Container image passed to `podman run ... customize` on the jumphost. The default is a SUSE beta build, not the released elemental/elemental:3.0 tag -- that one predates apiVIPMode support and would deploy MetalLB regardless of api_vip_mode. Being a beta, it carries no stability guarantee; revisit once 3.1.0 ships as a stable tag. `registry.opensuse.org/devel/unifiedcore/tumbleweed/containers/elemental:latest` is a verified fallback."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the jumphost on 22/tcp. No default: 0.0.0.0/0 would be an open SSH door, and [] would silently lock everyone out."

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must contain at least one CIDR block."
  }

  validation {
    # security-groups.tf feeds every entry straight into a rule's remote_ip;
    # an entry with no prefix (e.g. "1.2.3.4" instead of "1.2.3.4/32") would
    # reach evroc's API as a malformed CIDR and fail at apply time with a
    # provider error, instead of a clear one here at plan time.
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Every admin_cidrs entry must be a CIDR block with an explicit prefix, e.g. \"203.0.113.1/32\"."
  }
}

variable "root_password_hash" {
  type        = string
  sensitive   = true
  description = "Password hash (e.g. from `openssl passwd -6`) set as passwd.users[root].password_hash in the image's butane.yaml, which elemental bakes in as /usr/lib/ignition/base.d/90-butane.ign. Because it is part of the image, changing it rebuilds the image and replaces every node. No default: without it there is no console login on any node at all."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "Public keys injected onto every node that takes SSH access: the elemental nodes via the image's butane.yaml (onto var.node_username always, and onto root as well when var.permit_root_ssh is true), and the jumphost via cloud-init's own ssh_authorized_keys (it runs plain openSUSE, not elemental). Rotating a key therefore rebuilds the image and replaces every node. No default: without at least one key, nothing has a way into any of them except the console."

  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "ssh_authorized_keys must contain at least one public key."
  }
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login created on every elemental node by the image's butane.yaml, carrying var.ssh_authorized_keys and var.node_user_password_hash. This is the account SSH is meant to land on: root login over SSH is off unless var.permit_root_ssh is set. Escalate with `su -` and the root password -- deliberately not sudo, which is not installed in the elemental OS image (no sudo binary, no wheel group, no sudoers rules). Distinct from var.jumphost_username, which cloud-init creates on the jumphost and which DOES get passwordless sudo. Changing this rebuilds the image and replaces every node."

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.node_username))
    error_message = "node_username must be a valid POSIX user name: lowercase, starting with a letter or underscore, at most 32 characters."
  }

  validation {
    condition     = var.node_username != "root"
    error_message = "node_username must not be \"root\": root is configured separately, from root_password_hash and permit_root_ssh."
  }
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Password hash (e.g. from `openssl passwd -6`) for var.node_username on every elemental node. Required and required to differ from root_password_hash: the whole point of the account is that the credential which gets you a shell is not the credential which gets you root. Like every other value in the image, changing it rebuilds the image and replaces every node."

  validation {
    # Terraform 1.9+ lets a validation read another variable, and there is no
    # cycle here because root_password_hash has no validation of its own.
    condition     = var.node_user_password_hash != var.root_password_hash
    error_message = "node_user_password_hash must differ from root_password_hash -- otherwise the unprivileged account and root share one credential and the split buys nothing."
  }
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Whether sshd on the elemental nodes accepts root logins (PermitRootLogin, written into /etc/ssh/sshd_config.d/sshd.conf) and whether root also receives var.ssh_authorized_keys. Off by default: log in as var.node_username and `su -`. Turning it on is a legitimate choice for a throwaway cluster -- it is the shortest path for the `ssh root@<node>` recipes throughout the docs -- but it is an image-wide setting, so flipping it rebuilds the image and replaces every node. Root always keeps root_password_hash for console login regardless."
}

variable "appco_username" {
  type        = string
  sensitive   = true
  description = "SUSE Application Collection username. Used to authenticate the local-path-provisioner Helm chart pull (release.yaml) and the image pull secret in kubernetes/manifests/local-path-provisioner.yaml, and written into kubernetes/helm/values/aif-operator.yaml's credentials.applicationCollection.username."
}

variable "appco_password" {
  type        = string
  sensitive   = true
  description = "SUSE Application Collection password/token, paired with appco_username."
}

variable "appco_registry" {
  type        = string
  default     = "dp.apps.rancher.io"
  description = "Container registry host the local-path-provisioner image pull secret authenticates against. The release manifest's only stated Application Collection endpoint is the Helm OCI repository oci://dp.apps.rancher.io/charts; this assumes the container images referenced by that chart are served from the same host, since Application Collection does not publish a separate documented registry host for images. Override if that assumption turns out to be wrong."
}

variable "suse_registration_code" {
  type        = string
  sensitive   = true
  description = "SUSE registration code, written as kubernetes/helm/values/aif-operator.yaml's credentials.suseRegistry.username -- per SUSE's own convention, the registry \"username\" for this registry is always the registration code itself."
}

variable "suse_registry_password" {
  type        = string
  sensitive   = true
  description = "Password paired with suse_registration_code for the SUSE registry, written into aif-operator.yaml's credentials.suseRegistry.password."
}

variable "nvidia_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NVIDIA NGC API key, written into aif-operator.yaml's credentials.nvidia.password. Optional: when null, the whole nvidia: credentials block is omitted from aif-operator.yaml rather than written with an empty password. The paired username, when the block is present, is always the literal string \"$oauthtoken\" -- NGC's own convention, not a secret -- so it is hardcoded in the template rather than exposed as a variable."
}

variable "components" {
  type        = list(string)
  default     = ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
  description = "Which SUSE AI Factory Helm charts release.yaml enables. Rendered in a fixed CANONICAL order -- cert-manager, rancher, gpu-operator, local-path-provisioner | suse-storage, aif-operator -- never the order given here (see locals.tf's component_spec/enabled_components); that is what makes this default list render release.yaml byte-for-byte identical to what this module shipped before this variable existed, so upgrading the module alone does not force an image rebuild. `cert-manager` is accepted here but never required as an explicit entry -- it is injected automatically whenever `rancher` is selected, because elemental's own dependency resolution (`internal/config/helm.go`'s `enabledHelmCharts`/`addChart`) already walks the AIF manifest's `rancher -> cert-manager` and `aif-operator -> rancher` `dependsOn` edges and inserts a dependency before its dependent -- naming it here too would only risk contradicting that. `suse-storage` (Longhorn) needs no `components.systemd` entry either: its chart declares a sysext `dependsOn` and elemental's `internal/config/systemd_sysext.go` (`enabledExtensions`/`isDependency`) auto-enables the extension the manifest already ships for it. Changing this list changes release.yaml, which is in local.elemental_files and therefore rebuilds the image and replaces every node -- inherent, since the chart set is baked into the image. Not validated, deliberately: `gpu-operator` against the presence of a GPU pool -- either order is a legitimate intermediate state (pools provisioned before the operator while GPU stock is chased, or the operator enabled before any pool exists)."

  validation {
    condition = alltrue([
      for c in var.components : contains(
        ["cert-manager", "rancher", "gpu-operator", "local-path-provisioner", "suse-storage", "aif-operator"],
        c
      )
    ])
    error_message = "components entries must be one of: cert-manager, rancher, gpu-operator, local-path-provisioner, suse-storage, aif-operator."
  }

  validation {
    condition     = length(var.components) == length(distinct(var.components))
    error_message = "components must not contain duplicate entries."
  }

  validation {
    # Both make themselves the default StorageClass -- the release manifest's
    # own comments warn about running the two together twice over.
    condition     = !(contains(var.components, "local-path-provisioner") && contains(var.components, "suse-storage"))
    error_message = "components cannot list both local-path-provisioner and suse-storage -- both set themselves as the default StorageClass."
  }

  validation {
    condition     = !contains(var.components, "aif-operator") || contains(var.components, "rancher")
    error_message = "components lists aif-operator without rancher -- the AIF release manifest declares aif-operator -> rancher as a chart dependency."
  }

  validation {
    condition     = !contains(var.components, "aif-operator") || contains(var.components, "local-path-provisioner") || contains(var.components, "suse-storage")
    error_message = "components lists aif-operator without a storage chart -- add local-path-provisioner or suse-storage."
  }
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Hostname written into kubernetes/helm/values/rancher.yaml. Defaults to \"rancher-<api_vip>.sslip.io\" (computed in locals.tf) when null -- sslip.io resolves the embedded address, so Rancher has a working ingress host with no DNS of your own. It points at api_vip specifically because evroc's single load balancer (loadbalancer.tf) answers both the Kubernetes API and the ingress ports on the same public IP -- there is no separate ingress address to prefer here."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin bootstrap password, written into kubernetes/helm/values/rancher.yaml. Defaults to a generated random_password (see outputs.rancher_bootstrap_password) when null."
}

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix used to build resource labels and node hostnames (\"<cluster_name>-cp-NN\", \"<cluster_name>-<pool>-NN\")."

  validation {
    # Feeds kubernetes/cluster.yaml's nodes[].hostname, which elemental
    # validates as a hostname; catching an invalid value here beats failing
    # ~20 minutes into a jumphost build.
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a valid DNS label: lowercase alphanumeric and hyphens only, not starting or ending with a hyphen."
  }
}

variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "IPv4 CIDR block of the cluster VPC. Explicit, not auto-selected, so the range is reviewable in a diff. Must not overlap RKE2's default cluster-cidr (10.42.0.0/16) or service-cidr (10.43.0.0/16) -- see the validation below. The per-zone subnets are carved out of this range; see subnet_newbits."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, e.g. \"10.20.0.0/16\"."
  }

  validation {
    # A VPC range like 10.42.0.0/20 sits INSIDE RKE2's default cluster-cidr of
    # 10.42.0.0/16, and the result is subtle: the init node comes up with
    # `flannel.1: 10.42.0.0/32`, i.e. flannel has allocated itself the pod
    # subnet 10.42.0.0/24 -- potentially the same /24 that holds the VPC
    # addresses of the jumphost and the control-plane nodes. The connected
    # /20 route on the VPC NIC is more specific than flannel's /16, so
    # node-to-node VPC traffic survives; but every pod veth installs a /32,
    # which beats the /20. So the cluster stays up and then loses individual
    # VPC peers one at a time as pods happen to be allocated their addresses
    # -- intermittent, host-specific, and nearly impossible to read as an
    # addressing conflict from any single node's point of view.
    #
    # Validated rather than merely documented because the failure does not
    # look like a misconfiguration from any node's point of view.
    condition = tonumber(split("/", var.vpc_cidr)[1]) >= 16 && !contains(
      ["10.42.0.0", "10.43.0.0"],
      cidrhost("${split("/", var.vpc_cidr)[0]}/16", 0)
    )
    error_message = "vpc_cidr must be a /16 or smaller and must not fall within 10.42.0.0/16 (RKE2's default cluster-cidr) or 10.43.0.0/16 (its default service-cidr). Pick a range outside both, e.g. 10.20.0.0/16."
  }
}

variable "subnet_newbits" {
  type        = number
  default     = 4
  description = <<-EOT
    How many bits to add to vpc_cidr's prefix when carving one subnet per zone.
    The subnet for zones[i] is cidrsubnet(vpc_cidr, subnet_newbits, i), so the
    default -- a /16 VPC plus 4 bits -- gives 10.20.0.0/20, 10.20.16.0/20 and
    10.20.32.0/20 for zones a, b and c. See the subnet_cidrs output for the
    values a given configuration actually produces.

    DERIVED rather than a list of literal CIDRs, which is a deliberate reversal
    of this module's usual preference for explicit values. With one subnet an
    explicit CIDR was reviewable in a diff and could be checked for containment
    in one validation. With one per zone, a hand-written list has to be checked
    for containment AND for mutual overlap AND for having exactly as many
    entries as zones, and every one of those is an error an operator can
    plausibly make while editing an unrelated line. cidrsubnet() cannot produce
    an overlap or a gap, and the plan still shows every resulting CIDR.

    Every node -- jumphost, control plane, GPU -- lives in exactly one of these
    subnets, on one NIC. There is no dual-homing anywhere in this design; a
    node in zone b simply has an address out of zone b's range.
  EOT

  validation {
    condition     = var.subnet_newbits >= 1 && floor(var.subnet_newbits) == var.subnet_newbits
    error_message = "subnet_newbits must be a positive whole number."
  }

  validation {
    # evroc rejects a subnet prefix outside /16../29, and cidrsubnet() itself
    # would happily produce a /30. Catching it here names the variable that
    # caused it instead of surfacing an API error on the subnet resource.
    condition = (
      tonumber(split("/", var.vpc_cidr)[1]) + var.subnet_newbits >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) + var.subnet_newbits <= 29
    )
    error_message = "vpc_cidr's prefix plus subnet_newbits must land between /16 and /29, the range evroc accepts for a subnet. With a ${split("/", var.vpc_cidr)[1]}-bit VPC prefix, subnet_newbits must be between ${16 - tonumber(split("/", var.vpc_cidr)[1])} and ${29 - tonumber(split("/", var.vpc_cidr)[1])}."
  }

  validation {
    condition     = pow(2, var.subnet_newbits) >= length(var.zones)
    error_message = "subnet_newbits = ${var.subnet_newbits} only divides vpc_cidr into ${pow(2, var.subnet_newbits)} subnets, but zones lists ${length(var.zones)}. Raise subnet_newbits."
  }
}

variable "vpc_mtu" {
  type        = number
  default     = 8900
  description = "MTU set on the VPC network adapters. 8900 is evroc's measured value -- the platform hands eth0 a jumbo MTU over DHCP -- not the 1500 a VPC would conventionally use. configure-network.sh applies this to the node's NIC directly; the pod veth MTU (local.pod_veth_mtu) follows as vpc_mtu - 50 for RKE2's VXLAN overlay, which is the number that actually has to be right for pod-to-pod traffic not to fragment silently. Lowering this below the platform's own value is not a safe 'conservative' choice: configure-network.sh SETS the NIC to it, so a 1500 here actively downgrades a link the platform brought up at 8900."
  validation {
    # Upper bound is the largest MTU evroc has been observed to hand out; the
    # lower bound is IPv6's minimum link MTU, below which nothing works at all.
    # The pod veth MTU derived from this (vpc_mtu - 50) must also stay above
    # 1280, which the 1330 floor guarantees.
    condition     = var.vpc_mtu >= 1330 && var.vpc_mtu <= 9000
    error_message = "vpc_mtu must be between 1330 and 9000. evroc brings interfaces up at 8900; setting a lower value here does not merely fail to use the headroom, it reconfigures the NIC downward."
  }
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of control-plane VM nodes. Must stay odd (etcd quorum) and at least 3 (a two-member etcd has no fault tolerance at all). Nodes are assigned round-robin across var.zones, so a count that is a whole multiple of the zone count distributes evenly; 3 nodes over 3 zones -- the default -- puts one etcd member in each. An uneven split still works but concentrates quorum: 5 nodes over 3 zones leaves 2 in zones[0], and losing that zone costs 2 of 5 members, which survives, while 3 nodes over 2 zones leaves 2 in zones[0] and losing it breaks quorum."

  validation {
    condition     = var.control_plane_count >= 3 && var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be odd and at least 3."
  }
}

variable "control_plane_flavor" {
  type        = string
  default     = "c1a.m"
  description = "evroc compute profile for control-plane VMs. The default is a mid-size general-purpose profile: RKE2 plus the AI Factory Helm charts want more headroom than a small profile gives an etcd member. Changing this replaces every control-plane node (flavor changes stop, resize and restart a VM, but this module's placement-group/hostname model treats a flavor change as a full node replacement to keep node sizing uniform across the pool)."
}

variable "jumphost_flavor" {
  type        = string
  default     = "a1a.m"
  description = "evroc compute profile for EVERY build host -- the jumphost and, on a multi-zone cluster, each builder. The build is disk- and network-bound rather than CPU-bound (pull OCI layers, assemble a raw file, dd it), so the binding constraint is var.jumphost_disk_gb, not this. The default is deliberately one size down from a1a.l because this multiplies by the zone count: a default evroc project allows 20 vCPU, and at a1a.l (8 vCPU) three build hosts alone are 24 and never get to exist. At a1a.m (4 vCPU/16GB) three come to 12, and pass 2 -- which destroys the builders before creating nodes -- peaks at the jumphost plus three c1a.m control planes, 16. Size up only with quota to match. Changing this replaces the build hosts, which forces a fresh image build."
}

variable "gpu_zones" {
  type        = list(string)
  default     = ["a"]
  description = <<-EOT
    The zones where evroc permits GPU VMs. This is a PLATFORM limit, not a
    preference, and it is enforced by an admission webhook rather than by
    capacity:

      admission webhook "virtualmachine-webhook.evroc.com" denied the request:
      cannot deploy a GPU VM in zone "b". GPU VMs are currently only supported
      on zone "a"

    Observed 2026-09-22 in se-sto. It bites at APPLY time, after the pool's
    boot disks have already been created, so the module keeps its own copy of
    the rule: unpinned pools are spread only over these zones, and a pool
    pinned elsewhere fails during plan with a message that says why.

    Widen it the day evroc does -- the default here will be wrong before this
    module is. Setting it to var.zones restores the old behaviour of spreading
    GPU pools across every zone.
  EOT

  validation {
    condition     = length(var.gpu_zones) > 0
    error_message = "gpu_zones must list at least one zone. A GPU pool has nowhere to go otherwise."
  }

  validation {
    condition     = alltrue([for z in var.gpu_zones : contains(["a", "b", "c"], z)])
    error_message = "Every gpu_zones entry must be \"a\", \"b\" or \"c\" -- the zones evroc's se-sto region has."
  }
}

variable "gpu_pools" {
  type = map(object({
    flavor             = string
    count              = optional(number, 1)
    zone               = optional(string)
    placement_strategy = optional(string)
  }))
  default     = {}
  description = <<-EOT
    GPU worker pools, keyed by pool name. Defaults to {}, which builds a
    control-plane-only cluster -- the only safe default when GPU-bearing
    profiles sit at the expensive end of any cloud's price list.

    THE MAP KEY IS PART OF NODE IDENTITY. Every node in a pool is named
    "<cluster_name>-<key>-NN", and its role rides in per-node Ignition
    (locals.tf's node_runtime_ignition) keyed by that same hostname -- so
    renaming a pool renames, and therefore replaces, its nodes. "cp" is
    reserved for the control plane.

    Per pool:

      flavor              evroc compute profile, e.g. "gn-l40s.s". Required.
                          THE SIZE IS THE GPU COUNT: .s is 1 GPU, .m is 2, .l
                          is 4, gn-b200.xl is 8, and GPU quota is counted in
                          GPUs per model, so count = 1 on gn-l40s.m already
                          asks for two. See the gpu_quota_request output, which
                          multiplies this out at plan time.
      count               nodes in the pool. Default 1.
      zone                pin every node in the pool to one zone. Must be in
                          BOTH var.zones and var.gpu_zones. Default null, which
                          spreads the pool's nodes round-robin over the zones
                          in both lists -- today that is zone "a" alone, so an
                          unpinned pool is single-zone whether it asked to be
                          or not. Pin it when GPU stock for a flavor only
                          exists in one of several permitted zones, which
                          otherwise surfaces as an out-of-capacity error on an
                          arbitrary subset of the pool's nodes.
      placement_strategy  "spread", "cluster", or null (the default: no
                          placement group at all, leaving the scheduler
                          unconstrained). Per pool rather than module-wide
                          because the right answer differs by workload:

                            spread   anti-affinity -- no two nodes of the pool
                                     on one physical host. For an inference
                                     pool, where each node serves independently
                                     and a host failure should cost one replica
                                     rather than the pool.
                            cluster  affinity -- pack the pool onto as few
                                     hosts/racks as possible for the lowest
                                     inter-node latency. For a training pool
                                     doing collective operations, where the
                                     interconnect is the bottleneck and a host
                                     failure restarts the job anyway.

                          A placement group is ZONAL, so a multi-zone pool gets
                          one per zone it lands in. "cluster" therefore rejects
                          a multi-zone pool outright (see the validation below):
                          packing nodes tightly within each of three zones is
                          not what anyone asking for "cluster" wants.

    GPU nodes boot the same snapshot clone as the control plane. Until
    2026-09-23 they could not: a GPU flavor required spec.source.diskImageRef on
    its boot disk, which a snapshot clone cannot carry, and any non-empty
    gpu_pools failed at VM create with

      Ready: disk is missing DiskImageRef (ProvisioningFailed)

    evroc lifted that restriction and a gn-l40s.s node built from this module's
    snapshot now runs. If a project still returns that error, the pool cannot be
    built there and this variable has to stay {}; PLATFORM-NOTES.md has the
    detail.
  EOT

  validation {
    condition     = alltrue([for k in keys(var.gpu_pools) : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", k))])
    error_message = "Every gpu_pools key must be 1-16 characters of lowercase alphanumerics and hyphens, not starting or ending with a hyphen -- it becomes part of a node hostname."
  }

  validation {
    condition     = !contains(keys(var.gpu_pools), "cp")
    error_message = "\"cp\" is reserved: it is the control plane's own hostname infix, and a pool using it would produce duplicate node names."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_pools : p.count >= 0])
    error_message = "Every gpu_pools count must be >= 0."
  }

  validation {
    condition     = alltrue([for k in keys(var.gpu_pools) : length("${var.cluster_name}-${k}-00") <= 63])
    error_message = "cluster_name plus a pool key must leave the generated hostname \"<cluster_name>-<pool>-NN\" within the 63-character DNS label limit."
  }

  validation {
    # Without this, a typo'd or wrong-family flavor surfaces from
    # availability.tf's live check as "not currently available", which reads
    # as a stock problem rather than a malformed-name one. This only checks
    # that the string is a PLAUSIBLE evroc profile name (family.size, e.g.
    # "c1a.m") -- not that it actually exists, which availability.tf verifies
    # live against the API.
    condition     = alltrue([for k, p in var.gpu_pools : can(regex("^[a-z0-9]+[a-z0-9-]*\\.[a-z0-9]+$", p.flavor))])
    error_message = "Every gpu_pools flavor must look like an evroc compute profile name (\"<family>.<size>\", e.g. \"c1a.m\")."
  }

  validation {
    # A pool can only be pinned to a zone this module built a subnet in --
    # there is nothing for a node in an unlisted zone to attach to.
    condition     = alltrue([for k, p in var.gpu_pools : p.zone == null || contains(var.zones, coalesce(p.zone, "-"))])
    error_message = "Every gpu_pools zone must be one of var.zones (${join(", ", var.zones)}) -- this module only creates a subnet and placement group in the zones listed there."
  }

  validation {
    # And, separately, to a zone evroc will run a GPU VM in at all. Caught here
    # rather than by the admission webhook, which rejects the VM only after its
    # boot disk has been created and billed for.
    condition     = alltrue([for k, p in var.gpu_pools : p.zone == null || contains(var.gpu_zones, coalesce(p.zone, "-"))])
    error_message = "Every gpu_pools zone must be one of var.gpu_zones (${join(", ", var.gpu_zones)}). evroc's virtualmachine-webhook rejects a GPU VM in any other zone -- see gpu_zones."
  }

  validation {
    # An unpinned pool lands in setintersection(zones, gpu_zones); empty means
    # there is nowhere legal for it to go, and the round-robin below would
    # divide by zero.
    condition = (
      length(var.gpu_pools) == 0 ||
      length(setintersection(toset(var.zones), toset(var.gpu_zones))) > 0
    )
    error_message = "gpu_pools is non-empty but none of var.zones (${join(", ", var.zones)}) is a GPU zone (${join(", ", var.gpu_zones)}). Add a GPU zone to var.zones -- a GPU node also needs a subnet and an image snapshot in its own zone."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_pools : p.placement_strategy == null || contains(["spread", "cluster"], coalesce(p.placement_strategy, "-"))])
    error_message = "Every gpu_pools placement_strategy must be \"spread\", \"cluster\", or omitted (no placement group). Those are the only two strategies evroc_placement_group accepts."
  }

  validation {
    # "cluster" means "pack these nodes as close together as possible", which
    # a placement group can only do within one zone. Spread the same pool over
    # three zones and it becomes "pack each third tightly, then separate the
    # thirds by a datacentre" -- the opposite of the request, and silent.
    #
    # The zone count that matters is setintersection(zones, gpu_zones), NOT
    # length(var.zones): an unpinned pool is round-robined over
    # local.gpu_zones_usable (locals.tf), because evroc's webhook refuses a GPU
    # VM outside var.gpu_zones. Testing var.zones instead rejects the module's
    # OWN defaults -- zones = ["a","b","c"] with gpu_zones = ["a"] leaves
    # exactly one usable zone, so an unpinned "cluster" pool is already
    # confined to it and is precisely what this validation means to allow.
    condition = alltrue([
      for k, p in var.gpu_pools :
      p.placement_strategy != "cluster" || p.zone != null ||
      length(setintersection(toset(var.zones), toset(var.gpu_zones))) == 1
    ])
    error_message = "A gpu_pools entry with placement_strategy = \"cluster\" must also set zone, unless only one GPU-capable zone is in play (setintersection(var.zones, var.gpu_zones) holds exactly one). Placement groups are zonal, so a multi-zone \"cluster\" pool would be packed tightly within each zone and then spread across them -- which is not what \"cluster\" asks for."
  }
}

variable "jumphost_disk_gb" {
  type        = number
  default     = 200
  description = "Size, in GB, of the jumphost's own boot disk. Holds the jumphost's OS plus every OCI layer `elemental customize` pulls -- it does NOT hold the raw image being built, which is written to the separate image_target disk (image_target_disk_gb). Size up if the chart/extension set grows enough to strain the podman storage budget."
}

variable "retain_image_target_disks" {
  type        = bool
  default     = true
  description = <<-EOT
    Keep the image_target disks after their snapshots exist. Set false to
    reclaim them -- image_target_disk_gb per zone, 96 GB on a default
    three-zone cluster -- once nothing needs them any more.

    KEPT BY DEFAULT ON AN UNVERIFIED DEPENDENCY. Deleting a snapshot's source
    disk is permitted, and the snapshot stays Ready, keeps its restore_size and
    still creates disks (verified 2026-09-22 -- PLATFORM-NOTES.md). What has
    never been tested is BOOTING one of those disks: the probe disk was created
    and never started, and no node has been built from a snapshot whose source
    was already gone. The module defaults to true because flipping it in the
    wrong apply races (below); examples/ha-cluster/deploy.sh, which sequences
    it safely, reclaims by default unless --keep-build-disks is passed.

    Verify it if the storage matters: reclaim, then build one node from the
    snapshot and watch it boot. That single test is what would let this default
    flip.

    FLIP IT IN AN APPLY OF ITS OWN, AFTER THE SNAPSHOTS EXIST IN STATE. Setting
    this false in the SAME apply that flips image_ready true asks Terraform to
    create the snapshots and destroy the disks they are taken FROM at the same
    time, and their relative order is not something the dependency graph pins
    down. Lose that race and the snapshot is taken from a disk that is already
    gone: the apply fails, the built image no longer exists anywhere, and the
    only way forward is a full rebuild. deploy.sh does
    the sequencing for you; it is a third apply after pass 2, not part of it.

    For the same reason, do not set this false in terraform.tfvars, where it
    would persist into the next --rebuild's pass 2 and reproduce exactly that
    race. deploy.sh writes it to pass2.auto.tfvars.json, which is reset before
    every pass 1.

    A later pass 1 (image_ready = false) recreates the disks regardless of this
    setting -- a rebuild has to have somewhere to write.
  EOT
}

variable "disk_create_timeout" {
  type        = string
  default     = "30m"
  description = <<-EOT
    How long to wait for an evroc_disk to report Ready before giving up. Applies
    to every disk this module creates: the build hosts' OS disks, the
    image_target disks and every node's boot disk.

    The provider's own default is 10 minutes, which is not enough. Observed
    2026-09-22 on a three-zone cluster: two 200 GB builder disks came Ready in
    well under that and the third, identical but in zone "c", did not --

      Error: error waiting for disk <cluster>-builder-boot-c to be ready:
      timeout after 10m0s (attempted 25 times)

    Nothing was wrong with the request. Disk provisioning time varies by zone
    and by how busy the platform is, and the apply had already been running for
    ten minutes when it gave up, with a jumphost and two other disks created.

    A TIMEOUT HERE IS EXPENSIVE, which is why the default is generous. The
    provider records the half-created disk as TAINTED, so the next apply
    destroys and recreates it -- paying the provisioning time again, on a
    resource that was very likely about to finish. Waiting costs nothing but
    wall clock; timing out costs the whole attempt.

    Terraform duration string: "30m", "1h", "90s".
  EOT

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(s|m|h)$", var.disk_create_timeout))
    error_message = "disk_create_timeout must be a Terraform duration string such as \"30m\", \"90s\" or \"1h\"."
  }
}

variable "disk_delete_timeout" {
  type        = string
  default     = "20m"
  description = <<-EOT
    How long to wait for an evroc_disk to be deleted. The provider's default is
    the same 10 minutes it allows for a create.

    Separate from disk_create_timeout because the case that needs it is the
    aftermath of the other one: a disk wedged partway through provisioning
    (2026-09-22, a builder disk stuck at ImportScheduled in one zone while its
    twin in another zone was Ready in two minutes) still has to be destroyed,
    and a delete that times out leaves the resource in state, the object on the
    platform, and the apply unable to make progress in either direction.

    Terraform duration string: "20m", "1h", "90s".
  EOT

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(s|m|h)$", var.disk_delete_timeout))
    error_message = "disk_delete_timeout must be a Terraform duration string such as \"20m\", \"90s\" or \"1h\"."
  }
}

variable "image_target_disk_gb" {
  type        = number
  default     = 32
  description = "Size, in GB, of the blank disk (image_target) `elemental customize` writes the raw image onto during the build, and which is later snapshotted once image_ready is true. Must be at least the GB-equivalent of image_disk_size -- see the validation below. Changing this destroys and recreates image_target (a disk size change forces recreation), which forces a fresh image build."

  validation {
    # image_disk_size is validated elsewhere as <positive integer><K|M|G|T>;
    # this converts its unit to a GiB-equivalent GB figure and catches an
    # image_target too small to hold the raw image at PLAN time, instead of
    # partway into a jumphost build when `elemental customize` runs out of
    # space on the target disk.
    condition = var.image_target_disk_gb >= ceil(
      tonumber(substr(var.image_disk_size, 0, length(var.image_disk_size) - 1)) *
      lookup({ K = 1 / 1048576, M = 1 / 1024, G = 1, T = 1024 }, substr(var.image_disk_size, -1, 1), 0)
    )
    error_message = "image_target_disk_gb (${var.image_target_disk_gb}) must be at least the size image_disk_size (${var.image_disk_size}) requests."
  }
}

variable "node_disk_gb" {
  type        = number
  default     = 200
  description = "Size, in GB, of the boot disk created from the built snapshot for every control-plane and GPU node. elemental's firstboot bootstrap expands the partition to fill whatever this provides, so it is not tied to image_disk_size -- see that variable's own description. Changing this replaces every node."
}

variable "image_ready" {
  type        = bool
  default     = false
  description = "Set to true by the deploy script's second pass, once the images have actually finished building. On the FIRST pass, one blank image_target disk per zone is attached to that zone's build host and image-factory.sh writes the customized raw image onto it; this stays false throughout that pass, so nothing tries to snapshot a disk that is still attached and may still be mid-write. On the SECOND pass, with the builds known complete, this flips to true: the attachments are destroyed, which detaches the disks, and only once detached can a snapshot be taken from each with consistent contents. Flipping it back to false (or leaving snapshot_ids empty on a fresh apply) is what forces the two-pass dance to run again."
}

variable "control_plane_public_ip" {
  type        = bool
  default     = false
  description = <<-EOT
    Whether each control-plane node also gets its own public IP.

    NOT for reaching the node: the API, the supervisor and ingress all arrive
    through the load balancer's VIP, and SSH is meant to go via the jumphost.
    It is purely for EGRESS, and it is not needed for that either: evroc
    routes VMs with no public IP through shared NAT gateways, confirmed by
    support and then by a full cluster -- Rancher, cert-manager and the AppCo
    charts all pulled at runtime onto control planes with no address of their
    own (2026-09-22). Hence the false default.

    Turn it on only when something upstream allowlists by source address: a
    node behind the shared gateways has no say in the source IP it presents.

    PUBLIC IPs ARE A QUOTA'D RESOURCE, and a small one -- a default evroc
    project allows 3, and this module spends two before any node gets one (the
    API VIP and the jumphost). So `true` here cannot succeed on a default
    quota: three control-plane nodes ask for three more and evroc rejects them
    with "not enough quota ... (out of 3)" partway through the apply. Raise the
    quota first.
  EOT
}

variable "gpu_public_ip" {
  type        = bool
  default     = false
  description = <<-EOT
    Whether each GPU worker node gets its own public IP. Same egress-only
    purpose and same quota pressure as control_plane_public_ip -- see that
    variable.

    Separate from it because the exposure is not equivalent. A control-plane
    node is reachable through the load balancer whatever this is set to, so
    denying it a public IP costs nothing at all. A GPU node with no public IP
    is reachable only from inside the VPC, which is strictly the better
    posture, and the GPU operator's driver containers still pull out through
    the shared NAT gateways.
  EOT
}

variable "user_labels" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    Extra user_labels merged onto every resource this module creates that
    supports them, on top of the set it always applies (local.common_labels):
    cluster, managed-by, module and created, plus a per-resource role -- and
    pool, listener or build where those apply. Merged LAST, so a key here
    overrides the module's own value for it.

    Purely organizational; evroc labels carry no functional behavior. The one
    exception is compute-experimental-features-UEFI on the node VMs, which is a
    real feature flag the image cannot boot without -- do not shadow it.

    evroc_snapshot accepts no labels at all, so snapshots are identifiable only
    by name (cluster + build timestamp + zone).
  EOT

  validation {
    # evroc's API is Kubernetes-shaped and enforces Kubernetes label syntax, so
    # a stray colon, slash or space fails the APPLY -- on every resource in the
    # module at once, halfway through. Catching it at plan time costs one
    # regex. Keys may carry an optional DNS-subdomain prefix ("example.com/x");
    # values may not, and either may be at most 63 characters after the prefix.
    condition = alltrue([
      for k, v in var.user_labels :
      can(regex("^(([a-z0-9]([-a-z0-9.]*[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)$", k))
      && can(regex("^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$", v))
    ])
    error_message = "user_labels keys and values must be Kubernetes-shaped: start and end with an alphanumeric, contain only [-_.] in between, and be at most 63 characters (a key may also carry a \"prefix.example.com/\" DNS prefix). An RFC3339 timestamp is a common offender -- its colons are rejected; use YYYYMMDD-hhmmss."
  }
}

variable "jumphost_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login created on the jumphost by cloud-init, with passwordless sudo, the same ssh_authorized_keys as root and no password login. Jumphost only -- the elemental nodes stay root-only, since an account there would have to be baked into the image. Set to \"\" for a root-only jumphost. Changing this replaces the jumphost, which forces a fresh image build."

  validation {
    condition     = var.jumphost_username == "" || can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.jumphost_username))
    error_message = "jumphost_username must be a valid POSIX user name: lowercase, starting with a letter or underscore, at most 32 characters."
  }
}

variable "jumphost_image" {
  type        = string
  default     = null
  description = "evroc disk image identifier for the jumphost's boot disk. Defaults to openSUSE Leap 15.6 (data.evroc_disk_images.this.opensuse_15_6_1, resolved in locals.tf) when null. Leap 15.6, not 15/16: evroc offers no Leap 16 image, and 15.6 is the newest Leap it does offer. If `elemental customize` misbehaves on it, SLES 15.6 or Ubuntu 24.04 with upstream podman are the documented fallbacks. This is the jumphost's own OS, not the elemental image it builds and boots the other nodes from."
}

variable "ingress_controller" {
  type        = string
  default     = "traefik"
  description = "RKE2's ingress-controller setting, written into kubernetes/config/server.yaml. \"traefik\" (default) also pins the DaemonSet to the control-plane nodes and adds two more listeners (80/443) on this module's own load balancer -- see loadbalancer.tf and kubernetes/manifests/traefik.yaml. \"ingress-nginx\" is the pre-v1.36 RKE2 default but went end-of-life in March 2026 and is removed in v1.37; it gets no pinning, no proxy protocol and no ingress listeners here. \"none\" skips the ingress listeners entirely."

  validation {
    condition     = contains(["none", "traefik", "ingress-nginx"], var.ingress_controller)
    error_message = "ingress_controller must be one of: none, traefik, ingress-nginx."
  }
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress listeners (80/443) on the load balancer. Open by default -- an ingress nobody can reach has no purpose, and this is the address Rancher's UI lives on. Narrow it if the cluster is not meant to serve the public internet."
}

variable "api_host" {
  type        = string
  default     = null
  description = "Elemental network.apiHost, a DNS name for the Kubernetes API that elemental adds to the server certificate's SANs alongside apiVIP. Defaults to \"rke2-<api_vip>.sslip.io\" when null, so a kubeconfig can use a name instead of a bare IP without anyone running a DNS zone. Set to a name you control if you have one; there is no way to switch it off short of pointing it at the apiVIP itself."
}

variable "api_vip_mode" {
  type        = string
  default     = "external"
  description = "Elemental network.apiVIPMode. \"external\" (default) means a user-managed load balancer (this module's own evroc_loadbalancer) owns the API address and MetalLB/ECO are skipped; \"managed\" would hand the address to MetalLB instead, which this design has no use for."

  validation {
    condition     = contains(["managed", "external"], var.api_vip_mode)
    error_message = "api_vip_mode must be one of: managed, external."
  }
}

# SUSE/aif tags per COMPONENT, not per release, and aif-operator's tag is the
# one that tracks the AI Factory version as a whole: aif-operator-2.1.0,
# aif-operator-2.2.0, plus pre-releases aif-operator-2.2.0-rc.1 and
# aif-operator-2.3.0-dev.2. A tag rather than the release-X.Y branch because a
# tag is immutable -- release-2.2's tip can move under a built cluster, an
# aif-operator-2.2.0 tree cannot. aif-operator-2.0.x predates
# uc-release-manifest/ and 404s, so 2.1.0 is the floor.
variable "aif_version" {
  type        = string
  default     = "2.2.0"
  description = "AI Factory version, resolved to the SUSE/aif tag aif-operator-<version> and that tag's uc-release-manifest/release_manifest.yaml. Full X.Y.Z, optionally with a pre-release suffix: \"2.2.0\", \"2.1.0\", \"2.3.0-dev.2\", \"2.2.0-rc.1\". There is no \"2.2\" tag, so there is no \"2.2\" here. Ignored entirely if aif_release_manifest_url is set."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.aif_version))
    error_message = "aif_version must be a full X.Y.Z version, optionally with a pre-release suffix: \"2.2.0\", \"2.3.0-dev.2\". SUSE/aif tags releases as aif-operator-X.Y.Z, so a bare \"2.2\" resolves to no tag."
  }

  # Nothing below 2.1.0 has a manifest at this path, and saying so here beats a
  # 404 from the data source with no hint about why.
  validation {
    condition = (
      tonumber(split(".", split("-", var.aif_version)[0])[0]) > 2 ||
      tonumber(split(".", split("-", var.aif_version)[0])[1]) >= 1
    )
    error_message = "aif_version must be 2.1.0 or newer: SUSE/aif's aif-operator-2.0.x tags have no uc-release-manifest/release_manifest.yaml."
  }
}

variable "aif_release_manifest_url" {
  type        = string
  default     = null
  description = "Release manifest the jumphost curls into the config dir as release_manifest.yaml, referenced by release.yaml as manifestURI: file://./release_manifest.yaml. Leave null (the default) to derive it from aif_version's tag; set it to override that entirely -- a branch or commit URL, or a manifest hosted somewhere else. Either way the content is hashed into the build id, so a far-end change on a moving ref still forces a rebuild; it just won't show in a plan diff of these variables."
}

# Warns rather than fails: the manifest at the requested tag is still the best
# available answer, and upstream's own metadata is what is wrong. This does
# fire in practice -- aif-operator-2.2.0-rc.1 ships a manifest declaring
# metadata.version 2.0.1 -- so the warning is the difference between finding
# that out at plan time and finding it out in a running cluster.
#
# Skipped for an explicit URL, where aif_version is meaningless.
check "aif_version_matches_manifest" {
  assert {
    condition = (
      var.aif_release_manifest_url != null ||
      try(yamldecode(data.http.aif_release_manifest.response_body).metadata.version, "") == var.aif_version
    )
    error_message = "aif_version is \"${var.aif_version}\", but the manifest at tag ${local.aif_tag} declares metadata.version ${try(yamldecode(data.http.aif_release_manifest.response_body).metadata.version, "(unreadable)")} -- and THAT is what will be built. The tag is what was asked for, so this is upstream metadata disagreeing with its own tag; check the manifest before trusting the version number."
  }
}

# Two elemental versions are involved in one build and they have to agree:
# `elemental customize` only writes the media, while the install runs later
# from the OS image's own elemental3ctl. The customize container this module
# needs (3.1.0, for apiVIPMode: external) emits bootloader.initrdExtensions,
# the key that delivers the entire Kubernetes firstboot chain -- and every
# elemental3ctl on the 3.0.x line silently ignores it, producing a node that
# boots perfectly with no Kubernetes on it and no error anywhere. Support
# landed on the 3.1.0 line; a BRANCH difference, so a newer GA build will not
# fix it.
#
# The default manifest chain walks straight into that skew, which is why this
# variable is NOT null by default. AIF 2.2.0's release_manifest.yaml sets
# corePlatform.image to registry.suse.com/elemental/rke2/rke2-manifest:1.35.6-48.1,
# and that manifest pins the OS image to
# registry.suse.com/elemental/base-os-kernel-default-iso:16.0-3.15 -- the GA
# 16.0 line, whose elemental3ctl is 3.0.x. Following the chain therefore builds
# media whose CPIO of Ignition drop-ins the installer then discards. The tell on
# a node built that way: the installer's GRUB title says 16.0 (the beta line is
# 16.1) and every Ignition stage logs `no config dir at
# "/usr/lib/ignition/base.d"`. See PLATFORM-NOTES.md for the full diagnosis.
#
# corePlatform.image can't just be redirected at a local file (the resolver
# hard-forces an oci:// prefix) and no published core platform manifest pins a
# new enough OS image. So this flattens instead: the module writes its own
# schema-v0 core platform manifest with these pins and merges the AIF solution
# manifest's components.systemd and components.helm into it -- a v0 core
# manifest's Components is a superset, so nothing is lost.
#
# Setting it to null is supported and follows the manifest chain, but on AIF
# 2.2 that means the 16.0 OS image and a cluster that never comes up. Do it
# only against a manifest chain you have checked resolves to a 16.1-line image.
variable "core_platform_override" {
  type = object({
    os_image_base      = string
    os_image_iso       = string
    kubernetes_version = string
    kubernetes_image   = string
  })
  default = {
    # The OS images are the whole point of the default: 16.1, the beta line,
    # the one whose elemental3ctl honours initrdExtensions. base and iso are
    # published as independent builds with no common tag, so these are the
    # newest of each rather than a matched pair -- which is harmless, because
    # `elemental customize` extracts the ISO variant and never touches the
    # base. List what exists with:
    #   curl -fsSL "https://scc.suse.com/api/registry/authorize?service=SUSE+Linux+Docker+Registry&scope=repository:beta/uc/base-os-kernel-default-iso:pull"
    # then GET /v2/beta/uc/base-os-kernel-default-iso/tags/list with the token.
    os_image_base = "registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2"
    os_image_iso  = "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-73.3"

    # Kubernetes is deliberately NOT moved to a beta build. These are exactly
    # what AIF 2.2.0's own core platform manifest pins, so the chart set still
    # meets the RKE2 version it was released against. The skew being escaped
    # here lives in the OS image's elemental3ctl and nowhere else.
    kubernetes_version = "v1.35.6+rke2r1"
    kubernetes_image   = "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1"
  }
  description = "Replaces the release manifest chain with a locally-generated core platform manifest pinning these images, keeping the AIF manifest's systemd extensions and helm charts. Defaults to the beta 16.1 OS image because AIF 2.2's chain resolves to a GA 16.0 one whose elemental3ctl ignores initrdExtensions, producing a node that boots fine with no Kubernetes and no error. os_image_iso is the one that matters (customize extracts the ISO variant and never touches the base), but the schema requires both. kubernetes_version is the RKE2 version string (e.g. \"v1.35.6+rke2r1\") and kubernetes_image the matching rke2-tar OCI reference. null follows the manifest chain instead -- only safe against a chain you have checked."

  validation {
    # An OS image whose elemental3ctl predates 3.1.0~alpha.20260909 produces
    # a silently Kubernetes-less node, so pointing this at a GA tag defeats
    # the entire purpose of setting it. Can't check the binary from here, but
    # the GA repo path is a reliable enough proxy to be worth catching.
    condition = var.core_platform_override == null || !can(regex(
      "registry\\.suse\\.com/elemental/base-os-kernel-default",
      var.core_platform_override.os_image_iso
    ))
    error_message = "core_platform_override.os_image_iso points at the GA elemental/ repo, whose newest elemental3ctl (3.0.3) still ignores initrdExtensions -- overriding to it changes nothing. Use a beta/uc/ image."
  }
}

# The sibling of core_platform_override, for the same reason: beta bits. The
# AIF manifest pins each systemd extension's OCI image, and release.yaml can
# only name an extension -- there is no per-extension image field in that
# schema -- so an override has to rewrite the manifest itself. image-factory.sh
# does that in the same Python step that flattens the core platform, and will
# now run for a sysext override alone, with no core override set.
#
# It defaults to the beta longhorn extension rather than to {}, for the same
# reason elemental_image defaults to a beta build: the configuration this
# module is actually flown with is a beta one. core_platform_override now
# defaults to a beta 16.1 OS image, which the manifest's GA-pinned extension
# does not match. Defaulting to {} would mean anyone enabling suse-storage
# inherits that mismatch silently.
#
# Nothing here applies unless an enabled component actually pulls the named
# extension in -- locals.tf filters the map against local.enabled_sysexts, so
# the default is inert on the default (local-path-provisioner) chart set and
# does not even move the build id there. Once it does apply, a name the
# manifest does not declare stops the build early and says so; set this to {}
# against a manifest that does not ship the extension.
variable "sysext_image_overrides" {
  type = map(string)
  default = {
    # Pairs with the beta OS image core_platform_override defaults to. AIF 2.2 pins
    # registry.suse.com/elemental/longhorn:4.111-4.79, which is the GA build.
    suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13"
  }
  description = "Per-extension OCI image overrides applied to the release manifest before `elemental customize` reads it, keyed by the extension's name as the manifest spells it. Defaults to the beta longhorn extension, matching the beta OS image core_platform_override has to select; set to {} to follow the manifest's own pins instead. Only applies to extensions an enabled component pulls in -- the default does nothing until \"suse-storage\" is in var.components, and does not renumber the build until then either. Once it does apply, the named extension must exist in the manifest or the build fails early rather than silently overriding nothing."

  validation {
    condition = alltrue([
      for name in keys(var.sysext_image_overrides) :
      can(regex("^[a-z0-9][a-z0-9._-]*$", name))
    ])
    error_message = "sysext_image_overrides keys must be extension names as the release manifest spells them (lowercase alphanumerics, dots, dashes, underscores) -- e.g. \"suse-storage\"."
  }

  validation {
    # Passed to the build script as a shell single-quoted JSON blob, so a quote
    # or whitespace in the value would break out of it. No legitimate image
    # reference contains either.
    condition = alltrue([
      for image in values(var.sysext_image_overrides) :
      length(image) > 0 && !can(regex("[[:space:]'\"]", image))
    ])
    error_message = "sysext_image_overrides values must be non-empty OCI image references with no whitespace or quote characters."
  }
}

# The two validations above cannot see var.components, and the enablement
# filter in locals.tf deliberately makes an override for an unselected
# component a silent no-op -- which is right for the shipped default
# (suse-storage overridden, local-path-provisioner selected) and wrong for a
# typo, which would also silently do nothing.
#
# A check block distinguishes them: a name this module could never enable is
# almost certainly misspelled, so warn. A name it knows but has not selected is
# the normal case and stays quiet. A warning rather than an error because the
# module cannot be sure -- and because an override is inert either way.
check "sysext_image_overrides_are_known_extensions" {
  assert {
    condition = alltrue([
      for name in keys(var.sysext_image_overrides) :
      contains(local.known_sysexts, name)
    ])
    error_message = "sysext_image_overrides names extension(s) this module never enables: ${join(", ", setsubtract(keys(var.sysext_image_overrides), local.known_sysexts))}. Extensions it can enable: ${join(", ", local.known_sysexts)}. Check the spelling -- the override will otherwise be dropped silently. If the name is right and belongs to an extension no component pulls in, it has to be added to component_spec's sysext field in locals.tf to have any effect."
  }
}

variable "image_disk_size" {
  type        = string
  default     = "8G"
  description = "install.yaml raw.diskSize -- the size of the raw file elemental builds on image_target, not a cap on the node's usable disk: first-boot bootstrap expands the partition to fill whatever node_disk_gb provides. Smaller buys a faster build. The cookbook's own figure is 35G."

  validation {
    # Catches a malformed size (e.g. "35Gi", "35g", "0G") at plan time
    # instead of partway into a jumphost build, when elemental itself
    # rejects install.yaml.
    condition     = can(regex("^[1-9][0-9]*[KMGT]$", var.image_disk_size))
    error_message = "image_disk_size must match <positive integer><K|M|G|T>, e.g. \"35G\"."
  }
}

variable "fips" {
  type        = bool
  default     = false
  description = "Whether install.yaml sets cryptoPolicy: fips. Off by default: the upstream example enables it but warns every node must then be FIPS-ready, which is not a call to make silently on someone's behalf."
}

variable "snapshot_ids" {
  type    = map(string)
  default = {}

  description = <<-EOT
    Override: use already-existing evroc snapshots instead of building any.
    When non-empty, the build hosts, their disks, the wait and the snapshot
    resources all drop out entirely, which is how a redeploy reuses images
    already built.

    A MAP keyed by zone, not a single id, because evroc snapshots are zonal: a
    node's boot disk can only be cloned from a snapshot in that node's own
    zone. Supply one entry for every zone in var.zones -- a single-zone cluster
    therefore takes a single-entry map, e.g. { a = "<fqid>" }.

    This is for adopting a snapshot this module did NOT build. Do not feed it
    the module's own snapshot_ids output: the snapshot resources are gated on
    this being empty, so doing that destroys them while every node's boot disk
    still refers to them. deploy.sh never writes this for exactly that reason.
  EOT

  validation {
    condition     = length(var.snapshot_ids) == 0 || length(setsubtract(toset(var.zones), keys(var.snapshot_ids))) == 0
    error_message = "snapshot_ids, when set, needs an entry for every zone in var.zones -- evroc snapshots are zonal and a node disk cannot clone one from another zone. Missing: ${join(", ", setsubtract(toset(var.zones), keys(var.snapshot_ids)))}."
  }
}

variable "deploy_nodes" {
  type        = bool
  default     = true
  description = "Whether to provision the control-plane and GPU nodes (and, by extension, wait for the image build). false stands up only the network, load balancer and jumphost/image factory on their own."
}

variable "image_build_timeout" {
  type        = number
  default     = 5400
  description = "Seconds the image-build-wait local-exec (scripts/wait-for-image.sh) will poll before giving up. 5400 (90 min) gives headroom over a cold podman pull of the elemental image plus the raw build."
}

variable "verify_flavor_availability" {
  type        = bool
  default     = true
  description = "Whether to run pre-flight checks, during plan, that the chosen compute profiles (control_plane_flavor, jumphost_flavor, every gpu_pools flavor) are actually offered by evroc right now -- see availability.tf. Best-effort: availability can still change between plan and apply."
}
