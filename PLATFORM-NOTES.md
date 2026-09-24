# Platform notes

What evroc supports, and what that means for an [elemental3](https://github.com/suse/elemental)
image. These are the facts the module's design follows from — read them before
choosing flavors, before changing how the image reaches the nodes, and before
assuming a failure is the image's fault.

Elemental produces an image that is **EFI-only** and **immutable**: no kernel
sources, no writable root, no post-boot compilation. Almost everything below is
a consequence of those two properties meeting evroc's.

Provider: [`evroc-oss/evroc`](https://registry.terraform.io/providers/evroc-oss/evroc),
`~> 0.9`. Attribute names cited here are from that version's schema.

---

## UEFI is an experimental, label-gated feature

evroc VMs boot BIOS by default. UEFI is opted into per-VM with a label:

```hcl
user_labels = {
  "compute-experimental-features-UEFI" = "true"
}
```

The module sets this on every node VM and asserts it with a
`lifecycle.precondition`, because the failure mode when it is absent does not
look like a missing label. Elemental installs GRUB into the EFI system
partition and writes an EFI boot entry; nothing installs a BIOS boot sector. A
BIOS-booting VM therefore finds no bootloader at all and sits at the firmware's
"no bootable device" state — from the API the VM is `Running`, it never answers
on any port, and the obvious conclusion is that the image is broken.

The `compute-experimental-features-` prefix is the platform telling you this is
not a stable interface. If a future evroc release renames or withdraws the
label, this is the first thing to check when a previously working image stops
booting. There is no boot-mode field on `evroc_virtual_machine`, so the label is
the only lever.

Sources for the EFI-only claim: elemental's `pkg/bootloader/grub.go` installs
only the EFI target, and `pkg/firmware/efi_manager.go` plus `pkg/upgrade` call
`efibootmgr` on every upgrade.

## There is no console — no serial, no VNC (confirmed 2026-09-19)

Neither the CLI nor the web UI offers one. `evroc compute virtualmachine` has
`create`, `delete`, `get`, `label`, `list`, `update` and nothing else; there is
no `console`, no `serial`, no `vnc`. evroc support confirmed it; VNC access is
on evroc's roadmap.

This is the single biggest practical obstacle to bringing up a custom image here,
and it is worth planning around rather than discovering. Every distinct failure
in the boot path presents identically from outside — the API reports the VM
`Running` and `Ready` within seconds, and nothing ever answers on any port:

- firmware finds no bootloader (the UEFI label above),
- GRUB loads but does not start a kernel,
- the kernel panics or cannot find its root,
- Ignition fails and drops to a dracut emergency shell,
- the system boots correctly and only `sshd` is missing.

`Ready` in `status.conditions` means the hypervisor is executing the VM. It says
nothing about whether anything inside it got as far as userspace.

Two things partially substitute. evroc support **can** retrieve console logs on
request through a ticket, which is how this module's first boot failure was
diagnosed at all — slow, but it works. And a disk can be examined directly:
detach it, hotswap it onto the jumphost, and read the ESP and the root
filesystem from there. The `image_target` disks hold the same bytes the
snapshots were taken from and are already detached, which makes them the
cheapest thing to look at — but `deploy.sh` reclaims them once the snapshots
exist unless it is run with `--keep-build-disks`.

```bash
evroc compute hotswapdiskattachment create forensics-a \
  --disk-ref <cluster>-image-target-a --vm-ref <cluster>-jumphost
# then on the jumphost: parted -s /dev/sdb print; mount /dev/sdb1 /mnt
evroc compute hotswapdiskattachment delete forensics-a   # before any later apply
```

Both hops matter because they answer different questions: the log says how far
the boot got, the disk says what the image actually contains.

## There is no import-image-from-URL

evroc has no equivalent of "create a snapshot from this URL". `evroc_snapshot`
takes a `disk_ref` and nothing else — the only way to get bytes into the
platform is to write them to a disk that already exists inside it.

Hence the module's shape, **repeated once per zone** (see "`evroc_snapshot` is
zonal" below for why it cannot be done once and shared):

1. `evroc_disk.image_target[zone]` — a blank disk, never formatted by anything.
2. `evroc_hotswap_disk_attachment` joins it to that zone's build host.
3. The build host builds the raw elemental image and `dd`s it onto that disk.
4. The attachment is destroyed, **which is the detach**.
5. `evroc_snapshot.ai_factory[zone]` is taken from the now-free disk.
6. Each node's boot disk is an `evroc_disk` with `snapshot = <its own zone's>`.

Steps 1–3 and steps 4–6 are two separate applies, sequenced by the
`image_ready` variable. `deploy.sh` runs both.

Two consequences worth stating plainly. First, the build hosts never receive
evroc credentials: Terraform owns the detach and the snapshot, so nothing on a
build host can talk to the control plane. Second, the disk outlives the build
host — it is the medium the snapshot is taken from, not scratch space — which
is why the `dd` deliberately does not use `conv=sparse`. The disk is reused
across rebuilds, so a region that is zero in the new image must actually be
written as zeros, or stale bytes from the previous image survive underneath it.

### Disk provisioning can take longer than the provider waits (2026-09-22)

The provider gives a disk 10 minutes to report Ready, polling every 24 seconds,
and then fails the apply:

```
Error: error waiting for disk <cluster>-builder-boot-c to be ready:
timeout after 10m0s (attempted 25 times)
```

Observed on a three-zone rebuild: three identical 200 GB builder disks, same
image, same request, created in the same apply. Zones `a` and `b` came Ready
comfortably inside the window and zone `c` did not. Provisioning time is not a
property of the request; it varies by zone and by how busy the platform is.

The failure is more expensive than it looks. The provider records the
half-created disk as **tainted**, so the next apply destroys and recreates it —
paying the provisioning time over again, on a disk that was probably a minute
from Ready — and everything downstream of it in that apply was skipped. So the
module sets `timeouts { create = var.disk_create_timeout }` on every disk it
creates, defaulting to 30 minutes. Waiting costs wall clock; timing out costs
the attempt.

`evroc_virtual_machine` and `evroc_snapshot` accept the same block (`create`,
`delete`, and `update` on the VM) if either turns out to need it.

#### Zone `c` image imports can hang indefinitely (reported to evroc, 2026-09-22)

A longer timeout does not always help, because some of these are not slow, they
are stuck. Twice in one day, a disk created in `se-sto/c` from
`source.diskImageRef: /compute/global/diskImages/evroc/opensuse.15-6.1` sat at

```
status.conditions:
  - type: Ready
    status: "False"
    reason: ImportScheduled
    message: ImportScheduled
    lastTransitionTime: "2026-09-22T13:32:51Z"   # == creationTimestamp
```

and never moved. `lastTransitionTime` equal to `creationTimestamp` is the tell:
the import was scheduled and nothing has happened since. Blank disks in the same
zone completed normally, and identical image-backed disks in zones `a` and `b`
were Ready in about two minutes, so it is the image-import path in that zone,
not the zone and not the request.

Nothing in Terraform recovers from this — the disk is tainted at timeout and
recreated into the same hang. The workaround is `zones = ["a", "b"]`, which
costs a load balancer replacement (`backend_network` is ForceNew; the VIP
survives), puts a second control-plane member in zone `a`, and reduces the
cluster to surviving one zone loss out of two. Reported to evroc; the
environment it was seen on has been destroyed.

### Finding an attached disk from inside the guest (verified 2026-09-18)

Step 3 has to locate the blank disk on the jumphost, and the device path is not
knowable when Terraform renders the script.

evroc [documents the scheme](https://docs.evroc.com/products/compute/guides/hotswap-disk-attachments.html#identify-the-disk-inside-the-vm):
hotswap disks are **SCSI**, addressed at
`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_<SERIAL>`, up to 255 per VM. Observed:

```
scsi-0QEMU_QEMU_HARDDISK_5e88a11b058ce1a5de0458b6a7ace375 -> ../../sda
```

The serial is platform-assigned and opaque — the evroc disk name is nowhere in
it — and `evroc_hotswap_disk_attachment.serial` only exists *after* the
attachment, which requires the jumphost, whose user data *is* the script.
Naming the exact serial is therefore a dependency cycle.

**The bus resolves it without the serial.** The boot disk (`vda`) and the config
drive (`vdb`) are both virtio and neither appears under `/dev/disk/by-id` at
all, so a `scsi-0QEMU_QEMU_HARDDISK_*` glob structurally cannot match them.
`resolve_target_disk()` uses that as its primary identifier: exactly one match
is the target, any other count is a refusal. The size/partition-table
comparison is retained only as a last resort, since it depends on the GB/GiB
question below and on the target happening to be the only unpartitioned disk.

A jumphost's block devices look like this:

| Device | Bus | Size | Partitions | What it is |
|---|---|---|---|---|
| `vda` | virtio | 200 G | 3 (`EFI`, `ROOT`) | boot disk — excluded by `findmnt /` |
| `vdb` | virtio | 1 M | none | cloud-init user data, labelled `cidata` |
| `sda` | **SCSI** | 32 G | none | the attached image target |

Two things to note. The attached disk arrives on a different bus (`sd*`) than
the boot disk (`vd*`), so the `/sys/block` scan must cover both — it does. And
`vdb` is a partitionless disk too, so "no partition table" alone is not
sufficient; the size check is what separates them, and at 1 M versus 32 G that
is not a close call.

**The size tolerance has to exceed 7.4%.** A disk requested as 32 GB comes back
as 32 GiB — 34 359 738 368 bytes against an expected 32 000 000 000 — so evroc's
"GB" is 2^30, and any tolerance under the GiB/GB gap rejects the correct disk
outright. The check uses 20%.

**Unverified:** whether the API permits snapshotting a still-attached disk. If
it does, steps 4–6 collapse into the first apply and `var.image_ready` goes with
them. Worth testing once by hand — it is the largest simplification available to
the image pipeline. `deploy.sh` would still be worth keeping for
`--rebuild` and for reclaiming the build disks, but it would stop being
mandatory.

## GPUs are ordinary VMs

`data.evroc_compute_profiles` exposes GPU profiles in the same namespace as
every other flavor:

| Series | Profiles | GPU |
|---|---|---|
| `gn-l40s` | `.s`, `.m`, `.l` | NVIDIA L40S |
| `gn-b200` | `.s`, `.m`, `.l`, `.xl` | NVIDIA B200 |

They are `evroc_virtual_machine` like everything else. That has one large
security consequence.

The consequence: **security groups apply to GPU nodes**. There is no bare-metal
tier that the platform's packet filter cannot reach, so every node in this
module — control plane, GPU worker, jumphost — sits behind an
`evroc_security_group` with a default-deny inbound posture. The module does not
depend on host-level firewalling inside the image for its network policy.

The NVIDIA GPU Operator on an immutable OS only works with **precompiled**
driver containers. NVIDIA's documentation states that precompiled driver
containers do not support vGPU, and the vGPU guest-driver path needs DKMS
rebuilding the module on every kernel change plus `nvidia-gridd.service`
holding a licence — none of which an immutable root can do. So GPU support here
requires **passthrough**.

**Confirmed (2026-09-24): `gn-l40s` presents a full passthrough device**, not a
vGPU function:

```
0a:00.0 3D controller: NVIDIA Corporation AD102GL [L40S] (rev a1)
```

`nvidia-smi` on the same node reports the whole card (46068 MiB).

The release manifest's driver source does not work on these nodes:

```yaml
driver:
  repository: registry.suse.com/third-party/nvidia
  usePrecompiled: true
  version: 595
```

That registry publishes SLES 16.0 builds only, and a 16.0 module does not load
on the 16.1 kernel (`nvidia: disagrees about version of symbol module_layout`).
The module overrides it through `gpu_driver_repository`/`gpu_driver_version`,
defaulting to an experimental OBS 16.1 build of branch `615`. With it, the
driver daemonset, CUDA validator and device plugin all come up. See the
top-level README.

`data.evroc_disk_images` exposes a `gpu_affinities` list per stock image, which
suggests the platform tracks which images may run on which GPU flavors. A
**custom snapshot** boots on a `gn-l40s` flavor regardless: the same deployment
booted its GPU worker from this module's snapshot and it joined the cluster.

### GPU VMs run in zone "a" only (2026-09-22)

Not a capacity shortage — an admission webhook, refusing outright:

```
API error (403): Forbidden - admission webhook "virtualmachine-webhook.evroc.com"
denied the request: cannot deploy a GPU VM in zone "b". GPU VMs are currently
only supported on zone "a"
```

The wording ("currently") reads like a rollout, not a design, so expect it to
widen. Two things make it worse than a plan-time error:

- It fires **per VM, at apply time**, so a pool spread round-robin over three
  zones creates every node's boot disk first, then 403s on the two-thirds that
  did not land in zone "a".
- The zone of a GPU node is also the zone of the image snapshot it clones, so
  "just move the pool" means zone "a" must be in `var.zones` at all.

`var.gpu_zones` (default `["a"]`) is the module's copy of the rule: unpinned
pools round-robin over `setintersection(zones, gpu_zones)` rather than over
every zone, and a pool pinned outside it fails during **plan**. Widen the
variable the day evroc widens the platform.

### GPU quota is per GPU model, and nothing can check it at plan time (2026-09-22)

```
admission webhook "virtualmachine-webhook.evroc.com" denied the request: not
enough quota to perform request. Requested additional 2 "nvidia.com/AD102GL_L40S"
GPUs. Only 1 "nvidia.com/AD102GL_L40S" GPUs available (out of 1 in quota)
```

A default project carries **one** L40S. The quota is counted per GPU *model*
(`nvidia.com/AD102GL_L40S`), not per flavor and not as part of the vCPU budget.

**The flavor size is the GPU count.** This is the part that makes the error
message confusing, because the number it quotes appears nowhere in the tfvars:

| flavor | GPUs | vCPUs | memory | local disk |
|---|---|---|---|---|
| `gn-l40s.s` | 1 | 15 | 190 GB | 3800 GB |
| `gn-l40s.m` | 2 | 30 | 380 GB | 7600 GB |
| `gn-l40s.l` | 4 | 60 | 760 GB | 15200 GB |
| `gn-b200.s` | 1 | 26 | 260 GB | 4000 GB |
| `gn-b200.m` | 2 | 52 | 520 GB | 8000 GB |
| `gn-b200.l` | 4 | 104 | 1040 GB | 16000 GB |
| `gn-b200.xl` | 8 | 208 | 2080 GB | 32000 GB |

The webhook is handed `count × gpu_quantity`, so a single `gn-l40s.m` requests
two GPUs and is denied on a one-GPU project at `count = 1`. On an unmodified
project the only pool that applies is `gn-l40s.s` with `count = 1`.

Those GPU vCPUs are **not** drawn from the ordinary compute quota — a
`gn-l40s.s` worker's 15 vCPUs joined a cluster already using 16 of a 20 vCPU
allowance, for a total of 31, and the request was not denied.

The quota itself cannot be checked at plan time. `data.evroc_compute_profiles`
reports which profiles *exist*, not what the project may run, and the only quota
data sources the provider ships — `evroc_project_quota` and
`evroc_organization_quota` — expose object storage totals and nothing else. But
the *demand* side is plan-time knowable, because that same data source's
`details[]` carries `gpu_quantity` and `gpu_model` per profile: the module
multiplies it out into the `gpu_quota_request` output, so `terraform plan`
prints the number the webhook is about to compare against the quota, per pool
and summed per model. Ask evroc for the allowance once, then read it off the
plan.

The failure is clean in the sense that matters — the VM is never created, and
re-applying after lowering `count` or raising the quota converges. But the
node's **boot disk** was created before the VM was attempted and stays: in
state, on the platform, and on the bill. Terraform still manages it, so
lowering `count` destroys it on the next apply and `terraform destroy` reclaims
it -- just don't expect the failed apply itself to have rolled anything back.

## The load balancer is one resource, four listeners

evroc's L4 load balancer puts the health check and the PROXY-protocol toggle on
the **backend service**, not on the load balancer. So a single
`evroc_loadbalancer` can serve both the Kubernetes API and public ingress, with
different health checks and different proxy-protocol settings per port:

```
:6443 -> lb_l4_route -> lb_backend_service(6443, tcp health check)
:9345 -> lb_l4_route -> lb_backend_service(9345, tcp health check)
:80   -> lb_l4_route -> lb_backend_service(80,  proxy_protocol, http /ping :8080)
:443  -> lb_l4_route -> lb_backend_service(443, proxy_protocol, http /ping :8080)
                          all four -> one lb_backend_pool(control-plane fqids)
```

The health check for 80 and 443 targets **8080**, not the port being balanced.
Traefik's `web` and `websecure` entrypoints have `proxyProtocol.trustedIPs` set,
so they expect a PROXY header on every connection; the health checker does not
send one, and a health check against 80 would fail permanently. `hostPort: 8080`
exists on the Traefik pod purely as an unwrapped `/ping` endpoint.

Proxy protocol must be enabled on the backend service *and* in Traefik, together.
Either one alone breaks the listener: the backend sees a PROXY preamble it does
not parse, or Traefik waits for one that never arrives.

### A load balancer attaches to the default VPC unless `backend_network` is set

A load balancer with no `backendNetwork` attaches to the bootstrap subnet in
each zone, not to a custom VPC — documented API behaviour, and the right
default for a project that never builds its own network. This module always
builds its own, so it must set the block explicitly: `evroc_loadbalancer` grew
`backend_network` in provider 0.9.4, which `versions.tf` requires as a floor
and `loadbalancer.tf` sets. The diagnosis below is kept because the failure
mode is invisible — if the block is ever dropped, or an older provider pinned,
this is exactly what it looks like.

Every connection to the VIP is accepted and then immediately reset, on every
listener, from every source:

```
$ curl -vk https://<VIP>:9345/cacerts     # from the jumphost, a non-member
* TLS connect error: error:0A000126:SSL routines::unexpected eof while reading
$ curl -v  http://<VIP>:9345/             # a plain HTTP server, next env
* Connected to <VIP> port 9345
> GET / HTTP/1.1
* Recv failure: Connection reset by peer
```

while the backend answers perfectly when dialled directly from another VM in
the VPC (`curl -k https://10.20.0.3:9345/cacerts` → `HTTP/2 200`).

**Cause.** `LoadbalancerSpec` has an optional `backendNetwork`:

```go
// BackendNetwork Optional configuration specifying which VPC and subnets the
// Load Balancer is attached to. If omitted, the Load Balancer will attach to
// the bootstrap networking subnet in each zone.
BackendNetwork *LoadbalancerSpecBackendNetwork `json:"backendNetwork,omitempty"`
```

with `vpcRef` and a `subnets[] {zone, subnetRef}` list. The CLI exposes it as
`--vpc` / `--subnet zone:name`, which
[the create guide](https://docs.evroc.com/products/loadbalancer/guides/create-loadbalancer.html)
documents as *"By default, the load balancer is part of the default VPC and is
deployed to every zone, attaching to the default subnet in each zone."*

**`evroc_loadbalancer` did not expose it before 0.9.4.** Not in 0.9.2, not in
0.9.3: `terraform providers schema -json` listed only `name`, `public_ip_ref`,
`project`, `region`, `user_labels` and the `listener` block, and
`resource_loadbalancer.go` never set `Spec.BackendNetwork`. So every load
balancer this module has ever built sat in the **default** VPC while every
backend sat in `evroc_vpc.cluster` (`10.20.0.0/16`). The data plane has no
route to the pool. The VIP still answers the SYN — that is the frontend — and
then there is nowhere to send the bytes.

`--vpc`/`--subnet` are **immutable after creation**, so this cannot be patched
onto the existing object. The load balancer has to be recreated.

Why every earlier test came back clean, and why none of them found this:

| Observation | Why it is consistent with the wrong VPC |
|---|---|
| Every object reports `Ready` | The controllers only validate references. Nothing in the chain checks reachability. |
| `BackendService.status.backends` resolves all three VMs with correct **private** addresses and zones | Membership is resolved from the VM objects by the control plane. It is metadata, not a data-plane probe. |
| Security group admits 6443/9345 from `0.0.0.0/0`, verified by a successful curl from a VM in a *different* security group | Correct, and irrelevant — the packets never arrive. |
| A single-backend pool in one zone still resets | Zone was never the variable. |
| Pointing the pool at the jumphost — public IP, open SG, `python3 -m http.server 9345` running — still resets, and the server logs **no request** | The jumphost is in the same custom VPC. A public IP does not help: the LB reaches backends over the VPC, not over the internet. This is what killed the "backends need a public IP" hypothesis, and it was the right test for the wrong reason. |
| `BackendPool.status` is `null`, alone in the chain | A red herring. The pool is pure membership and has no conditions to report. |

Reproduced identically on two independently built environments, 2026-09-21 and
2026-09-22.

**Proven by a single-variable A/B, 2026-09-22.** One public IP, one pool, one
service, one route, one listener, all created once. Only the load balancer was
deleted and recreated between runs, reusing the same public IP so the client
dialled the identical address both times. Without `--vpc`:
`curl https://<VIP>:9345/cacerts` → `Recv failure: Connection reset by peer`.
With `--vpc`/`--subnet` and nothing else changed → `HTTP/2 200` and the RKE2 CA
certificate. Recreating the cluster load balancer the same way brought cp-02
and cp-03 — until then stuck on `Get "https://<VIP>:9345/cacerts": connection
reset by peer` — to `Ready` within two minutes, with no reboot and no change to
any security group, pool, service or route.

**Available from provider 0.9.4 (2026-09-22).** The release notes read
*"evroc_loadbalancer: add backend_network support for custom VPCs and subnets;
network changes force replacement"*. The schema is a `backend_network` block
(max 1) with a required `vpc_ref` and one or more `subnet { zone, subnet_ref }`
entries, and it is `ForceNew` — consistent with the API, where the setting is
immutable and a load balancer in the wrong VPC can only be rebuilt.

That retired the whole workaround this module used to carry: `deploy.sh` had a
"pass 0" that applied the VPC, subnets and VIP alone, created the load balancer
with `evroc loadbalancer loadbalancer create --vpc --subnet`, and
`terraform import`ed it, relying on the provider's update being a
read-modify-write that never touches `backendNetwork`. It also made the evroc
CLI a hard dependency of deploying at all. All of it is gone as of this
provider bump; a bare `terraform apply` from empty state is correct again.

The one operational consequence that remains: **`backend_network` forces
replacement.** Changing `var.vpc_cidr` or `var.zones` destroys and recreates the
load balancer, and the VIP stops answering for the length of it.

Related and still unresolved: **Traefik bound no host ports.** The pod ran, but
nothing listened on 80, 443 or 8080 on the node, so the `hostPort: 8080`
health-check entrypoint this module's `HelmChartConfig` depends on was not in
effect. Suspect the same lateness that afflicts canal — the values arriving
after the chart has already installed — but that is a guess, not a diagnosis.

### An unset health-check `target_port` becomes 0, not the service's port (2026-09-21)

`evroc_lb_backend_service.health_check.target_port` is optional, and the
obvious reading — leave it out and the check runs against the port the service
balances — is wrong. The API stores **0**. A health check against port 0 never
passes, so the service carries zero healthy backends while every backend is
healthy, and the listener accepts each connection and resets it:

```
$ curl -vk https://<vip>:9345/cacerts
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLS connect error: error:0A000126:SSL routines::unexpected eof while reading

$ curl -vk https://10.20.0.3:9345/cacerts     # same backend, direct
< HTTP/2 200
```

Which reads as a broken backend and is not. In this module it killed the 6443
and 9345 listeners — RKE2 servers 2 and 3 could not join, looping on
`failed to get CA certs: ... read: connection reset by peer` — while 80 and 443
were fine, because those two were the only services passing an explicit
`target_port` (8080, for Traefik's unwrapped `/ping`).

Three things make it hard to spot:

- Nothing fails. The apply succeeds, the service exists, the backends resolve
  correctly (`backends` shows all three VMs with their addresses).
- It is invisible in a plan diff, because 0 is what the API returns and what
  Terraform stores.
- `terraform state show` is where it shows up: `health_check { target_port = 0 }`.

**The LB API reports no backend health at all**, which is why this has to be
found with `curl`. Every object — load balancer, route, backend service —
reported `status.conditions: [{type: Ready, status: "True"}]` throughout, on a
service that was resetting every connection; `Ready` means the object
reconciled, not that anything behind it answers. `status.backends` on a backend
service lists pool *membership*, not health, and `backendpool get` returns
`status: null`. There is no "how many members are in rotation" to query.

`loadbalancer.tf` now passes `coalesce(each.value.health_check_target,
each.value.port)`, so a service that wants the check on its own port says so
explicitly. Never let this attribute go null.

### Backend-service defaults must be restated, or no plan is ever empty (2026-09-21)

The LB API is Kubernetes-style underneath: the objects are
`backendservices.loadbalancer.evroc.com`, they carry a resourceVersion, and a
controller reconciles them. Two consequences that bite together.

The provider declares several attributes Optional **without** Computed —
confirmed with `terraform providers schema -json`: `ip_protocol_selection`,
`health_check`'s `interval` / `timeout` / `healthy_threshold` /
`unhealthy_threshold`, and `http.expected_statuses`. The API defaults every one
of them. For an Optional-not-Computed attribute, absent in config means null in
the plan, so each apply proposes to unset the server's default, the server puts
it back, and the next plan proposes it again:

```
- ip_protocol_selection = "IPv4" -> null
~ health_check {
  - healthy_threshold = 1 -> null
  - interval          = "5s" -> null
  ...
```

That would merely be untidy if the objects were passive. They are not. A
permanently non-empty plan means **every** apply updates all four backend
services in parallel, while the controller is reconciling them, and the writes
lose the optimistic-concurrency race:

```
Error: error updating backend service suse-ai-factory-api-svc: API error (409):
Conflict - Operation cannot be fulfilled on backendservices.loadbalancer.evroc.com
"suse-ai-factory-api-svc": the object has been modified; please apply your
changes to the latest version and try again
```

Typically one or two of the four succeed and the rest fail, which reads like a
flaky API rather than a plan that should have been empty. `terraform apply
-parallelism=1` makes it go away and hides the real cause.

The fix is in `loadbalancer.tf`: pin those attributes to the API's own defaults.
The plan goes empty, so the writes stop, so the conflicts stop. Worth
generalising — on this provider, an attribute that reappears as `-> null` in
consecutive plans is missing `Computed`, and the cure is always to state the
server's value rather than to retry the apply.

### …but a REAL change to several LB objects at once conflicts too (2026-09-22)

Pinning the defaults removes the *spurious* writes. It does not remove the
conflict, because the conflict is a property of the API, not of that bug. Any
change that touches more than one load-balancer child object hits it again —
observed on a one-line change that added labels to every resource in the module:

```
module.ai_factory.evroc_lb_l4_route.cluster["api"]: Modifications complete after 0s
Error: error updating L4 route suse-ai-factory-supervisor-route: API error (409):
Conflict - Operation cannot be fulfilled on l4routes.loadbalancer.evroc.com
"suse-ai-factory-supervisor-route": the object has been modified; please apply
your changes to the latest version and try again
```

One of the four succeeded and the other three lost the race, exactly as the
backend services did. The controller reconciles the siblings when any one of
them changes, which bumps the resourceVersion the other three in-flight writes
were built against.

**There is no Terraform-side fix.** Parallelism is global (`-parallelism=1`
serialises the whole apply, including the tens of minutes of image build), and
instances of a single `for_each` resource cannot be ordered against each other —
referencing the resource from its own configuration is a cycle. Splitting the
four routes into four named resources chained with `depends_on` would work and
is not worth what it costs in duplication, especially since a serialised write
can still lose to a controller that reconciles between the read and the write.

So the retry lives in `examples/ha-cluster/deploy.sh`, which is the correct
client behaviour for optimistic concurrency anyway: on a 409, re-read and write
again. It re-runs `terraform apply` up to three times, but **only** when the
failure output contains `API error (409)` — any other failure surfaces on the
first attempt, unretried. Each retry re-plans from fresh state, so it applies
the remainder rather than repeating what already landed.

Running `terraform apply` by hand instead? Just run it again. That is all the
script is doing.

## The API VIP exists before anything needs it

`evroc_public_ip` is a standalone resource, not an attribute of a load balancer
or a VM. The API VIP's address is therefore known as soon as it is created —
before the load balancer, before the jumphost, before the image build.

This is what makes the design work at all. The elemental image bakes
`cluster.yaml` in at build time, and `cluster.yaml` needs the VIP. On a platform
where the address only appears once the load balancer has backends, and the
backends need the image, and the image needs the address, that is a cycle you
have to break with a placeholder and a post-boot rewrite. Here there is no
cycle: allocate the IP, build against it, attach it to the load balancer.

It also means `apiVIPMode: external` — the VIP is the platform's, so the cluster
needs no MetalLB, no kube-vip and no embedded cluster operator to own it.

RKE2 servers retry the 9345 registration endpoint until it answers, so
populating `lb_backend_pool.backend_refs` after the VMs exist is safe; the nodes
simply retry across the window where the pool is empty.

## Jumphost: openSUSE Leap 15.6

`data.evroc_disk_images.this.opensuse_15_6_1`. It is the build host because
evroc offers no Leap 16, and because `elemental customize` runs inside podman —
the host distribution only has to provide podman, python3 and curl.

If `elemental customize` misbehaves on Leap 15.6, the fallbacks are
`sles_15_6_1` or `ubuntu_24_04_1` with upstream podman. Nothing in the built
image depends on the build host's distribution.

Size the jumphost for the work, not for idling: it holds the pulled OCI layers,
the raw image, and a working copy at once. `jumphost_disk_gb` defaults to 200.

The `jumphost_username` account (default `suse`) has **passwordless sudo to
root**, set up by the cloud-init user data and confirmed working on a real
jumphost (2026-09-18). That matters for two reasons. It is the reason
`image-factory.sh` can run as a privileged `runcmd` and `dd` straight to a block
device while the interactive login stays unprivileged. And it means the jumphost
is a full root foothold for anyone holding an SSH key in `ssh_authorized_keys` —
it is the module's only inbound admin path, it holds the rendered elemental
config directory with every credential in it, and `admin_cidrs` is the only
thing in front of it. Treat it accordingly; it is not a bastion in the
restricted sense.

The elemental nodes are unaffected by this: they are root-only, with no
equivalent unprivileged account and no sudo.

## Networking

### Regional and zonal resources (verified 2026-09-18)

evroc's resource model splits along a line worth stating explicitly, because it
decides what a multi-AZ cluster costs:

| Regional | Zonal |
|---|---|
| `evroc_vpc` | `evroc_subnet` |
| `evroc_loadbalancer`, `evroc_lb_backend_pool` | `evroc_placement_group` |
| `evroc_public_ip`, `evroc_security_group` | `evroc_disk`, `evroc_virtual_machine` |
| | `evroc_snapshot` (see below) |

A subnet belongs to exactly one zone and a VM can only attach to a subnet in
its own zone, so spanning zones means one subnet per zone -- there is no
stretched subnet. The load balancer and its backend pool are regional, so
**one** load balancer fronts backends in every zone.

### `evroc_snapshot` is zonal, and its schema says otherwise (verified 2026-09-18)

This is the single most expensive thing to get wrong on this platform, so it
gets its own heading.

`evroc_snapshot` **looks regional**. Its schema has a `region` attribute and no
`zone` attribute at all; the only thing tying it to a zone is the disk named by
`disk_ref`. Plan and apply both succeed. The constraint surfaces one resource
later, when a node disk in another zone tries to clone it:

```
Error: error creating disk <cluster>-cp-03-boot: API error (403): Forbidden -
admission webhook "disk-webhook.evroc.com" denied the request: snapshot
"<cluster>-<build-id>-snapshot" is in zone "a" but disk is in zone "c"
```

evroc's own docs state it plainly: *"Snapshots are zonal resources. Each
snapshot exists in the same zone as the source disk it was created from. […] If
you need disks in different zones, you would need to create separate snapshots
from disks in those respective zones."*

There is **no snapshot-copy resource and no cross-zone disk clone** anywhere in
the provider. Nothing in Terraform can move an image between zones.

#### A snapshot survives its source disk being deleted (verified 2026-09-22)

Deleting the disk a snapshot was taken from is permitted and leaves the
snapshot usable. Checked against a live cluster: `<cluster>-image-target-c` was
deleted, after which

```
evroc compute snapshot get suse-ai-factory-20260922-100927-snapshot-c -o yaml
```

still reported `status.conditions[Ready] = True` and `restoreSize: 32 GB` — with
`spec.diskRef` still naming the deleted disk, so that field is a record of
provenance, not a live reference — and

```
evroc compute disk create probe-c --snapshot suse-ai-factory-20260922-100927-snapshot-c \
  --zone c --size-amount 32 --size-unit GB
```

succeeded.

**What is still not verified is booting such a clone.** `probe-c` was created
and never started, and no node has yet been built from a snapshot whose source
disk was already gone. `var.retain_image_target_disks` still defaults to `true`
(see the race below), but `deploy.sh` reclaims by default in a pass of its own;
`--keep-build-disks` keeps the 96 GB as a hedge against that untested
dependency.
If you do reclaim, do it in **an apply of its own, after** pass 2 — creating a
snapshot and destroying the disk it is taken from in one apply depends on an
ordering Terraform's graph does not pin down, and losing that race leaves the
built image on neither a disk nor a snapshot.

One consequence for `snapshot.tf`: `disk_ref` cannot simply reference
`evroc_disk.image_target[z].fqid`, since that is an "Invalid index" once the
disks are gone. It falls back to a string built from a sibling disk's fqid
prefix, and carries `ignore_changes = [disk_ref]` — a wrong value there would
not fail the plan, it would delete the snapshot every node was cloned from.

For a while this file claimed the opposite — that deleting the source disk
emptied the snapshot. That was wrong, and the test above is what disproved it:
the `disk is missing DiskImageRef` error that prompted the theory has a
completely different cause, below.

evroc support confirmed all of this directly (2026-09-19), including that the
disk-plus-temporary-VM dance this module performs is the intended workaround
today:

> Right now, snapshots are zonal and any disks created from them must be
> deployed in the same zone. We don't yet have the concept of regional scoped
> snapshots or any way to copy snapshots from one zone to another. We also do not
> currently offer an official way to create and upload your own OS image that you
> can then deploy across a region.

**Two items on evroc's roadmap would each collapse most of this module's image
pipeline:**

- **Customer-provided OS images** — upload an image to *regional* object storage
  and reference it exactly like an evroc-provided OS image, deployable in any
  zone from one master copy. evroc names this as the right fit for this use
  case. It removes the per-zone build, the build hosts, the image-target disks,
  the hotswap attachments, the sentinel wait *and* the two-pass apply: the module
  would build one image, upload it, and create nodes from it in a single pass.
- **Regional snapshots** — framed as a backup feature rather than an
  image-distribution one. It would fix the fan-out without fixing the two-pass
  structure, since a snapshot still has to come from a written disk.

Anything built on the current shape should expect to be deleted rather than
extended. Do not invest further in making the per-zone fan-out cheaper.

So a multi-AZ cluster cannot build its image once. The module runs a complete
build **per zone** — one build host, one image-target disk, one snapshot each —
and every node clones its own zone's snapshot. Three zones means three
concurrent elemental builds and three temporary build hosts. They run in
parallel, so wall-clock build time is roughly unchanged; the cost is compute,
not waiting.

Two consequences fall out of that, both handled in the module:

- **Only `zones[0]`'s build host gets a public IP.** A default project allows
  three and the API VIP holds one, so one public IP per build host would put a
  three-zone cluster over quota before a node existed. The others need no
  inbound path: evroc gives every VM outbound internet access regardless, which
  is all `podman pull` requires. They are reached with `ssh -J` through the
  public one, and they sit in their own security group that admits SSH from
  that host's private address and nothing else.
- **The builds are independent, and nothing verifies they agree.** Each pulls
  the same OCI references at roughly the same moment, but OCI tags are mutable.
  A tag that moves mid-build gives one zone different software, and every
  downstream signal — sentinels, snapshots, node boots — looks identical either
  way. Comparing the built images does not help: `elemental customize` writes
  fresh filesystems, so filesystem UUIDs, GPT GUIDs and mtimes differ between
  any two runs and the sha256 sums never match (this module shipped that check
  briefly; it failed every multi-zone build). The sound check is on the inputs —
  resolve each OCI reference to a digest per host and compare those — and is not
  implemented. Pinning digests rather than tags prevents the divergence outright
  and is the recommendation until it is.

The module still defaults to `zones = ["a", "b", "c"]`, one control-plane member
per zone: RKE2's etcd is latency-sensitive and cross-zone writes are slower, but
evroc's zones are close enough that surviving a zone loss is the better trade.
`zones = ["a"]` collapses everything above back to one build host, one snapshot
and no independent-build concern — the cheaper shape, and the right one when a zone loss
is out of scope.

#### GPU VMs and snapshot-backed disks — restriction lifted 2026-09-23

**Current state: GPU pools work.** A `gn-l40s.s` node booted from this module's
own snapshot runs, and evroc confirmed the change. Nothing in the module was
altered for it — `gpu-nodes.tf` had always been written for this. The rest of
this section is the history, kept because the error is opaque and a project
that has not picked up the change will still produce it.

Until then, GPU VMs were restricted to disks created from an evroc-provided
image, because the platform injects a cloud-init that installs the GPU
prerequisites into the guest. A disk cloned from a snapshot carries no
`spec.source.diskImageRef`, so the validation rejected it:

```
Error: error waiting for virtual machine <node> to be ready: condition check
failed: VM <node> provisioning failed:
  - Ready: disk is missing DiskImageRef (ProvisioningFailed)
  - VMIsRunning: disk is missing DiskImageRef (ProvisioningFailed)
```

The message names the missing field, not the rule, which is why this took a
round-trip with evroc to identify. Note what it is *not*: not a quota problem,
not the zone-`a` webhook, not anything about the snapshot's health. The same
snapshot, in the same zone, booted control-plane VMs perfectly well — the
restriction was on the GPU flavors only.

No workaround was implemented while it stood. The alternative was to build GPU
workers from a stock evroc image and join them to RKE2 separately, which would
have added a second, permanent node path outside the immutable elemental image
in exchange for a restriction that turned out to be temporary. `gpu_pools`
stayed `{}` instead, which cost one default and no code.

`gpu_pools` still defaults to `{}`, now for the ordinary reason: a GPU pool is
opt-in, it is quota'd per GPU model, and it is expensive.

### Placement groups are zonal

`evroc_placement_group` takes `strategy = "spread"` (anti-affinity: keep
members off the same physical host) or `"cluster"` (affinity: pack them onto as
few hosts as possible). The web guide documents only `spread`; the provider
accepts both.

A placement group is scoped to **one zone** and can only constrain VMs within
it, which is why the module creates one per zone rather than one per cluster.
The two mechanisms are complementary, not alternatives: zones protect against
losing a datacentre, placement groups against losing a host inside one.

For GPU pools the strategy is per pool (`gpu_pools[*].placement_strategy`) and
defaults to none. `spread` suits an inference pool, where a host failure should
cost one replica; `cluster` suits a training pool doing collective operations,
where the interconnect is the bottleneck. Because the group is zonal, a
`cluster` pool must also pin a zone -- otherwise it would be packed tightly
within each of several zones and spread across them, which is the opposite of
the request and entirely silent.

### Addressing

`vpc_cidr` must not overlap RKE2's cluster CIDR `10.42.0.0/16` or its service
CIDR `10.43.0.0/16`. The module validates this. An overlap does not fail
cleanly — it produces intermittent, host-specific connectivity loss that reads
as a CNI bug, a DNS bug, or flaky hardware, and essentially never as an
addressing conflict.

### MTU is 8900, not 1500 (verified 2026-09-18)

```
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 8900 qdisc mq state UP
```

evroc brings interfaces up with a jumbo MTU, handed out over DHCP — there is no
`network-config` on the config drive, so nothing in the image chose this.
`var.vpc_mtu` therefore defaults to **8900**, and the pod veth MTU follows at
8850.

**1500 is not the safe conservative choice here.** `configure-network.sh` does
not merely record the value, it runs `ip link set dev eth0 mtu <vpc_mtu>` — so
a 1500 in `terraform.tfvars` actively downgrades a link the platform brought up
at 8900, costing roughly six times the per-packet overhead on every pod-to-pod
byte in the cluster. The variable is range-validated (1330–9000) to make an
accidental 1500 visible, but a value inside that range is accepted as
deliberate.

Still worth confirming end to end with `ping -M do -s 8872` between two VMs in
the subnet: a NIC configured at 8900 is not proof that every hop between two
hosts carries it. If it turns out not to, the symptom is the usual silent one —
small packets flow, large ones vanish, TLS handshakes hang partway.

### One NIC, public IP by 1:1 NAT (verified 2026-09-18)

```
eth0             UP             10.20.0.2/20 fe80::94ba:54ff:fe2c:e431/64
```

One interface, carrying only the private address; the public IP is NAT'd and
never appears in the guest. So the module's assumption holds, and the code it
gates stays in its simple form: `configure-network.sh` and `write-node-ip.sh`
both detect a single NIC and no-op, RKE2's default `node-ip` is already the
right address, and `flannel.regexIface` is unnecessary — there is no public
interface for flannel to mistakenly choose as its VXLAN source.

Note the link-local IPv6 address. The image disables IPv6 per-interface at
boot, which is what keeps this from becoming a second candidate address.

### Public IPs are quota'd, and the quota is 3 (verified 2026-09-18)

**The quota is raisable on request.** evroc support offered an increase
unprompted (2026-09-19) — *"if you require additional public IP addresses to work
around the issue temporarily, let us know and we can increase your quota"* — and
the same goes for vCPU. The defaults below are what an untouched project gets,
not a hard ceiling. A GPU pool needs an increase regardless.

```
API error (403): Forbidden - admission webhook "publicip-webhook.evroc.com"
denied the request: not enough quota to perform request. Requested additional
public IP but no public IPs are available (out of 3).
```

A default evroc project allows **three** `evroc_public_ip` resources. This
module spends two of them before any node gets one — the API VIP
(`evroc_public_ip.cluster`, which is also the Kubernetes API endpoint baked into
the image) and the primary build host. That leaves exactly one, against a
default of three control-plane nodes.

Two of three is also the ceiling no matter how many zones are configured. The
per-zone build described above needs a build host in each zone, but only
`zones[0]`'s gets a public IP; the rest are private-only and tunnelled through
it. Were that not the case, a three-zone cluster would need four IPs to build
an image at all.

So on a default quota, `control_plane_public_ip = true` **cannot** succeed. It
fails partway rather than at plan time: the quota is enforced by an admission
webhook at create time, so Terraform gets partway through the
apply, creates whichever IPs fit, and errors on the rest. The nodes whose IPs
failed are simply not created, and state is left holding the ones that
succeeded.

`data.evroc_project_quota` exists but exposes only object-storage counters
(`object_storage_total_size`, `object_storage_usage`) — there is nothing for
public IPs, so the module cannot check this at plan time. On a default project,
set both toggles false:

```hcl
control_plane_public_ip = false
gpu_public_ip           = false
```

which is the better posture anyway — the control plane is reachable through the
load balancer either way.

### Public IPs are recycled across clusters, which breaks SSH host keys (2026-09-22)

With a quota of three and a pool shared across the region, a destroyed
cluster's public IP comes back to the next one often enough to treat it as the
normal case rather than bad luck. The new jumphost is a different machine with
a different host key on the same address, so the operator's `~/.ssh/known_hosts`
now says the host is an impostor:

```
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
```

`ssh` then refuses to connect. Interactively that is obvious and
`ssh-keygen -R <ip>` fixes it. **Non-interactively it was not obvious at all**:
`scripts/wait-for-image.sh` polls over SSH, a refused connection exits 255, and
255 is indistinguishable from "the host has not finished booting", so the wait
treated a permanent failure as transient and sat there until
`image_build_timeout` — 90 minutes by default — expired. The only visible
symptom was a line repeating every 30 s saying SSH did not complete this poll.

Fixed on both halves, and neither alone is enough:

- The script now uses a `mktemp` known_hosts discarded on exit, plus
  `GlobalKnownHostsFile=/dev/null`. It never reads or writes the operator's
  file — these hosts were created minutes ago by the same apply, so
  recognising them across runs was never worth anything, while
  `StrictHostKeyChecking=accept-new` against an empty file still pins each key
  for the duration of the run.
- The jump hop needs the options too, and **`ProxyJump` does not pass the
  parent's `-o` flags down to the `ssh` it spawns**, so the tunnel would have
  gone on consulting the real known_hosts — on the single host every builder is
  reached through. Hence the explicit `ProxyCommand=ssh … -W %h:%p`.

It also captures ssh's stderr, prints it with every transient, and after five
minutes of consecutive failures says out loud that the failure is probably not
transient and gives a copy-pasteable command to reproduce it by hand.

### Compute is quota'd too, at 20 vCPU / 160 GB (verified 2026-09-18)

```
API error (403): Forbidden - admission webhook "virtualmachine-webhook.evroc.com"
denied the request: not enough quota to perform request. Requested additional
8 vCPUs and 32.0GB memory. Only 4 vCPUs (out of 20 in quota) and 96.0GB memory
(out of 160GB in quota) available
```

vCPU, not memory, is what binds: a default project's 160 GB is generous next to
its 20 vCPU. And because the image must be built once per zone, build hosts
multiply — at `a1a.l` (8 vCPU) three of them are 24 vCPU and a three-zone
cluster cannot get through pass 1 at all, let alone stand up nodes afterwards.

Two design choices follow, and both are load-bearing rather than tidy-ups:

- **`jumphost_flavor` defaults to `a1a.m`** (4 vCPU / 16 GB), not `a1a.l`. The
  build is disk- and network-bound, so this costs little; the disk
  (`jumphost_disk_gb`) is the real constraint.
- **Pass 2 destroys the builders** before creating any node. Their job ends when
  their image-target disk holds a verified image, and
  `evroc_snapshot.ai_factory` lists `evroc_virtual_machine.builder` in its
  `depends_on` so the teardown is ordered ahead of everything downstream of a
  snapshot. Without that edge Terraform would create nodes in parallel with the
  teardown and collect this 403 for a cluster that fits perfectly well once the
  apply settles. The jumphost survives — with `control_plane_public_ip = false`
  it is the only inbound path into the VPC.

The resulting budget, on the default three zones and three control planes:

| | vCPU |
|---|---|
| pass 1: 3 build hosts @ `a1a.m` | 12 |
| pass 2: jumphost + 3 control planes @ `c1a.m` | 16 |
| quota | 20 |

That leaves 4 vCPU. A GPU pool does not fit in it — `gn-*` profiles need their
own quota increase, and so does any larger control-plane flavor.

Like the public-IP quota, this is an admission webhook at create time, not a
plan-time check, and `data.evroc_project_quota` exposes nothing about it.

### Egress works without a public IP

evroc's VPC docs: *"VMs can make outbound connections to the internet, and
inbound connections are possible with a Public IP."* Outbound is a property of
the VPC, not of having an address on it; there is no NAT gateway resource to
create and none is needed.

Confirmed in production (2026-09-22): a full cluster whose only two public IPs
are the API VIP and the jumphost pulls Rancher, cert-manager and the AppCo
charts at runtime and serves the Rancher dashboard through the load balancer.
`control_plane_public_ip` and `gpu_public_ip` both default to `false` because of
it.

evroc support confirmed the mechanism (2026-09-19):

> Yes, VMs can reach the internet even if they have no public IP. We have a
> number of shared NAT gateways in our virtual networking infrastructure that
> permit this — any VMs without public IPs are routed to one of those gateways
> and out to the internet. However, those gateways are not user-configurable in
> any way.

Two consequences. The gateways are **shared and opaque**: no control over the
source address a node presents, so anything upstream that allowlists by source IP
cannot be pointed at a node without a public IP of its own. And egress is
governed **only** by security groups — evroc defaults to deny-all, and this
module's `egress_all_rules` (all TCP, all UDP, `0.0.0.0/0`) is what opens it.
Tightening that is the supported way to restrict egress; there is nothing at the
gateway to configure. Note that those rules cover TCP and UDP and nothing else,
so ICMP is blocked in both directions — `ping` between two VMs in this VPC fails
by design and is useless as a liveness check. Probe a TCP port instead.

This matters twice over. It is what makes `control_plane_public_ip = false` and
`gpu_public_ip = false` safe despite the image not being self-contained —
Rancher, the GPU operator's driver containers and the AppCo charts are all
pulled at runtime. And it is what lets the non-primary build hosts do a full
`podman pull` of the elemental customize image with no inbound path at all.

Worth confirming on a first deployment anyway, because the failure mode is
silent and slow: nodes boot, join the cluster, report `Ready`, and then every
runtime chart install sits in `ImagePullBackOff`. `kubectl get pods -A` is the
tell, not anything in the Terraform apply.

```bash
ssh <jumphost>                                    # then, from there
ssh <node_username>@<control-plane private ip>    # allowed by the
                                                  # ssh-jumphost rule on the
                                                  # control-plane group
curl -sSf https://dp.apps.rancher.io/v2/ && echo "egress works"
```

`evroc_virtual_machine.stack_type` accepts `ipv4-only`, `ipv6-only` and
`dual-stack`, defaulting to the subnet's. The module leaves it at the default
and the image disables IPv6 per-interface at boot.

## Node roles come from user data, not from the VM

Every node boots the same image. Its role is declared in exactly one place:
`/var/lib/elemental/runtime.env`, written by per-node Ignition delivered through
`cloud_config_user_data`.

```
NODETYPE=server        # or agent
IS_INIT_NODE=true      # first control plane only; omitted elsewhere, never false
```

This is why `cluster.yaml` inside the image carries no `nodes:` list. Adding a
GPU pool is an add — a new disk and a new VM — not an image rebuild and a
cluster replacement.

The kernel command line sets `ignition.platform.id=proxmoxve`. That is not a
typo and not the hypervisor's name — see below.

### User data is delivered verbatim on a NoCloud drive (verified 2026-09-18)

A VM carries a third block device, `vdb`, 1 MB, partitionless, labelled
`cidata`, holding two files: `user-data` and `meta-data`. That is a standard
cloud-init NoCloud drive — evroc builds it themselves; it is not KubeVirt's own
rendering, which would name the files `userdata` and `metadata`. A 15 813-byte
`user-data` has been delivered intact, which raises the known-good lower bound
from 14 581.

### `ignition.platform.id` must be `proxmoxve`, not `kubevirt` (resolved 2026-09-21)

This cost several days, so the reasoning is written out in full.

evroc runs KubeVirt — the guest's own DMI string is `KubeVirt None` — and evroc
recommended `ignition.platform.id=kubevirt`. It is the wrong value, because
`ignition.platform.id` names a config-**delivery convention**, not a hypervisor.

The symptom was that every control-plane node reported Running and Ready through
the API while answering nothing on any port, ever. With no serial console and no
VNC on the platform, that is invisible from the outside. A console capture
retrieved through evroc support showed:

```
Expecting device /dev/disk/by-label/ignition...
[TIME] Timed out waiting for device /dev/disk/by-label/ignition.
       Starting Ignition (fetch-offline)...
[***] A start job is running for Ignition (fetch-offline) (48s / no limit)
```

Both halves of that mislead, and both wasted time:

- The `by-label/ignition` wait is **not** the failure. It comes from openSUSE's
  `30ignition-microos` dracut module (`ignition-setup-user.sh`), whose mount is
  guarded by `if [ -e /dev/disk/by-label/ignition ]`. It is an optional
  embedded-config convenience, it times out harmlessly, and the boot continues
  past it. It is also a near-perfect decoy for "the platform id is missing and
  Ignition fell back to `metal`", which it is not.
- `A start job is running … (48s / no limit)` is the real one. `no limit` is
  literal: nothing ever fails it.

The provider was then run by hand, on a jumphost, against evroc's own live
`cidata` drive — no node, no console, no boot. The binary is at
`/usr/lib/dracut/modules.d/30ignition/ignition` inside the image's LiveOS
squashfs (there is no `/usr/bin/ignition`), and it runs fine on an ordinary
Leap host:

```
# IGN=/mnt/sq/usr/lib/dracut/modules.d/30ignition/ignition
# $IGN --root=/tmp/ir --platform=kubevirt --stage=fetch-offline --log-to-stdout
DEBUG : config drive ("/dev/disk/by-label/config-2") not found. Waiting...
DEBUG : config drive ("/dev/disk/by-label/config-2") not found. Waiting...
...forever
```

**The `kubevirt` provider looks for `config-2` — ConfigDrive — and retries
without any bound.** The drive evroc presents is NoCloud (`cidata`), which
never carries that label. So Ignition spins in
`fetch-offline` for the life of the VM: it does not fail, does not fall back,
does not reach `sshd`. Exactly the observed signature.

```
# $IGN --root=/tmp/ir --platform=proxmoxve --stage=fetch-offline --log-to-stdout
DEBUG : op(1): executing: "mount" "-o" "ro" "-t" "auto" \
        "/dev/disk/by-label/cidata" "/tmp/ignition-configdrive..."
DEBUG : config drive (".../user-data") contains a cloud-config configuration, ignoring
INFO  : fetch-offline: fetch-offline passed
```

`proxmoxve` mounts `cidata` and reads `user-data`, because Proxmox generates the
same standard NoCloud drive evroc does. (It declined the config in that run only
because a *jumphost's* `user-data` really is cloud-config; on a node it is
Ignition JSON and parses. The corollary is that node user data can never carry a
`#cloud-config` header — `proxmoxve` skips anything that starts with one.)

Two things to remember from this:

- Verify a provider by running it, not by reading about it. Ignition 2.21.0 has
  30 providers compiled in; `strings $IGN | grep -oE 'internal/providers/[a-z0-9]+'`
  lists them, and any one of them can be pointed at a real drive in userspace.
- On a platform with no console, prefer failures that are loud and bounded. The
  reason this took days is that the failure mode was an infinite silent retry
  inside an initrd on a machine with no way to look at it.

`image-factory.sh` now records the equivalent evidence at build time into
`/var/lib/image-factory/boot-diagnostics.txt` — the installed kernel command
line, the device labels the image's own Ignition binary searches for, the
ignition dracut modules present, and `Install/install.yaml` — and
`wait-for-image.sh` prints it into the apply log while the build hosts still
exist.

### The built image is installation media, not a node image (verified 2026-09-21)

Worth knowing before doing forensics on one. `elemental customize --type raw`
produces a disk with **two** partitions — `EFI` (vfat) and `RECOVERY` (ext4,
holding `LiveOS/squashfs.img`, `Install/install.yaml` and `Install/initrdExt.cpio`)
— and leaves the rest of the GPT unallocated. Its GRUB menu entry reads
`SUSE Linux Enterprise Server 16.0 (Installer)`.

Consequences:

- There is no `SYSTEM` partition and no installed root to inspect in the image.
  `CATALYST` and `SYSTEM` are created by the installer on the node's first boot.
- The menu entry carries no literal command line: it is `linux … ${cmdline}`,
  with `cmdline` set in `/boot/grubenv` on the ESP, to elemental's own
  `root=live:LABEL=RECOVERY … elm.recovery elm.reset console=ttyS0`. That is the
  *installer's* line. Ours is not there and should not be.
- Ours is in `Install/install.yaml` as `bootloader.kernelCmdline`, which the
  installer applies to the system it lays down. `kernelCmdLine` in the module's
  `install.yaml` is honoured; it just takes effect one boot later.
- So a node's first boot runs the installer and ends in a legitimate
  `reboot: Restarting system`. The second boot is the installed system. A
  console log showing `Found device /dev/disk/by-label/SYSTEM` is therefore boot
  #2, not boot #1 — that timestamp is what distinguishes an install failure from
  a post-install failure.

What IS verified is the delivery itself.

`cloud_config_user_data` arrives **byte-for-byte**. The drive holds exactly what
Terraform rendered, starting at the first character:

```
$ head -c 14 /mnt/cidata/user-data
#cloud-config
```

No `## template: jinja` header, no re-serialization, nothing prepended — which
is what the design needs, since the nodes send raw Ignition JSON through the
same field and any wrapping would break it. `meta-data` is a separate JSON
document the platform generates itself (`instance-id`, `local-hostname`,
`public-keys`), so it does not compete with user data for space. There is **no**
`network-config`, which is why the guest's 8900 MTU comes from DHCP rather than
from anything in the image.

**The size limit is 1 MB** (evroc, 2026-09-22). It is not a cloud-init or
Ignition limit: a VM is a KubeVirt object underneath, user data is a field in
it, and 1 MB is the ceiling on the object. The `cidata` drive in the guest is
exactly 1 M (see the block-device table above), which is the same number seen
from the other side. The largest payload this module has actually shipped is
14 581 bytes, so there are roughly two orders of magnitude of headroom.

The module checks two different numbers, and they mean different things:

| | |
|---|---|
| **1 MB** | the platform's real limit, on the object. `local.user_data_max_bytes` sets the check a little under it (768 KiB), because a payload that is base64-encoded into the object is 4/3 its raw size and the budget is the object's, not the payload's. Node VMs are checked against this. |
| **32 KiB** | a tripwire, not a limit. The build hosts carry the whole elemental config directory gz+base64'd in their cloud-init, so a template bug that renders something twice shows up as a size explosion. 32 KiB is ~2× a known-good payload and ~1/24 of what the platform would reject, which is the point: it fails at plan time with a pointer at the likely cause, long before anything reaches evroc. |

## base.d goes missing when the OS image's elemental3ctl is too old

Diagnosed 2026-09-21. The symptom is a cluster that never appears: every node
installs, reboots, comes up, and has no Kubernetes, no users and no sshd. It is
not an evroc property and it is not an upstream bug — it is a version skew, and
the module's default now avoids it. Recorded in full because the symptom points
nowhere near the cause.

**In one sentence, portable to any platform:** `elemental customize` writes
`bootloader.initrdExtensions` into the media, but the install is run later by
the elemental3ctl baked into the *OS image*, and a 3.0.x one ignores that key —
so pin the OS image to the beta 16.1 line
(`registry.suse.com/beta/uc/base-os-kernel-default-iso`) instead of letting AIF
2.2's manifest chain resolve it to GA `elemental/base-os-kernel-default-iso:16.0-*`,
or the node boots clean with no Kubernetes, no users and no error anywhere.

### Two elemental versions, only one of which is obvious

A build involves two of them:

- `var.elemental_image` — the **customize container**. It writes the media and
  nothing else.
- the **elemental3ctl baked into the OS image** — this is what actually runs the
  install, on the node, one boot later.

`bootloader.initrdExtensions` is emitted by the first and has to be honoured by
the second. Support for it landed on the 3.1.0 line; every 3.0.x elemental3ctl
parses `install.yaml` without complaint and silently ignores the key. So a
3.1.0 customize container paired with a 3.0.x OS image produces media that is
correct and an installed system that is missing the whole payload.

### The default manifest chain walks straight into it

With `core_platform_override` unset, the chain resolves like this — verified by
pulling each artefact:

```
SUSE/aif @ aif-operator-2.2.0  uc-release-manifest/release_manifest.yaml
  corePlatform.image:
    registry.suse.com/elemental/rke2/rke2-manifest:1.35.6-48.1
      components.operatingSystem.image.iso:
        registry.suse.com/elemental/base-os-kernel-default-iso:16.0-3.15
```

That is the GA `elemental/` repo on the **16.0** line. The beta images that
carry a 3.1.0 elemental3ctl are `registry.suse.com/beta/uc/base-os-kernel-default-iso`
on the **16.1** line. So the published AIF 2.2 chain cannot build a working
cluster on its own, and `var.core_platform_override` defaults to a 16.1 image
for that reason rather than as a preference for beta bits.

### What it looks like from the node

```
# on the built image's RECOVERY partition -- the media is CORRECT
# cpio -t < /mnt/r/Install/initrdExt.cpio | grep -i ignition
usr/lib/ignition/base.d/10-elemental.ign
usr/lib/ignition/base.d/90-butane.ign

# on the INSTALLED node's ESP -- one initrd, and it does not carry base.d
# cat /mnt/e/loader/entries/active
initrd=/sles/6.12.0-160000.36-default/initrd
# lsinitrd /mnt/e/sles/6.12.0-160000.36-default/initrd | grep -i 'base\.d'
(nothing)

# and so, in the node's journal, at every single stage
no config dir at "/usr/lib/ignition/base.d"
```

Two cheap tells, either of which identifies this in seconds:

- **The installer's GRUB title says `SUSE Linux Enterprise Server 16.0`.** The
  beta line is 16.1. A 16.0 title means the GA OS image booted.
- **Ignition is otherwise healthy.** The same journal shows `fetched user config
  from "proxmoxve"`, `/etc/hostname` written and `canal.yaml` written. Only the
  base.d layer is gone. That combination — per-node config fine, base.d empty —
  is this skew and nothing else.

### Why it takes the whole cluster with it

The first reading is "we lose our butane layer, so there is no `suse` user".
Dumping `10-elemental.ign` out of the CPIO shows it is much worse:
**elemental's own entire Kubernetes bring-up lives in base.d.** That one file
carries

- `/var/lib/elemental/kubernetes/helm/{cert-manager,rancher,gpu-operator,local-path-provisioner,aif-operator}.yaml`
- `/var/lib/elemental/kubernetes/manifests/{local-path-provisioner,local-path-provisioner-auth-priority,traefik}.yaml`
- `/var/lib/elemental/runtime.env`, `k8s_res_deploy.sh`, `k8s_conf_deploy.sh`
- RKE2's `server.yaml`, `init.yaml` (with `tls-san` and the cluster token),
  `agent.yaml`, `registries.yaml`
- and two `enabled: true` units, `k8s-resource-installer.service` and
  `k8s-config-installer.service`, which are what install and configure RKE2 on
  first boot

None of it arrives. That is why there is no RKE2 at all, rather than an RKE2
missing a login.

One trap in the diagnosis: `runtime.env` is written by `10-elemental.ign` *and*
by this module's per-node Ignition. Seeing the correct `NODETYPE=server` /
`IS_INIT_NODE=true` on a node therefore proves nothing about base.d — the
per-node copy is the one that landed.

### Not verified

The elemental3ctl version actually inside `base-os-kernel-default-iso:16.0-3.15`
has not been read off the binary; that would mean pulling a multi-gigabyte
image. The manifest chain above, and the 16.0/16.1 split, are verified. "GA is
3.0.x" comes from the module's earlier notes.

## Flavor availability fails at plan time

`data.evroc_compute_profiles.this.profiles` is queried live from the API, and
the module carries one precondition per requested flavor. A typo or a
withdrawn profile fails during `terraform plan`, with the offending flavor and
the available list in the message, rather than partway through an apply that has
already created a network and a load balancer.

It needs API reachability at plan time. Set `verify_flavor_availability = false`
to skip it.

## Sources

- evroc Terraform provider: [`evroc-oss/evroc`](https://github.com/evroc-oss/terraform-provider-evroc),
  resource and data-source schemas for `virtual_machine`, `snapshot`,
  `hotswap_disk_attachment`, `compute_profiles`, `disk_images`,
  `lb_backend_service`.
- NVIDIA, [Precompiled Driver Containers](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html)
  — precompiled driver containers do not support vGPU.
- SUSE, [GPU operators on RKE2](https://documentation.suse.com/cloudnative/rke2/latest/en/add-ons/gpu_operators.html)
  — GPU Operator values for SUSE's precompiled driver containers.
- SUSE, [`third-party/nvidia/driver` container images](https://registry.suse.com/repositories/third-party-nvidia-driver-sles16).
- Elemental source: `pkg/bootloader/grub.go`, `pkg/firmware/efi_manager.go`,
  `pkg/upgrade`.
