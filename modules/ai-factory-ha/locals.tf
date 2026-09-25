# Shared RKE2 join token, used by kubernetes/config/{server,agent}.yaml.
# special = false: the value lands verbatim in a YAML scalar in the elemental
# config dir, where a special character would need escaping nobody would add.
resource "random_password" "token" {
  length  = 32
  special = false
}

# Used only when var.rancher_bootstrap_password is null. Always created --
# cheaper than a count/for_each just to keep it referenceable.
resource "random_password" "rancher_bootstrap" {
  length  = 24
  special = false
}

# The cluster's own creation timestamp, stamped into every object's labels
# below so a project holding several clusters -- or the leftovers of one that
# was half-destroyed -- can be sorted by age in the console.
#
# time_static, not timestamp(): timestamp() re-evaluates on every plan, so the
# rendered label would differ from the one in state every single time and every
# apply would propose updating the labels on every object in the project.
#
# The trigger is the cluster name and nothing else. This records when the
# cluster was first stood up and must survive rebuilds, resizes, zone changes
# and image regeneration -- none of those make it a different cluster. A
# changed cluster_name does: every object is named after it, so the whole stack
# is replaced and restarting the clock is correct.
resource "time_static" "created" {
  triggers = {
    cluster = var.cluster_name
  }
}

