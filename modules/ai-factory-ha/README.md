# `ai-factory-ha`

Stands up a SUSE AI Factory cluster on evroc: RKE2 in HA behind a single L4
load balancer, Rancher, the AI Factory operator and an optional GPU worker
pool, every node booted from a self-built [elemental3](https://github.com/suse/elemental)
image with the OS, Kubernetes and the chart set baked in at build time.

For the platform facts this design is built around -- the experimental UEFI
label, the absence of import-image-from-URL, what is still unverified -- read
[`../../PLATFORM-NOTES.md`](../../PLATFORM-NOTES.md). For a working invocation,
see [`../../examples/ha-cluster`](../../examples/ha-cluster).

## Design

### The two passes

evroc has no import-image-from-URL, so the image is built on a jumphost inside
the project and handed over as a snapshot. That handoff cannot happen in one
apply, because Terraform will not attach and detach the same disk within a
single graph walk:

| | `image_ready` | What happens |
|---|---|---|
| Pass 1 | `false` | VPC, subnets, API VIP, security groups and the load balancer come up. One blank `evroc_disk.image_target` per zone is attached to that zone's build host by `evroc_hotswap_disk_attachment`. `image-factory.sh` builds the raw elemental image on each and `dd`s it onto the attached disk. Each build host publishes its progress to a status relay on the jumphost (`templates/status-relay.py`, port `status_relay_port`), and `terraform_data.image_written` blocks on `scripts/wait-for-image.sh`, which polls that relay over plain HTTP until every zone reports `done` for this build's id -- or stops at once if one reports `failed`. |
| Pass 2 | `true` | The attachments drop to an empty `for_each`, which **is** the detach. One `evroc_snapshot.ai_factory` per zone is taken from the now-free disks. Each node's boot disk is an `evroc_disk` cloned from its own zone's snapshot, and the control planes populate the load balancer's backend pool. |

This module requires **provider 0.9.4 or newer** (`versions.tf` enforces it):
it is the first release where `evroc_loadbalancer` accepts `backend_network`,
without which the load balancer lands in the default VPC, cannot reach its own
backend pool, and resets every connection at the VIP while reporting `Ready`.
Note that `backend_network` forces replacement, so changing `var.vpc_cidr` or
`var.zones` rebuilds the load balancer.

There is an optional third apply that reclaims the image-target disks
(`retain_image_target_disks = false`). The module variable defaults to keeping
them, because it has to be a separate apply -- creating a snapshot and
destroying its source in the same one races. `deploy.sh` does that sequencing
and reclaims by default (`--keep-build-disks` opts out). A snapshot does survive
its source disk, but no node has yet been booted from a clone made after that
disk was deleted.

`examples/ha-cluster/deploy.sh` drives every pass and pins `image_ready` in an
auto-loaded `pass2.auto.tfvars.json` so a later bare `terraform apply` does not
revert it. Once the snapshot is in state, a bare apply is safe and the script
does a single pass.

The API VIP is a standalone `evroc_public_ip`, so its address is known before
the load balancer, the jumphost or the image exist. That is what lets the image
be built against a live `apiVIP` with no dependency cycle.

### `var.snapshot_ids` is not a pin

It means *"do not build an image, adopt these externally-owned snapshots"*, and
`evroc_snapshot.ai_factory` is gated on it being **empty**. Setting it to the
FQIDs of the snapshots this module built destroys those resources while every
node disk still refers to the ids. There is no need to pin: once created, a
snapshot's FQID is in state and already plan-known.

It is a map keyed by zone, with an entry required for every zone in
`var.zones`, because evroc snapshots are zonal -- there is no single id that
serves a multi-zone cluster.

### Node roles

`kubernetes/cluster.yaml` carries **no `nodes:` list**. Each node's role is
declared once, by per-node Ignition in `cloud_config_user_data`, which writes
`/etc/hostname` and `/var/lib/elemental/runtime.env` with
`NODETYPE=server|agent` plus `IS_INIT_NODE=true` on `cp-01` only (omitted, not
`false`, elsewhere). Adding a GPU pool is therefore an add, not an image
rebuild and cluster replacement.

Ignition is hand-built in `locals.tf` rather than shelled out to butane, with
two encoding traps handled: `urlencode` is Go's `QueryEscape` and renders a
space as `+`, which a `data:` URI does not decode (hence
`replace(urlencode(c), "+", "%20")`), and prose-heavy manifests go through
`data:;base64,` instead.

### Where nodes land: zones and placement groups

evroc's resources split into regional and zonal, and that split decides what a
multi-AZ cluster costs:

| Regional (one, shared) | Zonal (one per zone) |
|---|---|
| `evroc_vpc` | `evroc_subnet` |
| `evroc_loadbalancer`, `evroc_lb_backend_pool` | `evroc_placement_group` |
| `evroc_public_ip`, `evroc_security_group` | `evroc_disk`, `evroc_virtual_machine` |
| | `evroc_snapshot` -- see below |

So one load balancer fronts backends in every zone. Everything else a node is
made of is per-zone, **including the image it boots**.

Control-plane nodes are assigned round-robin across `var.zones` **by node
index** -- `cp-01` to `zones[0]`, `cp-02` to `zones[1]`, wrapping. Index-based
rather than anything that balances the final layout, because the assignment has
to be a pure function of the node's own number: a scheme that filled the
emptiest zone would move existing members between zones as
`control_plane_count` changed, and moving an etcd member means destroying and
recreating it.

The two failure domains stack rather than substitute. A zone is what evroc
loses as a whole; a placement group with `strategy = "spread"` only constrains
placement **within** one zone, so there is one per zone. On the default
three-nodes-over-three-zones layout each group holds one VM and does nothing --
it earns its keep the moment `control_plane_count` exceeds the zone count and
two members share a zone.

GPU pools boot the same snapshot clone as everything else. That was not always
true: until 2026-09-23 a GPU flavor required `spec.source.diskImageRef` on its
boot disk, which a snapshot clone has no way to carry, and any non-empty
`gpu_pools` failed at VM create with `Ready: disk is missing DiskImageRef
(ProvisioningFailed)`. evroc lifted the restriction and confirmed it, and a
`gn-l40s.s` node built from this module's own snapshot now runs. Nothing in the
module changed for it. If you are reading an older checkout against a project
that still enforces the rule, that error is what it looks like -- see
[PLATFORM-NOTES.md](../../PLATFORM-NOTES.md).

GPU pools do not get that choice of zone: evroc runs GPU VMs in **zone `a`
only**, refused by an admission webhook everywhere else, so an unpinned pool
round-robins over `setintersection(zones, gpu_zones)` -- one zone today. The
webhook fires per VM during apply, after that node's boot disk has been
created, which is why `var.gpu_zones` exists rather than letting the platform
say no.

Placement groups, by contrast, are opt-in per pool
(`gpu_pools[*].placement_strategy`), default none, because there is no single
right answer: an inference pool wants `spread` so a host failure costs one
replica, a training pool wants `cluster` so collective operations stay on the
fastest interconnect. `cluster` requires the pool to name a `zone`, since
packing tightly within each of three zones is not what it asks for.

#### The image is built once per zone, not once

`evroc_snapshot` looks regional -- its schema has `region` and no `zone` -- but
it is not. It inherits the zone of the disk in its `disk_ref`, and
`disk-webhook.evroc.com` rejects a disk created from another zone's snapshot:

```
admission webhook "disk-webhook.evroc.com" denied the request: snapshot
"<name>" is in zone "a" but disk is in zone "c"
```

evroc's docs agree and name the only remedy: *"If you need disks in different
zones, you would need to create separate snapshots from disks in those
respective zones."* No snapshot-copy resource and no cross-zone disk clone
exists in the provider, so this is not something the module can route around.

Each zone therefore gets its own build host, its own `evroc_disk.image_target`
and its own `evroc_snapshot`, and each node clones the snapshot belonging to its
own zone. Three zones means three concurrent elemental builds. They run in
parallel, so wall-clock build time is roughly unchanged; the cost is compute.

Two details follow from that:

- **Build hosts come in two flavours.** `evroc_virtual_machine.jumphost` is
  `zones[0]`'s and holds the only public IP -- a default project allows three
  and the API VIP holds one, so one per zone would not fit.
  `evroc_virtual_machine.builder` is every other zone: no public IP (evroc
  gives VMs outbound internet access without one), reached by `ssh -J` through
  the jumphost, in a security group that admits SSH from the jumphost's private
  address and nothing else. They are two resources rather than one `for_each`
  because that security group must read the jumphost, and Terraform tracks
  dependencies per resource, not per instance -- one resource would be a cycle.
- **The builds are not verified identical.** Nothing coordinates them and OCI
  tags are mutable, so a tag that moves mid-build gives one zone different
  software with no visible signal anywhere. That cannot be caught by comparing
  the results: an elemental raw is not reproducible (fresh filesystem UUIDs, GPT
  GUIDs, build-time mtimes), so the sums differ on every multi-zone build
  whether or not anything moved. Pin digests rather than tags to prevent it; see
  `scripts/wait-for-image.sh` for the input-side check that would be sound.
- **The builders are ephemeral, and have to be.** A default project allows 20
  vCPU; three build hosts and three control-plane nodes do not both fit. So
  pass 2 destroys `evroc_virtual_machine.builder` and
  `evroc_snapshot.ai_factory` depends on that teardown, which puts it ahead of
  every node disk and every node. The jumphost stays -- with
  `control_plane_public_ip = false` it is the VPC's only inbound path. The
  trade: if pass 2 fails partway, recovering means `--rebuild` rather than a
  retry, which is acceptable only because the images are verified before pass 2
  begins.

RKE2's etcd is latency-sensitive, and spreading its members across zones does
trade write latency for surviving a zone loss. evroc's zones are close enough
that this is the better default; a deployment that disagrees says so with
`zones = ["a"]`, which collapses every per-zone resource back to one -- one
build host and one snapshot.

### One load balancer, four listeners

evroc puts health checks and PROXY protocol on `evroc_lb_backend_service`, not
on the load balancer, so 6443, 9345, 80 and 443 share one `evroc_loadbalancer`
and one backend pool. The 80/443 services set `proxy_protocol = true` and
health-check `/ping` on **8080**, because the ingress controller's 80/443
entrypoints expect a PROXY header the health checker does not send. The http
and https services, their routes and their listeners are all gated on
`ingress_controller != "none"` together, so nothing is left health-checking a
port nothing listens on.

Since the VIP is an ordinary public IP, `cluster.yaml` uses
`apiVIPMode: external`: no MetalLB, no kube-vip.

### CNI

`canal.yaml` is delivered by per-node Ignition straight into
`/var/lib/rancher/rke2/server/manifests/` on servers, **not** through
elemental's `kubernetes/manifests/` slot. That slot runs only after the API
server answers, by which time RKE2 has already installed the chart with default
values; for canal that lateness is permanent, because the values reach the
DaemonSet through a ConfigMap with no checksum annotation, so the reinstall
produces a byte-identical pod template, nothing rolls, and the wrong
`vethuMTU` stays in `/etc/cni/net.d/10-canal.conflist` for the node's life.
`"canal.yaml"` sorting before `"rke2-canal.yaml"` is what makes ours win.

`vpc_mtu` defaults to 8900, which is what evroc actually hands out over DHCP --
not the 1500 a VPC would conventionally use. `calico.vethuMTU` follows at
`vpc_mtu - 50`. A wrong value never errors: too high hangs large transfers and
TLS handshakes intermittently, too low silently costs throughput on every
pod-to-pod byte, since `configure-network.sh` applies it to the NIC directly.

### Build identity

`time_static.build` is triggered by the cluster name, the API VIP, the
elemental image ref, and hashes of the *rendered* config files, the fetched AIF
release manifest body, and the filtered sysext overrides. Rendered, not the
`.tftpl` sources, so a changed variable renumbers the build even when no
template changed; `time_static` rather than `timestamp()`, so the id does not
drift on every plan.

### Labels

Every evroc object the module creates carries `cluster`, `managed-by`,
`module` and `created` (`YYYYMMDD-hhmmss` of the first apply, from
`time_static.created`), plus a `role`:

| `role` | Objects |
|---|---|
| `network` | VPC, subnets |
| `api-vip` | the standalone public IP the load balancer fronts |
| `loadbalancer` | load balancer, backend pool, backend services, L4 routes |
| `jumphost` / `builder` | build hosts, their boot disks, their security groups, the jumphost IP |
| `image-build` | image-target disks, hotswap attachments |
| `control-plane` | CP nodes, their disks and IPs, placement groups, security group |
| `gpu` | GPU nodes, their disks and IPs, placement groups, security group |

Per-pool and per-listener objects add `pool` or `listener`, so the four
near-identical backend services and routes are distinguishable by label rather
than by a suffix on the name.

Objects whose contents belong to one image generation -- the image-target
disks, the node boot disks cloned from that generation's snapshot, and the
nodes themselves -- also carry `build` (`local.build_labels`). The network,
security groups and load balancer do not: they survive a rebuild untouched.

Two constraints worth knowing before editing this:

- **`build` cannot go in `common_labels`.** It derives from
  `time_static.build`, which reaches `local.api_vip` -- and that public IP
  wears `common_labels`, so Terraform rejects the configuration with a cycle.
- **`evroc_snapshot` accepts no labels at all** -- the provider exposes only
  `system_labels` on it. A snapshot is identifiable by name only, which is why
  `local.snapshot_names` spells out cluster, build timestamp and zone.

`var.user_labels` merges last and can override any of these. It is validated
against Kubernetes label syntax at plan time, because evroc's API enforces it
and an invalid value otherwise fails the apply across every resource at once.

### Things in the image that look wrong and are not

Four constraints in `templates/elemental/butane.yaml.tftpl` are load-bearing
and each has a comment saying so:

- Helper scripts live under `/var/lib/elemental`, never `/opt` -- `/opt` is
  read-only in the initrd and a failed write there drops the whole Ignition
  files stage into a dracut emergency shell.
- Units invoke them as `ExecStart=/usr/bin/bash /var/lib/elemental/foo.sh`. A
  direct `ExecStart` fails 203/EXEC with no AVC in dmesg, because Ignition
  labels those files `var_lib_t` and the denial is dontaudited.
- File modes are decimal (`384`, `416`, `493`). Elemental round-trips the YAML
  through `map[string]any`; a leading-zero octal does not survive.
- `local-path-prep.service` uses `mkdir -pZ`. Without `-Z` the directory
  inherits `usr_t` from `/opt` and the provisioner pod cannot write to it.

Similarly, `iscsi-prep.sh` (shipped only with `suse-storage`) exists because
systemd-sysext merges `/usr` and `/opt` and nothing else: the Longhorn
extension brings `iscsid` but no `/etc/iscsi`. The symptom is nowhere near
iSCSI -- the PVC binds, replicas schedule, and the consuming pod hangs in
`ContainerCreating` with `AttachVolume.Attach ... DeadlineExceeded`.

And note the schema asymmetry between `release.yaml`, which keys extensions as
`- extension: <name>`, and the release *manifest*, which uses
`systemd.extensions[].name`. Getting it wrong yields "requested systemd
extension(s) not found".

## Files

| File | Contents |
|---|---|
| `network.tf` | VPC, per-zone subnets, the standalone API VIP, per-zone placement groups |
| `security-groups.tf` | jumphost / builder / control-plane / gpu groups |
| `loadbalancer.tf` | one LB, one backend pool, four (listener, route, service) sets |
| `availability.tf` | plan-time flavor checks against `data.evroc_compute_profiles` |
| `image-build.tf` | per-zone blank disks, jumphost + builders, hotswap attachments, build-status wait |
| `snapshot.tf` | build id, per-zone `evroc_snapshot`, `effective_snapshot_ids` |
| `control-plane.tf`, `gpu-nodes.tf` | node disks, public IPs, VMs |
| `templates/image-factory.sh.tftpl` | the build script, run on every build host |
| `templates/status-relay.py` | build-status relay on the jumphost: build hosts PUT, the operator GETs |
| `templates/elemental/` | the elemental config directory, rendered and shipped |
| `scripts/wait-for-image.sh` | operator-side HTTP poll of the status relay |

## Variables

### Required

| Name | Type | Notes |
|---|---|---|
| `admin_cidrs` | `list(string)` | SSH sources for every group. An explicit prefix length is required, so `0.0.0.0` will not slip through as a bare address -- but `0.0.0.0/0` is accepted, and opens SSH to the internet. |
| `root_password_hash` | `string` | `openssl passwd -6`. |
| `ssh_authorized_keys` | `list(string)` | At least one. |
| `node_user_password_hash` | `string` | Must differ from `root_password_hash`. |
| `appco_username`, `appco_password` | `string` | Application Collection pull credentials. |
| `suse_registration_code`, `suse_registry_password` | `string` | SUSE registry access. |

### Placement and identity

| Name | Default | Notes |
|---|---|---|
| `region`, `project` | `null` | Fall through to the provider context from `evroc login`. |
| `zones` | `["a","b","c"]` | Zones the cluster spans. One subnet, one control-plane placement group, **one build host and one snapshot** per zone; control-plane nodes round-robin across the list. Only `zones[0]`'s build host gets a public IP. A one-element list gives single-AZ behaviour and a single build. |
| `cluster_name` | `"suse-ai-factory"` | Prefixes every resource name and every hostname. |
| `user_labels` | `{}` | Merged last into every resource's labels, on top of the `cluster`/`managed-by`/`module`/`created`/`role` set the module always applies -- see [Labels](#labels). Kubernetes label syntax, validated at plan time. |

### Network

| Name | Default | Notes |
|---|---|---|
| `vpc_cidr` | `10.20.0.0/16` | Validated not to overlap RKE2's `10.42.0.0/16` / `10.43.0.0/16`. The failure when it does is intermittent and reads as anything but an addressing conflict. |
| `subnet_newbits` | `4` | Per-zone subnets are derived, not listed: `zones[i]` gets `cidrsubnet(vpc_cidr, subnet_newbits, i)`. The defaults give `10.20.0.0/20`, `10.20.16.0/20`, `10.20.32.0/20`. Validated to keep the prefix in evroc's /16../29 range and to yield at least as many subnets as zones. |
| `vpc_mtu` | `8900` | evroc's measured value. Drives `calico.vethuMTU = vpc_mtu - 50`. Range-validated 1330-9000; lowering it *reconfigures the NIC downward* rather than being conservative. |
| `ingress_cidrs` | `["0.0.0.0/0"]` | Sources allowed to 80/443. |
| `api_host` | `null` | Defaults to `rke2-<api_vip>.sslip.io`; lands in the API server certificate's SANs. |
| `api_vip_mode` | `"external"` | The VIP is a real evroc public IP, so nothing in-cluster should claim it. |
| `control_plane_public_ip` | `false` | Buys nothing: the API and ingress arrive via the load balancer, and egress works without one (evroc's shared NAT gateways). |
| `gpu_public_ip` | `false` | Same, for GPU workers. Turn either on only for an upstream that allowlists by source address -- a node behind the shared gateways cannot choose the address it presents. **Public IPs are also quota'd at 3 on a default evroc project**, two of which go to the API VIP and the primary build host, so `true` needs a quota increase first. The quota is enforced by an admission webhook at create time, so exceeding it fails partway through an apply, not at plan. |

### Sizing

| Name | Default | Notes |
|---|---|---|
| `control_plane_count` | `3` | Odd and >= 3 (etcd quorum). |
| `control_plane_flavor` | `"c1a.m"` | |
| `gpu_pools` | `{}` | `map(object({ flavor, count, zone, placement_strategy }))`; pool name becomes the hostname prefix. `zone` pins the pool (default: round-robin across the zones in both `zones` and `gpu_zones`). `placement_strategy` is `"spread"` (anti-affinity, for inference), `"cluster"` (affinity, for training collectives) or omitted (no placement group). A `"cluster"` pool must also set `zone`, since placement groups are zonal. **GPU quota is per GPU model and a default project holds one**, so `count` above that fails at apply time -- no plan-time check exists. |
| `gpu_zones` | `["a"]` | Zones where evroc will run a GPU VM at all. Its `virtualmachine-webhook` rejects the others outright, per VM, at apply time, after that node's boot disk exists -- so the module keeps its own copy of the rule and refuses at plan instead. Widen it when evroc does. |
| `jumphost_flavor` / `jumphost_disk_gb` | `a1a.m` / `200` | Applies to every build host, one per zone. The disk is the binding constraint -- room for the OCI layers and the raw file; the flavor is sized so three build hosts fit a default project's 20 vCPU quota. |
| `image_target_disk_gb` | `32` | Validated `>=` the `raw.diskSize` in `image_disk_size`. |
| `retain_image_target_disks` | `true` | Keep the image-target disks after the snapshots exist. `false` reclaims them. Kept by default as a hedge: a snapshot outlives its source disk and still creates disks, but no node has ever been booted from a clone taken after the source was deleted. `deploy.sh` flips it in a pass of its own by default; `--keep-build-disks` opts out. |
| `node_disk_gb` | `200` | Elemental expands the root on first boot. |
| `image_disk_size` | `"8G"` | The raw image's own size. |

### Image contents

| Name | Default | Notes |
|---|---|---|
| `elemental_image` | `registry.suse.com/beta/uc/elemental:3.1.0-6.5` | The builder image. |
| `components` | `["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]` | `cert-manager` is injected automatically when `rancher` is present. Rendered in a canonical order, not the given one, so reordering the list does not rebuild the image. |
| `aif_version` / `aif_release_manifest_url` | `2.2.0` / derived | The manifest body is fetched at **plan** time purely to hash into the build id, so `terraform plan` needs outbound access to it. |
| `core_platform_override` | beta `base-os-kernel-default-iso:16.1-*` | Not null on purpose, and not safe to null out. AIF 2.2's manifest chain resolves to the GA 16.0 OS image, whose elemental3ctl silently ignores `initrdExtensions` and yields a node that boots fine with no Kubernetes and no error. A GA `base-os-kernel-default` path is rejected at plan time for the same reason. |
| `sysext_image_overrides` | (map) | Keyed by extension name. A name this module never enables is rejected at plan time, and one the release manifest does not carry is fatal in the build script -- either is almost always a typo. Filtered to enabled extensions before hashing, so an override for a disabled extension does not renumber the build. |
| `fips` | `false` | Sets `cryptoPolicy: fips`. |
| `node_username` / `permit_root_ssh` | `suse` / `false` | |
| `nvidia_api_key` | `null` | NGC key, for the GPU operator. |
| `gpu_driver_repository` / `gpu_driver_version` | experimental OBS SLES 16.1 build / `615` | Overrides the manifest's `driver.repository`/`driver.version`. The operator pulls `<repo>/driver:<version>-<uname -r>-sles16.1`, so the repo needs a tag for the nodes' exact kernel. Revert to `registry.suse.com/third-party/nvidia` once it publishes 16.1 drivers. |
| `ingress_controller` | `"traefik"` | `"none"` removes the 80/443 listeners, services and routes together. |
| `rancher_hostname` / `rancher_bootstrap_password` | `null` / generated | Default hostname is `rancher-<api_vip>.sslip.io`. |

### Build and sequencing

| Name | Default | Notes |
|---|---|---|
| `image_ready` | `false` | Set by `deploy.sh`'s second pass. Do not edit by hand on a standing cluster: reverting it destroys the snapshot every node disk is cloned from. |
| `snapshot_ids` | `{}` | Adopt **externally-owned** snapshots and skip the build entirely. Keyed by zone, one entry per entry in `zones`. Never point it at this module's own snapshots. |
| `deploy_nodes` | `true` | `false` stands up only the network, load balancer and jumphost. |
| `image_build_timeout` | `5400` | Seconds `wait-for-image.sh` waits for every zone to report `done`. A zone reporting `failed` ends the wait early. |
| `status_relay_port` | `8080` | Build-status relay port on the jumphost. Open to `admin_cidrs` (read-only) and `vpc_cidr` (publish) during pass 1 only, so `admin_cidrs` must include the address `terraform apply` runs from. |
| `verify_flavor_availability` | `true` | Plan-time check against the live profile list; the error names the flavor and what is actually on offer. Also fails the plan when the cluster's peak vCPU / memory / public-IP demand exceeds the organization quota (usage is not considered -- see the `quota_request` output). |
| `jumphost_username` / `jumphost_image` | `suse` / `null` | Default image is openSUSE Leap 15.6. |

## Outputs

`jumphost_public_ipv4`, `jumphost_ssh_login`, `api_vip`, `api_host`,
`kubernetes_api_endpoint`, `ingress_endpoint`, `rancher_hostname`,
`rancher_url`, `rancher_bootstrap_password` (sensitive), `rke2_token`
(sensitive), `snapshot_ids`, `image_target_disk_names`, `builder_private_ips`,
`build_status_url`,
`control_plane_names`,
`control_plane_fqids`, `control_plane_private_ips`, `control_plane_public_ips`,
`gpu_node_names`, `gpu_node_private_ips`, `gpu_node_public_ips`,
`gpu_quota_request`, `quota_request`, `vpc_cidr`,
`subnet_cidrs`, `node_zones`, `security_group_names`.

## Security

Everything sensitive this module takes -- both password hashes, the AppCo and
SUSE registry credentials, the NGC key, and the generated RKE2 join token and
Rancher bootstrap password -- is stored in Terraform state in plaintext **and**
baked into the elemental image. So the snapshot is a credential in its own
right: anyone who can clone it has the join token and the root password hash,
with no access to state required. Restrict read access to snapshots and disks
in the project the same way you restrict `terraform.tfstate`.
