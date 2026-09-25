# SUSE AI Factory on evroc

Terraform for deploying SUSE AI Factory on [evroc](https://www.evroc.com/) from
an [elemental3](https://github.com/suse/elemental) image, with RKE2, Rancher and
the AI Factory stack baked into the image at build time.

| | |
|---|---|
| Module | [`modules/ai-factory-ha`](modules/ai-factory-ha/) |
| Example | [`examples/ha-cluster`](examples/ha-cluster/) |

A build host in each availability zone builds the elemental image and writes it
onto an attached disk, which becomes that zone's snapshot; three control-plane
VMs, one per zone and each in that zone's spread placement group, boot clones of
it behind one load balancer serving both the Kubernetes API and public ingress;
and any number of GPU worker pools join as agents, pinned or spread across zones
per pool. GPU pools are opt-in and default to `{}`; they run in `gpu_zones`
(zone `a` today) and are quota'd per GPU model, so read
[PLATFORM-NOTES.md](PLATFORM-NOTES.md) before sizing one. The module builds its own image, and is applied through `deploy.sh`
rather than a bare `terraform apply` -- see [below](#why-deploysh-and-not-bare-terraform-apply).

Start with [`examples/ha-cluster/README.md`](examples/ha-cluster/README.md) to
run it, and [`modules/ai-factory-ha/README.md`](modules/ai-factory-ha/README.md)
for the design and the full variable reference.

[PLATFORM-NOTES.md](PLATFORM-NOTES.md) covers what evroc supports and what that
costs an immutable EFI-only image — the experimental UEFI label, why the image
build takes two passes, the GPU placement and quota rules, and the handful of platform behaviours this module
currently assumes rather than knows.

## Experimental NVIDIA driver for SLES 16.1 (as of 2026-09-24)

The GPU operator uses an **experimental** precompiled driver: branch `615`
from an OBS build,
`registry.opensuse.org/home/eminguez/branches/home/avicenzi/nvidia-for-bci-161/containerfile/third-party/nvidia`.
It is not a supported SUSE image. It does work: on a `gn-l40s` node the driver
pod loads, the CUDA validator passes and `nvidia-smi` reports the L40S.

The nodes run SLES 16.1 (kernel `6.12.0-160100.x`), which the module needs:
`core_platform_override` pins the 16.1 OS image because the 16.0 one does not
bring up Kubernetes (see the variable's description). The precompiled driver
images the release manifest points at,
[`registry.suse.com/third-party/nvidia/driver`](https://registry.suse.com/repositories/third-party-nvidia-driver-sles16),
are published for SLES 16.0 only. A 16.0 module does not load on a 16.1 node
(`nvidia: disagrees about version of symbol module_layout`), because the
kernel's module ABI changed between the two.

The operator pulls `<repository>/driver:<version>-<uname -r>-sles16.1`, so the
OBS repository needs a tag for the node's exact kernel. Once
`registry.suse.com/third-party/nvidia` publishes 16.1 drivers, set
`gpu_driver_repository` and `gpu_driver_version` back to it.

## Usage

```bash
cd examples/ha-cluster
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars -- every REPLACE_WITH_* placeholder
evroc login                     # writes ~/.evroc/config.yaml

./deploy.sh
```

`deploy.sh` runs every pass. Pass 1 blocks for the length of the image build
with no output; watch it with
`ssh suse@<jumphost-ip> tail -f /var/log/elemental-factory.log`. The example
README covers timing, the post-deploy checks, and what `terraform destroy`
leaves behind.

The provider reads `~/.evroc/config.yaml`, so `provider "evroc" {}` needs no
arguments. `region` and `project` are module variables that default to whatever
that context says; `zones` defaults to `["a", "b", "c"]` -- the cluster spans
all three, with one subnet, one control-plane placement group and one image
build in each. `zones = ["a"]` is the cheaper single-AZ shape.

## Why deploy.sh and not bare `terraform apply`

evroc has no import-image-from-URL. The only way to get an image into the
platform is to write it onto a disk that is already there:

1. **Pass 1** attaches a blank disk to a build host, builds the raw elemental
   image on it, and `dd`s the image onto the disk.
2. **Pass 2** (`image_ready = true`) destroys the attachment — which is the
   detach — tears down the non-primary build hosts, takes an `evroc_snapshot` of
   each freed disk, and clones every node's boot disk from its own zone's
   snapshot. The build hosts go first because a default project's 20 vCPU does
   not hold them and the nodes at once.

A third, short apply deletes the image-target disks. It is **on by default** in
`deploy.sh`; `--keep-build-disks` opts out. A snapshot outlives its source disk,
but no node has yet been booted from a clone taken after that disk was deleted.
See PLATFORM-NOTES.md.

Terraform owns the detach and the snapshot, so no build host ever holds evroc
credentials. `deploy.sh` drives the passes and pins `image_ready` in
`pass2.auto.tfvars.json`, which Terraform auto-loads — so a later bare
`terraform apply` cannot silently revert it and tear the cluster's backends out
of the load balancer.

**This happens once per zone.** evroc snapshots are zonal: a disk cannot be
cloned from a snapshot belonging to another zone, and the provider has no
snapshot-copy operation, so a three-zone cluster runs three concurrent builds
and produces three snapshots. Only `zones[0]`'s build host gets a public IP —
the others need no inbound path and are tunnelled through it. Nothing checks
that the zones built the same software — an elemental raw image is not
reproducible, so the images cannot be compared; pin OCI digests rather than tags
if that matters. See [PLATFORM-NOTES.md](PLATFORM-NOTES.md).

## Fast-fail on flavor availability

`data.evroc_compute_profiles` is queried live from the API, and the module
carries one precondition per requested flavor. A typo or a withdrawn profile
fails during `terraform plan`:

```
Error: Resource precondition failed

  Flavor "gn-l40s.xl" requested for GPU pool "inference" is not available.
  Available profiles: a1a.xs, a1a.s, ..., gn-l40s.s, gn-l40s.m, gn-l40s.l
```

rather than partway through an apply that has already built a network, a load
balancer and a jumphost. The same gate fails the plan when the cluster's own
peak vCPU, memory or public-IP demand exceeds the organization quota
(`evroc_organization_quota`) -- three `a1a.l` build hosts against 20 vCPU, or
`control_plane_public_ip = true` against 3 IPs -- and the `quota_request`
output prints demand, limit and current usage. It needs API reachability at
plan time; set `verify_flavor_availability = false` to skip it.

## Security

Every node on evroc is an ordinary VM, so **every node is behind an
`evroc_security_group`** — there is no bare-metal tier the platform's packet
filter cannot reach, and the module does not rely on host-level firewalling
inside the image for its network policy.

| Group | Inbound |
|---|---|
| jumphost | 22 from `admin_cidrs` |
| builder (multi-zone only) | 22 from the jumphost's private /32 — nothing else; these have no public IP |
| control plane | 22 from `admin_cidrs` and from the jumphost's private /32; 6443 and 9345 from `0.0.0.0/0`; etcd 2379–2381, kubelet 10250, VXLAN udp/8472 and NodePorts 30000–32767 from within the VPC; 80, 443 and 8080 from `ingress_cidrs` when an ingress controller is enabled |
| GPU | 22 from `admin_cidrs` and from the jumphost's private /32; kubelet 10250, VXLAN udp/8472 and NodePorts 30000–32767 from within the VPC |

Egress is unrestricted. It has to be: the image is not self-contained, and
Rancher, the AppCo charts and the GPU operator's driver containers are all
pulled at runtime.

6443 and 9345 are open to the internet because they terminate on the load
balancer's public VIP, which is how the cluster is reached at all. Both are
TLS-authenticated — 9345 requires the RKE2 join token — but narrowing them to
known operator networks is a reasonable hardening step and costs nothing but a
variable.

Two things to know about the state file. Terraform writes **every sensitive
input in plaintext**: `root_password_hash`, the AppCo and SUSE registry
credentials, the NVIDIA NGC key, and the generated RKE2 join token and Rancher
bootstrap password. Treat `terraform.tfstate` as a credential. And the same
values are baked into the elemental image, so the snapshot is a credential too —
anyone who can clone it can read the join token out of it.

## License

Apache-2.0. See [LICENSE](LICENSE).