locals {
  # Every evroc object this module creates carries these four, so a project
  # holding more than one cluster can be read at a glance and filtered by label
  # rather than by guessing at name prefixes:
  #
  #   cluster     which cluster this belongs to -- the one label that has to be
  #               right before anyone can answer "is this safe to delete?"
  #   managed-by  terraform, i.e. do not edit this object by hand
  #   module      which module in this repo created it
  #   created     UTC YYYYMMDD-hhmmss of the first apply for this cluster name
  #
  # Individual resources add `role` on top, plus `pool` or `listener` wherever
  # there is one object per GPU pool or per listener, so the label set alone
  # identifies any object without having to parse its name.
  #
  # Label VALUES are Kubernetes-shaped here -- evroc's API is (see
  # loadbalancer.tf's note on the backend services being real Kubernetes
  # objects) -- so no colons and nothing over 63 characters. That is why
  # `created` is formatted YYYYMMDD-hhmmss rather than carrying the RFC3339
  # instant time_static actually stores: RFC3339 contains colons and would be
  # rejected. var.user_labels is validated against the same shape.
  #
  # `created` is deliberately NOT local.build_id, which is the obvious
  # candidate for "a timestamp". Adding `"build" = local.build_id` to THIS map
  # -- the one every resource reads -- does not merely look redundant, it
  # refuses to plan. Tried, and the error is:
  #
  #   Error: Cycle: local.api_vip, evroc_public_ip.cluster,
  #     local.component_values_files, local.rancher_hostname, local.api_host,
  #     local.common_labels
  #
  # build_id derives from time_static.build, whose triggers reach api_host and
  # so local.api_vip = evroc_public_ip.cluster.ip_address -- and that public IP
  # wears common_labels like everything else, so it would depend on a value
  # derived from itself. The build id reaches the objects it actually describes
  # through local.build_labels below, none of which the VIP depends on.
  #
  # var.user_labels merges last, so an operator can override any of these.
  common_labels = merge({
    "cluster"    = var.cluster_name
    "managed-by" = "terraform"
    "module"     = "ai-factory-ha"
    "created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }, var.user_labels)

  # common_labels plus the image generation, for the objects whose CONTENT
  # comes from one specific build: the image-target disks, the node boot disks
  # cloned from that build's snapshot, and the nodes booted off them. During a
  # --rebuild both generations exist at once, and this is what tells them apart
  # -- the snapshot itself cannot be labelled at all (see snapshot.tf), so its
  # name is the only other handle and the disks cloned from it have none.
  #
  # NOT applied to the VPC, subnets, security groups, public IPs or the load
  # balancer. Those survive a rebuild untouched; stamping a build id on them
  # would assert a relationship that does not exist, and would churn their
  # labels on every image change.
  build_labels = merge(local.common_labels, { "build" = local.build_id })

  # Directory the cloud-init payload is unpacked into on the jumphost, and the
  # -v mount point handed to `podman run ... customize --type raw`. (No
  # --local: it fails "No such image" for the OCI images elemental pulls
  # itself. See image-factory.sh.tftpl.)
  config_dir = "/opt/elemental-config"
}

# The address baked into every node's elemental config as network.apiVIP --
# see network.tf's own comment on evroc_public_ip.cluster for why this has to
# be a standalone resource with no dependencies, allocated before anything
# else in the module.
locals {
  api_vip = evroc_public_ip.cluster.ip_address

  api_host = coalesce(var.api_host, "rke2-${local.api_vip}.sslip.io")

  # Rancher's ingress and the Kubernetes API answer on the SAME address here:
  # evroc's single load balancer (loadbalancer.tf) forwards 6443/9345/80/443
  # off one public IP, unlike a design that splits API and ingress across two
  # load balancers. So there is nothing to fall back to and nothing to prefer
  # -- api_vip is simply the only address there is.
  rancher_hostname           = coalesce(var.rancher_hostname, "rancher-${local.api_vip}.sslip.io")
  rancher_bootstrap_password = coalesce(var.rancher_bootstrap_password, random_password.rancher_bootstrap.result)
}

# Queried live so the jumphost image tracks whatever evroc currently offers,
# rather than a hardcoded identifier that silently goes stale. openSUSE Leap
# 15.6 is the build host because evroc offers no Leap 16 image at all, and
# 15.6 is the newest Leap it does offer; SLES 15.6 or Ubuntu 24.04 with
# upstream podman are the fallbacks if `elemental customize` misbehaves on it.
data "evroc_disk_images" "this" {}

locals {
  jumphost_image = coalesce(var.jumphost_image, data.evroc_disk_images.this.opensuse_15_6_1)
}

locals {
  # A TAG, not a branch: SUSE/aif tags per component, and aif-operator's tag is
  # the one that moves with the AI Factory version as a whole ("2.2.0" ->
  # aif-operator-2.2.0). A tag is immutable, so unlike release-2.2 the manifest
  # behind it cannot change under a built cluster. Pre-releases are ordinary
  # tags too -- "2.3.0-dev.2" -> aif-operator-2.3.0-dev.2.
  aif_tag = "aif-operator-${var.aif_version}"

  # An explicit URL wins, so a commit-pinned or self-hosted manifest is still
  # one variable away. Everything downstream -- the data source below, the
  # jumphost's curl, the build-id hash -- reads THIS, not the variable.
  aif_release_manifest_url = coalesce(
    var.aif_release_manifest_url,
    "https://raw.githubusercontent.com/SUSE/aif/refs/tags/${local.aif_tag}/uc-release-manifest/release_manifest.yaml",
  )
}

# Fetched at plan time only to hash the manifest's content into the build id
# (owned by image-build.tf/snapshot.tf) -- the jumphost curls the same URL
# itself at build time. See the elemental_files comment below, and
# aif_release_manifest_url's description for why manifestURI is
# file://./release_manifest.yaml.
#
# Consequence of fetching at plan time rather than apply time: `terraform plan`
# needs outbound access to this URL, and an unreachable one fails the plan.
# That is the intended trade -- a manifest that cannot be fetched cannot be
# hashed, and an unhashable manifest means the build id no longer describes
# what was actually built.
data "http" "aif_release_manifest" {
  url = local.aif_release_manifest_url

  lifecycle {
    postcondition {
      # A 404 here is nearly always aif_version naming a tag that does not
      # exist -- an unreleased version, or a patch SUSE never cut -- so the
      # message says which tag was derived and from what, rather than only
      # echoing a URL.
      condition     = self.status_code == 200
      error_message = "Fetching the AI Factory release manifest (${local.aif_release_manifest_url}) returned HTTP ${self.status_code}. ${var.aif_release_manifest_url != null ? "That URL came from aif_release_manifest_url." : "That URL was derived from aif_version = \"${var.aif_version}\" -- SUSE/aif has no ${local.aif_tag} tag, or that tag has no uc-release-manifest/release_manifest.yaml. Check `git ls-remote --tags https://github.com/SUSE/aif` for what exists; to build from an untagged ref, set aif_release_manifest_url instead."}"
    }
  }
}

# local-path-provisioner's imagePullSecrets expect a Secret named
# "application-collection"; kubernetes/manifests/local-path-provisioner.yaml
# below creates it. A dockerconfigjson Secret is just base64(json(...)), so
# Terraform computes it rather than a template hand-rolling it.
locals {
  dockerconfigjson_b64 = base64encode(jsonencode({
    auths = {
      (var.appco_registry) = {
        username = var.appco_username
        password = var.appco_password
        auth     = base64encode("${var.appco_username}:${var.appco_password}")
      }
    }
  }))
}

# write-node-ip.sh, rendered once here (no template vars of its own -- see its
# header) so it can be indent()ed straight into butane.yaml.tftpl's
# write-node-ip.service storage.files entry below. Kept as a named local,
# rather than inlined into that templatefile() call, so the script's own file
# is what gets read and rendered, not shell hand-typed into this file.
locals {
  write_node_ip_script = templatefile("${path.module}/templates/elemental/network/write-node-ip.sh.tftpl", {})

  # iscsi-prep.sh, likewise indent()ed into butane.yaml.tftpl -- but only when
  # the suse-storage extension is enabled (see local.enable_iscsi_prep below).
  # file(), not templatefile(): it has no template variables, and reading it
  # verbatim means its shell "$" and "${...}" need no escaping.
  iscsi_prep_script = file("${path.module}/templates/elemental/storage/iscsi-prep.sh")
}

# One image serves every node. Hostname and RKE2 role (NODETYPE/IS_INIT_NODE)
# are plan-time known, so they ride per node in Ignition user_data
# (node_runtime_ignition below) instead of being baked in. Every evroc VM in
# this design carries exactly one NIC -- there is no vpc_only/public_nic
# classification to make here, and configure-network.sh.tftpl's own header
# explains why it asserts the NIC count itself rather than assuming it.
locals {
  vpc_cidr = var.vpc_cidr

  # One subnet CIDR per zone, carved out of vpc_cidr in zone-list order:
  # zones[0] gets cidrsubnet(vpc_cidr, newbits, 0), zones[1] index 1, and so
  # on. Derived rather than supplied -- see var.subnet_newbits for why -- and
  # exported as the subnet_cidrs output so the values are still readable
  # without computing them by hand.
  #
  # The index comes from the zone's POSITION in var.zones, so reordering that
  # list renumbers the subnets and replaces them (along with every node in
  # them). Append new zones; do not reorder existing ones.
  subnet_cidrs = {
    for i, z in var.zones : z => cidrsubnet(var.vpc_cidr, var.subnet_newbits, i)
  }

  # Every subnet shares this prefix length by construction, which is what lets
  # configure-network.sh -- one script baked into one image serving nodes in
  # every zone -- state a single expected prefix.
  subnet_prefix = tonumber(split("/", var.vpc_cidr)[1]) + var.subnet_newbits

  # THE reason this module builds the image once PER ZONE rather than once.
  #
  # evroc_snapshot looks regional in the provider schema -- it has a `region`
  # attribute and no `zone` -- but it is not. It inherits the zone of the disk
  # named by its disk_ref, and disk-webhook.evroc.com rejects any disk created
  # in zone X from a snapshot whose source disk was in zone Y:
  #
  #   admission webhook "disk-webhook.evroc.com" denied the request: snapshot
  #   "<name>" is in zone "a" but disk is in zone "c"
  #
  # evroc's own docs say the same thing, and name the only remedy: "Snapshots
  # are zonal resources. Each snapshot exists in the same zone as the source
  # disk it was created from. [...] If you need disks in different zones, you
  # would need to create separate snapshots from disks in those respective
  # zones." There is no snapshot-copy resource and no cross-zone disk clone
  # anywhere in the provider -- this is not a gap this module can route around.
  #
  # So image-build.tf stands up one jumphost, one image-target disk and one
  # snapshot per entry in var.zones. A single-zone cluster is unaffected: with
  # zones = ["a"] every for_each below has exactly one element and the shape is
  # identical to a one-jumphost build.
  #
  # Each jumphost is pinned to its own zone because evroc_hotswap_disk_attachment
  # only joins a disk to a VM in the same zone, and the image-target disk exists
  # to be dd'd onto by that VM.

  # The one zone whose jumphost is reachable from outside: it is the only one
  # given a public IP, and every other jumphost is reached by tunnelling through
  # it (see scripts/wait-for-image.sh). zones[0] rather than a variable of its
  # own -- nothing distinguishes the zones here, and one fewer knob that can be
  # set to a zone not in the list.
  #
  # Why only one public IP: a default evroc project allows three, and the API
  # VIP already holds one. One public jumphost keeps the whole build inside a
  # two-IP budget no matter how many zones are configured. The other jumphosts
  # do not need one -- evroc VPCs give every VM outbound internet access
  # regardless ("VMs can make outbound connections to the internet, and inbound
  # connections are possible with a Public IP"), which is all a build host needs
  # to podman-pull the elemental image.
  primary_zone = var.zones[0]

  # Flannel's --iface-regex matches an interface by IP OR name, so the VPC
  # address range is what pins canal's VXLAN to the node's one NIC -- see
  # kubernetes/manifests/canal.yaml.tftpl for why that matters. Derived from
  # vpc_cidr, not from any single subnet: one image serves nodes in every zone,
  # and each zone's nodes carry addresses out of a different subnet, so the
  # only range that matches all of them is their common supernet. Only the
  # octets the mask holds constant can go in the regex, so this is as tight as
  # the VPC range allows: a /16 yields "^10\.20\." in the default config.
  # Harmless, because no interface on these nodes carries any other address in
  # that range -- pods are on cluster-cidr (10.42/16 by default) and a public
  # IP, when attached, is 1:1 NAT onto the same interface rather than a second
  # one.
  vpc_iface_regex_octets = tonumber(split("/", var.vpc_cidr)[1]) >= 24 ? 3 : (tonumber(split("/", var.vpc_cidr)[1]) >= 16 ? 2 : 1)
  vpc_iface_regex        = "^${join("\\.", slice(split(".", split("/", var.vpc_cidr)[0]), 0, local.vpc_iface_regex_octets))}\\."

  # 50 bytes of VXLAN header. Calico sizes the pod veths and has no idea what
  # the underlay is, so it must be told.
  pod_veth_mtu = var.vpc_mtu - 50

  # Every control-plane node is a load balancer backend (loadbalancer.tf), so
  # its address has to be the one evroc itself assigned -- there is no
  # self-assignment anywhere in this module for any node to disagree with.
  # cp-01 initializes the cluster; the rest join it. IS_INIT_NODE rides in
  # node_runtime_ignition below, not here -- see that block's own comment for
  # why this is the ONLY place a node's role is declared.
  #
  # Zone assignment is round-robin over var.zones by node index, so cp-01 lands
  # in zones[0], cp-02 in zones[1] and so on, wrapping. Index-based rather than
  # anything cleverer for one reason: it must be a pure function of the node's
  # own number, so bumping control_plane_count only ever APPENDS nodes. A
  # scheme that balanced the final layout (say, filling the emptiest zone)
  # would move existing members between zones as the count changed, and moving
  # an etcd member means destroying and recreating it.
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      hostname = format("%s-cp-%02d", var.cluster_name, i + 1)
      type     = "server"
      init     = i == 0 # cp-01 initializes the cluster; the rest join it.
      zone     = var.zones[i % length(var.zones)]
    }
  ]

  # Built from ONE pool map (var.gpu_pools), not two -- evroc has no separate
  # bare-metal tier, so every GPU worker is an ordinary VM regardless of pool.
  # Pools are flattened in sort(keys()) order purely for deterministic
  # iteration -- hostnames are already stable per pool (format() below uses
  # only the pool's own name and a per-pool index, never a running/global one)
  # -- so adding a pool, renaming one, or bumping a count never renumbers a
  # pool it didn't touch. Nothing here feeds the image either: adding a GPU
  # node is a pure Terraform add of just the affected nodes, never a rebuild.
  #
  # Zone per node: the pool's own `zone` when it pins one, otherwise the same
  # index round-robin the control plane uses, over the pool's OWN index rather
  # than a global one -- so a pool's zone layout does not shift when an
  # unrelated pool is added or resized.
  #
  # The round-robin runs over gpu_zones_usable, NOT var.zones: evroc's
  # virtualmachine-webhook refuses to create a GPU VM outside var.gpu_zones,
  # and it refuses at apply time, one node at a time, after that node's boot
  # disk already exists. Spreading over var.zones would therefore succeed for
  # whichever nodes happened to land in zone "a" and 403 for the rest.
  # sorted() so the order is deterministic rather than set-ordered.
  gpu_zones_usable = sort(tolist(setintersection(toset(var.zones), toset(var.gpu_zones))))

  gpu_nodes = flatten([
    for pool in sort(keys(var.gpu_pools)) : [
      for i in range(var.gpu_pools[pool].count) : {
        hostname = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
        pool     = pool
        type     = "agent"
        flavor   = var.gpu_pools[pool].flavor
        zone = (
          var.gpu_pools[pool].zone != null
          ? var.gpu_pools[pool].zone
          : local.gpu_zones_usable[i % max(length(local.gpu_zones_usable), 1)]
        )
      }
    ]
  ])

  # One placement group per (pool, zone) pair that actually holds a node, for
  # pools that asked for a strategy. Built from the node list rather than from
  # var.gpu_pools directly so a pool with count = 0 creates no empty group, and
  # a multi-zone "spread" pool gets exactly the groups its nodes need.
  #
  # Keyed "<pool>/<zone>": "/" cannot appear in either half (both are validated
  # DNS-label-ish), so the key cannot be ambiguous. gpu-nodes.tf looks the
  # group up by rebuilding this same key from the node's own pool and zone.
  gpu_placement_groups = {
    for node in local.gpu_nodes :
    "${node.pool}/${node.zone}" => {
      pool     = node.pool
      zone     = node.zone
      strategy = var.gpu_pools[node.pool].placement_strategy
    }
    if var.gpu_pools[node.pool].placement_strategy != null
  }

  cluster_nodes = concat(local.control_plane_nodes, local.gpu_nodes)
}

# Per-node Ignition "user config", keyed by hostname, wired to each node's own
# user_data in control-plane.tf/gpu-nodes.tf. Hand-built rather than
# transpiled: there is no butane step in this pipeline and this config is three
# files. Matches real butane 0.29.0 output (decimal mode, contents.source as an
# RFC 2397 data: URL, ignition version "3.5.0").
#
# This is the PER-NODE half. The cluster-wide half -- root's password hash and
# SSH keys, sshd, /root/.profile -- is baked into the image as
# base.d/90-butane.ign by templates/elemental/butane.yaml.tftpl. Ignition
# merges every base.d config first, then the platform config (this one, from
# evroc's own cloud_config_user_data) on top, so the two are layered and this
# one wins on conflict.
locals {
  # The ceiling on cloud_config_user_data, per VM. evroc confirmed 1 MB on
  # 2026-09-22: it is not a cloud-init or Ignition limit but a KubeVirt one --
  # the VM is a KubeVirt object and user data is a field in it, so the whole
  # object has to fit.
  #
  # Checked at 768 KiB rather than 1 MB. The budget belongs to the object, not
  # to the payload, and a payload base64'd into that object is 4/3 its raw
  # size; 3/4 of the limit is what survives that encoding no matter which way
  # it is stored. Nothing here comes close -- the largest payload the module
  # has shipped is ~15 KB -- so the margin costs nothing and removes the need
  # to know how evroc stores the field.
  user_data_max_bytes = 786432

  # Per node, and ONLY per node: anything identical across the cluster belongs
  # in butane.yaml.tftpl instead. Plain {path, mode, content} tuples; the
  # data: URI encoding happens once, below.
  node_files = {
    for node in local.cluster_nodes : node.hostname => concat(
      [
        {
          path    = "/etc/hostname"
          mode    = 420 # 0644
          content = "${node.hostname}\n"
        },
      ],
      # THE ONLY PLACE A NODE'S ROLE IS DECLARED. kubernetes/cluster.yaml has
      # no nodes: list, so elemental writes its own copy of this file into
      # base.d carrying IS_INIT_NODE=true NODETYPE=server; this one merges over
      # it (see the header above) and is what both k8s_conf_deploy.sh and
      # k8s-resource-installer.service's ExecCondition actually read.
      #
      # IS_INIT_NODE is emitted only on the init node -- not as "false"
      # elsewhere -- because absent and false behave identically downstream,
      # and the upstream example omits it the same way. try() below, not a
      # bare node.init, because a GPU node's object has no init attribute at
      # all -- concat() unifies control_plane_nodes and gpu_nodes into one
      # object type with init present but null on a GPU node's copy.
      [
        {
          path = "/var/lib/elemental/runtime.env"
          mode = 420 # 0644
          content = join("", concat(
            ["NODETYPE=${node.type}\n"],
            try(node.init, false) ? ["IS_INIT_NODE=true\n"] : [],
          ))
        },
      ],
    )
  }

  # Identical on every server, and delivered per node anyway -- because of WHEN
  # it has to exist, not because it varies.
  #
  # RKE2 reads /var/lib/rancher/rke2/server/manifests at startup and turns each
  # file into an AddOn. Elemental's own kubernetes/manifests/ is a DIFFERENT
  # slot: k8s-resource-installer.service kubectl-applies it once the API server
  # answers, which is far too late for a HelmChartConfig. That is elemental
  # issue #570, whose documented workaround is exactly this -- write the file
  # straight into RKE2's manifests directory. On a fresh build:
  #
  #   12:30:17  ignition writes /var/lib/elemental/kubernetes/manifests/canal.yaml
  #   12:30:29  rke2-server starts
  #   12:30:33  RKE2 drops its own rke2-canal.yaml into the manifests dir
  #   12:30:58  the rke2-canal HelmChart is created -- chart defaults
  #   12:31:03  ConfigMap rke2-canal-config appears with veth_mtu 1450
  #   12:32:42  k8s-resource-installer applies our HelmChartConfig, 104s late
  #
  # For canal specifically that lateness is permanent, not merely slow: its
  # values reach the DaemonSet through rke2-canal-config via env.valueFrom and
  # the chart sets no checksum annotation, so the reinstall produces a
  # byte-identical pod template, nothing rolls, install-cni never re-runs and
  # /etc/cni/net.d/10-canal.conflist keeps the default MTU for the life of the
  # node. Here the chart's default is far off rather than merely suboptimal:
  # the underlay is 8900, so the chart's own 1450 leaves the init node running
  # pod veths at roughly a sixth of the available MTU while every node that
  # joins later gets 8850 -- an asymmetry that is invisible until throughput
  # between two specific pods is compared against two others.
  #
  # Worth knowing if #570 is ever fixed: the failure it describes is a deadlock,
  # loud and self-announcing. This one is silent -- the chart installs, the
  # installer succeeds, every pod is Running, and the HelmChartConfig sits in the
  # cluster looking applied while doing nothing. Ordering resources WITHIN
  # k8s-resource-installer would not fix it; the file has to exist before
  # rke2-server starts, and that service runs after the API server answers.
  #
  # Ignition runs before rke2-server, so writing the file into RKE2's own
  # directory makes it an AddOn in the same sync as rke2-canal.yaml -- and
  # "canal.yaml" sorts before "rke2-canal.yaml": both AddOns present, the
  # conflist carries the requested MTU on the init node with no pod bounce,
  # every cali veth born correct, 9091 closed from off-cluster.
  #
  # Servers only: agents never read this directory. All servers rather than just
  # the init node, so no server holds a divergent view of it.
  #
  # Being here also takes CNI tuning off the image-rebuild path: editing
  # canal.yaml.tftpl now replaces nodes instead of rebuilding the snapshot.
  node_server_manifests = {
    for node in local.cluster_nodes : node.hostname => node.type != "server" ? [] : [
      {
        path = "/var/lib/rancher/rke2/server/manifests/canal.yaml"
        mode = 420 # 0644
        content = templatefile("${path.module}/templates/elemental/kubernetes/manifests/canal.yaml.tftpl", {
          iface_regex = local.vpc_iface_regex
          veth_mtu    = local.pod_veth_mtu
        })
      },
    ]
  }

  # Ignition creates a file's parent directories implicitly, so this is
  # belt-and-braces: it pins the mode, and the directory still exists if the
  # list above is ever emptied.
  node_server_dirs = {
    for node in local.cluster_nodes : node.hostname => node.type != "server" ? [] : [
      "/var/lib/rancher/rke2/server/manifests",
    ]
  }

  node_runtime_ignition = {
    for hostname, files in local.node_files : hostname => jsonencode({
      ignition = { version = "3.5.0" }

      # passwd and systemd live in butane.yaml. A storage-only Ignition config
      # is still valid.
      storage = {
        directories = [
          for d in local.node_server_dirs[hostname] : {
            path = d
            mode = 493 # 0755
          }
        ]

        files = concat(
          [
            for f in files : {
              path      = f.path
              mode      = f.mode
              overwrite = true
              contents = {
                compression = ""

                # The replace() is load-bearing: urlencode() is Go's
                # url.QueryEscape, which renders a space as "+", but an RFC 2397
                # data: URI is only percent-decoded, so the "+" survives
                # literally. Real butane emits %20. It bites silently and only
                # for files containing a space -- none of the files above do
                # today, but the encoding has to be right for the next one
                # that does.
                source = "data:,${replace(urlencode(f.content), "+", "%20")}"
              }
            }
          ],
          # base64 rather than percent-encoding for these: they are mostly
          # prose, which percent-encoding roughly triples, and user_data is a
          # budget. Both forms are valid RFC 2397 and both are emitted by real
          # butane; this one also sidesteps the "+" trap above entirely.
          [
            for f in local.node_server_manifests[hostname] : {
              path      = f.path
              mode      = f.mode
              overwrite = true
              contents = {
                compression = ""
                source      = "data:;base64,${base64encode(f.content)}"
              }
            }
          ],
        )
      }
    })
  }
}

# Chart set enabled in release.yaml, driven by var.components. One spec entry
# per chart name: values_file is what release.yaml's valuesFile points at
# (null when a chart ships no values of its own), chart_credentials is Helm
# chart-PULL auth against oci://dp.apps.rancher.io/charts -- release.yaml's
# per-chart credentials: block, keyed by chart name because elemental's
# createAuthMap keys the auth map that way, not by repository -- and
# pull_secret_namespace is a separate, unrelated thing: an in-cluster
# Kubernetes image-PULL Secret this module creates by hand (see
# component_pull_secret_manifests below), because CreateNamespace: true is
# hardcoded on every generated HelmChart CR (pkg/helm/helm.go:109) and the
# Secret has to exist in that namespace before the chart runs. The two flags
# are independent on purpose: local-path-provisioner needs both, because its
# pods pull images directly from the same registry; suse-storage needs only
# the first, because its own values file sets
# privateRegistry.createSecret: true and the chart creates the Secret itself.
#
# sysext names a systemd system extension release.yaml must enable alongside
# the chart. In theory this is redundant: the AIF manifest's suse-storage chart
# already declares `dependsOn: [{name: suse-storage, type: sysext}]`, and
# elemental's enabledExtensions() turns any extension named by an enabled
# chart's ExtensionDependencies() into an enabled extension without being
# asked (internal/config/systemd_sysext.go, the isDependency closure).
#
# It is listed explicitly anyway, because that auto-enable was read out of
# elemental `main` and this module pins elemental 3.1.0-6.5 -- the exact kind
# of version skew that already cost a cluster once with initrdExtensions (see
# core_platform_override). The same function's isExtensionExplicitlyEnabled()
# honours release.yaml's own `components.systemd` list, which is the path that
# does not depend on the tool being new enough. Belt and braces, one line.
locals {
  component_spec = {
    cert-manager = {
      values_file           = null
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
    rancher = {
      values_file           = "rancher.yaml"
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
    gpu-operator = {
      values_file           = "gpu-operator.yaml"
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
    local-path-provisioner = {
      values_file           = "local-path-provisioner.yaml"
      chart_credentials     = true
      pull_secret_namespace = "local-path-provisioner"
      sysext                = null
    }
    # Longhorn cannot start without iscsiadm, which is not in the base OS
    # image. registry.suse.com/elemental/longhorn:4.111-4.79 exists in the AIF
    # manifest for that one reason, and its own comment there says so.
    # Without it longhorn-manager crash-loops on:
    #   "failed to check environment, please make sure you have
    #    iscsiadm/open-iscsi installed on the host"
    suse-storage = {
      values_file           = "suse-storage.yaml"
      chart_credentials     = true
      pull_secret_namespace = null
      sysext                = "suse-storage"
    }
    aif-operator = {
      values_file           = "aif-operator.yaml"
      chart_credentials     = false
      pull_secret_namespace = null
      sysext                = null
    }
  }

  # CANONICAL order, not the order var.components was typed in. Chart
  # dependsOn is resolved automatically and recursively by elemental itself
  # (internal/config/helm.go's enabledHelmCharts/addChart inserts a dependency
  # BEFORE its dependent), so this list only has to avoid contradicting that --
  # its actual job is making release.yaml depend only on WHICH components are
  # selected, never on the order they were typed in. That matters here
  # specifically: release.yaml is in local.elemental_files, sha256'd into the
  # build id, which names the snapshot -- ForceNew on every node -- so merely
  # reordering var.components would otherwise propose destroying a running
  # cluster.
  component_order = [
    "cert-manager", "rancher", "gpu-operator",
    "local-path-provisioner", "suse-storage", "aif-operator",
  ]

  # rancher -> cert-manager is already enforced upstream (see component_spec's
  # header comment); this only adds what var.components didn't already say,
  # and never double-adds cert-manager if it's already present.
  components_with_deps = contains(var.components, "rancher") && !contains(var.components, "cert-manager") ? concat(var.components, ["cert-manager"]) : var.components

  enabled_components      = [for c in local.component_order : c if contains(local.components_with_deps, c)]
  enabled_component_specs = [for c in local.enabled_components : merge({ chart = c }, local.component_spec[c])]

  # Extensions the enabled charts need, in the same canonical order, deduped
  # (distinct) so two charts naming one extension emit it once. Empty for the
  # default chart set -- release.yaml.tftpl omits the block entirely when this
  # is empty rather than emitting `systemd: []`.
  enabled_sysexts = distinct([
    for c in local.enabled_components : local.component_spec[c].sysext
    if local.component_spec[c].sysext != null
  ])

  # Whether butane.yaml has to carry the open-iSCSI firstboot unit. Keyed off
  # the EXTENSION, not the chart: it is the sysext that delivers iscsid under
  # /usr with no /etc to go with it, and anything else that ever pulls that
  # same extension in needs the same repair. Gating it also keeps butane.yaml
  # -- and therefore the build id and the whole image -- byte-identical for the
  # default (local-path-provisioner) component set.
  enable_iscsi_prep = contains(local.enabled_sysexts, "suse-storage")

  # Whether butane.yaml has to carry the local-path-provisioner firstboot unit.
  # Keyed off the CHART, not an extension: the directory is the chart's default
  # storage path, so nothing else needs it. Gated for the same reason as
  # enable_iscsi_prep -- a suse-storage cluster gets a byte-identical
  # butane.yaml, and therefore the same build id, as one built before this
  # existed.
  enable_local_path_prep = contains(local.enabled_components, "local-path-provisioner")

  # Every extension this module knows how to enable, regardless of whether the
  # component that pulls it in is selected. Only used to tell a typo from a
  # deliberate no-op below.
  known_sysexts = distinct([
    for spec in values(local.component_spec) : spec.sysext if spec.sysext != null
  ])

  # var.sysext_image_overrides, narrowed to extensions that are actually
  # enabled. The variable ships a non-empty default (the beta longhorn build),
  # and the default component set does NOT include suse-storage, so without
  # this filter every ordinary local-path-provisioner cluster would rewrite an
  # extension it never builds -- and, worse, would fail the build outright
  # against any manifest that does not declare that extension, over a component
  # nobody asked for. Filtering here means an override is inert until the
  # component that needs it is selected.
  #
  # The build script keeps its own fatal check on names the manifest does not
  # declare. That check now only sees names that survived this filter, which is
  # the intended division: "the manifest has no such extension" is fatal, "no
  # selected component pulls this extension in" is a no-op.
  #
  # Consequence worth knowing: an extension the manifest marks Required, or one
  # pulled in by a chart this module does not model, cannot be overridden at
  # all -- it never appears in enabled_sysexts. Add it to component_spec's
  # sysext field in locals.tf if that day comes.
  effective_sysext_overrides = {
    for name, image in var.sysext_image_overrides : name => image
    if contains(local.enabled_sysexts, name)
  }

  # Longhorn's replica count for suse-storage.yaml.tftpl. control_plane_count
  # is validated >= 3 && odd (variables.tf), so the < 3 branch in that
  # template is unreachable in this module today -- see its own comment for
  # why it is kept anyway.
  suse_storage_node_count = var.control_plane_count

  # Values files and appco-pull-secret manifests driven by which components
  # are enabled. Split from the always-present entries in elemental_files
  # below so each one is entered ONLY when its component is: a cluster
  # without aif-operator, for instance, stops shipping the SUSE registration
  # code, registry password and NVIDIA API key into the image at all.
  component_values_files = merge(
    !contains(local.enabled_components, "rancher") ? {} : {
      "kubernetes/helm/values/rancher.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/helm/values/rancher.yaml.tftpl", {
        hostname           = local.rancher_hostname
        bootstrap_password = local.rancher_bootstrap_password
      })
    },
    !contains(local.enabled_components, "gpu-operator") ? {} : {
      "kubernetes/helm/values/gpu-operator.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/helm/values/gpu-operator.yaml.tftpl", {
        repository = var.gpu_driver_repository
        version    = var.gpu_driver_version
      })
    },
    !contains(local.enabled_components, "local-path-provisioner") ? {} : {
      # Static: no per-deployment values, so no templating needed.
      "kubernetes/helm/values/local-path-provisioner.yaml" = file("${path.module}/templates/elemental/kubernetes/helm/values/local-path-provisioner.yaml")
    },
    !contains(local.enabled_components, "suse-storage") ? {} : {
      "kubernetes/helm/values/suse-storage.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/helm/values/suse-storage.yaml.tftpl", {
        appco_username = var.appco_username
        appco_password = var.appco_password
        node_count     = local.suse_storage_node_count
      })
    },
    !contains(local.enabled_components, "aif-operator") ? {} : {
      "kubernetes/helm/values/aif-operator.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/helm/values/aif-operator.yaml.tftpl", {
        appco_username         = var.appco_username
        appco_password         = var.appco_password
        suse_registration_code = var.suse_registration_code
        suse_registry_password = var.suse_registry_password
        nvidia_api_key         = var.nvidia_api_key
      })
    },
  )

  # Image-pull Secret manifests, one per enabled component whose spec names a
  # pull_secret_namespace -- today only local-path-provisioner. suse-storage
  # is deliberately absent: see component_spec's header comment.
  component_pull_secret_manifests = {
    for c in local.enabled_components : "kubernetes/manifests/${c}.yaml" => templatefile(
      "${path.module}/templates/elemental/kubernetes/manifests/appco-pull-secret.yaml.tftpl",
      {
        namespace            = local.component_spec[c].pull_secret_namespace
        dockerconfigjson_b64 = local.dockerconfigjson_b64
      }
    ) if local.component_spec[c].pull_secret_namespace != null
  }
}

# The elemental config dir, keyed by path relative to config_dir. Looped over
# in cloud-init.yaml.tftpl's write_files with gzip+base64 encoding, which
# both shrinks the payload and sidesteps YAML-indenting arbitrary generated
# content by hand.
#
# This is the DOCUMENTED form. local.elemental_files below strips the comments
# out before anything consumes it -- nothing outside this file should read
# elemental_files_documented.
locals {
  elemental_files_documented = merge({
    "release.yaml" = templatefile("${path.module}/templates/elemental/release.yaml.tftpl", {
      components     = local.enabled_component_specs
      sysexts        = local.enabled_sysexts
      appco_username = var.appco_username
      appco_password = var.appco_password
    })

    # release_manifest.yaml is NOT embedded here -- ~3.8 KB against the
    # user_data ceiling, for no benefit since the jumphost has network access.
    # image-factory.sh curls aif_release_manifest_url into the config dir
    # before running elemental customize. data.http.aif_release_manifest above
    # exists only to hash the manifest into the build id; the two fetches are
    # minutes apart, so pin the URL to a commit SHA if it tracks a branch.

    "install.yaml" = templatefile("${path.module}/templates/elemental/install.yaml.tftpl", {
      disk_size = var.image_disk_size
      fips      = var.fips
    })

    # Everything identical on every node: the accounts (root's hash, the
    # unprivileged var.node_username with its own hash and the SSH keys, and
    # whether sshd takes root at all), the /home subvolume mount those accounts
    # need, /root/.profile, and the write-node-ip firstboot unit (see
    # local.write_node_ip_script above, and that script's own header for why
    # it has to be delivered this way rather than through
    # configure-network.sh). Layered with, not exclusive to, each node's
    # user_data -- see the template's header.
    "butane.yaml" = templatefile("${path.module}/templates/elemental/butane.yaml.tftpl", {
      root_password_hash      = var.root_password_hash
      ssh_authorized_keys     = var.ssh_authorized_keys
      node_username           = var.node_username
      node_user_password_hash = var.node_user_password_hash
      permit_root_ssh         = var.permit_root_ssh
      write_node_ip_script    = local.write_node_ip_script
      enable_iscsi_prep       = local.enable_iscsi_prep
      iscsi_prep_script       = local.iscsi_prep_script
      enable_local_path_prep  = local.enable_local_path_prep
    })

    # No node list is passed: roles ride per node in runtime.env instead. See
    # the template's header for the elemental source that makes that work, and
    # for why keeping node identity out of this file matters.
    "kubernetes/cluster.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/cluster.yaml.tftpl", {
      api_vip      = local.api_vip
      api_vip_mode = var.api_vip_mode
      api_host     = local.api_host
    })

    "kubernetes/config/server.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/config/server.yaml.tftpl", {
      token                = random_password.token.result
      ingress_controller   = var.ingress_controller
      suse_storage_enabled = contains(local.enabled_components, "suse-storage")
    })

    "kubernetes/config/agent.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/config/agent.yaml.tftpl", {
      token = random_password.token.result
    })

    # kubernetes/helm/values/{rancher,local-path-provisioner,suse-storage,
    # aif-operator}.yaml and kubernetes/manifests/*.yaml (the appco image-pull
    # Secrets) are NOT here -- both are component-driven, see
    # component_values_files and component_pull_secret_manifests above, and
    # both are merge()'d in below.

    # canal.yaml is NOT here. Its HelmChartConfig has to exist before RKE2
    # installs the chart, and this directory is applied minutes after that --
    # see node_server_manifests above, which delivers it through Ignition
    # instead.

    # nat_gateway_ip and dns_servers, present in an earlier iteration of this
    # template, are gone: this design has no NAT gateway (every node either
    # carries its own public IP or has none at all) and DHCP already supplies
    # resolvers on the single NIC either way, so there was never a static
    # fallback path left for either value to feed.
    "network/configure-network.sh" = templatefile("${path.module}/templates/elemental/network/configure-network.sh.tftpl", {
      vpc_mtu = var.vpc_mtu
      # local.subnet_prefix, not any one subnet's own: this script is baked
      # into the single image every node boots, in every zone, and each zone's
      # subnet is a different range. They all share a prefix length by
      # construction (cidrsubnet with one newbits value), which is precisely
      # the part that is the same everywhere and therefore the only part this
      # script can assert.
      vpc_prefix = local.subnet_prefix
    })
    },

    local.component_values_files,
    local.component_pull_secret_manifests,

    # Only traefik gets a HelmChartConfig: ingress-nginx is on its way out
    # upstream and not worth carrying a second variant of this for.
    var.ingress_controller != "traefik" ? {} : {
      "kubernetes/manifests/traefik.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/manifests/traefik.yaml.tftpl", {
        vpc_cidr = local.vpc_cidr
      })
  })
}

# image-factory.sh, the script that runs `elemental customize` on the jumphost
# and writes the resulting raw image onto the attached image_target disk.
# Rendered here (rather than beside evroc_disk.image_target/evroc_snapshot in
# image-build.tf) because it goes through the SAME comment-strip pass as
# elemental_files below, and that pass has to run over both in one file to
# avoid the dependency cycle described on that block.
#
# Nothing here reaches into an evroc resource's computed attributes. In
# particular the script is NOT handed the target disk's device path: the only
# thing that would identify it is evroc_hotswap_disk_attachment.serial, which
# the platform only assigns once the attachment exists -- and the attachment is
# made to a VM whose user_data embeds this script, so reading the serial here
# would be a cycle. The script resolves its own target at runtime by exclusion
# instead, the same way configure-network.sh.tftpl discovers its own NIC from
# /sys rather than being told. It is given the disk's NAME and SIZE, both
# plan-known, as corroborating evidence for that search.
#
# local.build_id IS passed, and is the reason the comment-strip pass below has
# to be split in two. It comes from time_static in snapshot.tf, whose triggers
# hash local.elemental_files; since elemental_files never reads the factory
# script, the graph stays acyclic -- but only as long as the two stay separate
# expressions. See the block below.
locals {
  # The blank disk the image is written onto, one per zone. Named here rather
  # than in image-build.tf so the script can be told what to look for without
  # depending on the resource that creates it; image-build.tf reads this same
  # local for evroc_disk.image_target[*].name, so the two cannot drift.
  #
  # Suffixed by zone unconditionally, including in a single-zone cluster: an
  # unsuffixed name for zones[0] would mean the disk gets renamed -- and
  # therefore replaced -- the first time a second zone is added, which is
  # exactly when an operator least wants their built image thrown away.
  image_target_disk_names = {
    for z in var.zones : z => "${var.cluster_name}-image-target-${z}"
  }

  # One rendering per zone. The ONLY thing that varies between them is the
  # target disk name below; the build itself -- same elemental image, same
  # release manifest, same config dir -- is identical everywhere, which is what
  # makes the resulting per-zone snapshots interchangeable -- "same inputs" is
  # the whole of the guarantee, and it is taken on trust. It cannot be checked
  # by comparing the built images: elemental customize lays down fresh
  # filesystems, so UUIDs, GPT GUIDs and mtimes differ between any two runs. See
  # scripts/wait-for-image.sh for the check that would be sound (compare the
  # resolved OCI digests, not the output bytes) and why the sha256 one was
  # removed.
  factory_script_documented = {
    for z in var.zones : z => templatefile("${path.module}/templates/image-factory.sh.tftpl", {
      elemental_image          = var.elemental_image
      config_dir               = local.config_dir
      aif_release_manifest_url = local.aif_release_manifest_url
      cluster_name             = var.cluster_name
      log_file                 = "/var/log/elemental-factory.log"

      # Carried in every status line the build publishes to the relay, so a
      # status left behind by a PREVIOUS build reads as "not done yet" rather
      # than being mistaken for this one. One build id across every zone: the
      # zones build the same image, so a per-zone id would imply a difference
      # that does not exist.
      build_id = local.build_id

      # Corroborating evidence for resolve_target_disk(): a /dev/disk/by-id/
      # entry carrying this name is taken as definitive, and the expected size
      # is the fallback discriminator when it is not.
      image_target_disk_name = local.image_target_disk_names[z]
      image_target_disk_gb   = var.image_target_disk_gb

      # Where the build reports its status: the relay on the jumphost. Only
      # the zone (the path it publishes to) and the port go in here; the
      # script defaults to localhost, and a builder learns the jumphost's
      # address from builder_user_data at runtime. Putting that address in
      # this map would make every zone's script depend on the jumphost VM,
      # which itself reads this map -- a cycle.
      zone              = z
      status_relay_port = var.status_relay_port

      # "" = no override, which is what the script branches on. try() because
      # indexing into a null object is an error, not a null.
      core_os_image_base = try(var.core_platform_override.os_image_base, "")
      core_os_image_iso  = try(var.core_platform_override.os_image_iso, "")
      core_k8s_version   = try(var.core_platform_override.kubernetes_version, "")
      core_k8s_image     = try(var.core_platform_override.kubernetes_image, "")

      # "{}" when unset OR when no enabled component pulls the named extension
      # in, which is what the script branches on. The filtering is above.
      sysext_image_overrides_json = jsonencode(local.effective_sysext_overrides)
    })
  }
}

# Comments stripped. Everything downstream reads local.elemental_files and
# local.factory_script, never the *_documented values feeding this block.
#
# Why: the templates are commented heavily on purpose, but every byte of them
# rides in the jumphost's user_data, which the jumphost VM's own cloud-init
# payload caps in practice well under evroc's limits. Across all templates,
# gzip+base64'd the way cloud-init.yaml.tftpl encodes them, comments cost real
# bytes for zero runtime benefit. Gzip does not rescue prose here -- the files
# are encoded one at a time, so no shared dictionary ever forms across them.
#
# The second, larger benefit: elemental_files is what image-build.tf sha256s
# into the build id that names the image/snapshot, so the hash is now blind to
# comments. Editing a comment in any template does not rebuild the image or
# replace the cluster.
#
# What the regex does and does not touch:
#   - Strips a line whose first non-blank character is "#", and its newline.
#   - Leaves "#!" alone, so the shebang survives -- including the indented one
#     inside butane.yaml's `inline: |` block, where write-node-ip.sh is
#     embedded. That is the whole reason for the (?:[^!].*)? alternation.
#   - Leaves trailing comments ("foo  # bar") alone. Stripping those needs
#     to know whether the "#" is inside a quoted string, which a regex cannot,
#     and they are a rounding error next to the block comments.
#   - Leaves "#cloud-config" alone by not applying here at all:
#     cloud-init.yaml.tftpl is rendered elsewhere, not through this map, and
#     its first line is a directive rather than a comment.
#   - ".*" does not cross a newline in RE2, so a comment can never eat the
#     line after it.
# Then runs of blank lines collapse to one, since removing a block comment
# usually leaves the blank lines that framed it back to back.
#
# image-factory.sh goes through the same pipe -- it is the single largest file
# in the payload (heavily commented by design), so exempting it would give
# back most of the saving.
#
# It is stripped SEPARATELY rather than merged into one map with the elemental
# files. The merged version is the obvious-looking one and it deadlocks -- a
# single `merge()`d map stripped in one comprehension, re-split afterwards,
# gets you:
#
#   Cycle: <the build id> -> local.elemental_files -> <the merged map>
#          -> local.factory_script_documented -> <the build id>
#
# image-factory.sh interpolates values derived from the build id (the
# description/name it gives the artifact it writes), while the build id itself
# is the sha256 of elemental_files. Merging the two puts elemental_files
# downstream of the factory script and closes the loop. Keeping them as two
# expressions over shared regex locals costs a duplicated replace() pair and
# keeps the graph acyclic.
locals {
  # Wrapped in forward slashes, so replace() treats them as regexes.
  strip_comment_lines = "/(?m)^[ \\t]*#(?:[^!].*)?\\n/"
  collapse_blank_runs = "/\\n{3,}/"

  elemental_files = {
    for path, content in local.elemental_files_documented :
    path => replace(
      replace(content, local.strip_comment_lines, ""),
      local.collapse_blank_runs, "\n\n"
    )
  }

  factory_script = {
    for z, content in local.factory_script_documented :
    z => replace(
      replace(content, local.strip_comment_lines, ""),
      local.collapse_blank_runs, "\n\n"
    )
  }
}
