# SUSE AI Factory HA cluster on evroc

Terraform example that provisions a highly-available SUSE AI Factory cluster
on evroc: one build host per availability zone, each building the elemental
image for its own zone; three control-plane VMs -- one per zone, each in that
zone's spread placement group -- booting clones of it behind a single load
balancer (API, supervisor and ingress on one public IP); and any number of GPU
worker pools. Uses `modules/ai-factory-ha`.

This is the runbook for operating that example. For the design, the full
variable reference and evroc-specific behaviour, see:

- [`../../README.md`](../../README.md) -- overview and topology
- [`../../PLATFORM-NOTES.md`](../../PLATFORM-NOTES.md) -- what evroc supports
  and what that costs (UEFI, the two-pass build, GPU driver constraints,
  networking)
- [`../../modules/ai-factory-ha/README.md`](../../modules/ai-factory-ha/README.md) --
  module design and the full variable reference

## 1. Prerequisites

- Terraform >= 1.9, and the evroc provider >= 0.9.4 (pinned in `versions.tf`).
- `evroc login`, so `~/.evroc/config.yaml` exists. The provider block here is
  empty (`provider "evroc" {}`) and reads its context -- credentials, and by
  default region/zone/project -- entirely from that file. The CLI is needed for
  nothing else at deploy time.
- A SUSE Application Collection subscription (`appco_username`/
  `appco_password`).
- A SUSE registration code and registry password (`suse_registration_code`/
  `suse_registry_password`).
- An NVIDIA NGC API key (`nvidia_api_key`), if any GPU pool is configured.
  Optional otherwise.
- At least one admin CIDR (`admin_cidrs`) and one SSH public key
  (`ssh_authorized_keys`).
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`. The module rejects the plan if they match.

## 2. Quickstart

```bash
cd examples/ha-cluster
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars -- every REPLACE_WITH_* placeholder
evroc login

./deploy.sh
```

`terraform init` is not a separate step: `deploy.sh` runs it itself, before
anything else, on every invocation. It is idempotent, so this costs a fresh
checkout one provider download and every later run nothing.

## 3. What each pass does

`deploy.sh` runs two `terraform apply` passes because evroc has no
import-image-from-URL: a build host writes the built image onto a disk that
is already attached to it, and only a detached disk can be snapshotted. See
[`../../PLATFORM-NOTES.md`](../../PLATFORM-NOTES.md#there-is-no-import-image-from-url)
for the full reasoning.

**Provider 0.9.4 or newer is required**, and `versions.tf` enforces it. Older
releases cannot set the load balancer's `backend_network`, so the load balancer
attaches to the *default* VPC, has no route to its own backend pool, and resets
every connection at the VIP while every object reports `Ready=True`. Deployments
from before 0.9.4 worked around it by creating the load balancer with the evroc
CLI and importing it -- that is gone, along with the CLI dependency and the
"pass 0" that carried it.

The build happens **once per zone**, because evroc snapshots are zonal and
cannot be cloned across zones. With the default `zones = ["a", "b", "c"]` that
is three build hosts running three concurrent elemental builds. Only the one in
`zones[0]` -- the jumphost -- has a public IP; the others are private-only.

**Pass 1** stands up the network, the load balancer, the build hosts, and (if
`deploy_nodes = true`) the control-plane and GPU nodes. The image build
dominates its running time and produces **no local output** while it runs --
the apply simply blocks. Watch it from another terminal:

```bash
# one status line per zone, "<state> <build id> <step>" -- what the apply is
# waiting on (only during pass 1, from an admin_cidrs address)
curl "$(terraform output -raw build_status_url)/a"

# the full log on the jumphost, zones[0]
ssh <jumphost_username>@<jumphost ip> tail -f /var/log/elemental-factory.log

# any other zone's builder, tunnelled through the jumphost
terraform output builder_private_ips
ssh -J <jumphost_username>@<jumphost ip> \
    <jumphost_username>@<builder ip> tail -f /var/log/elemental-factory.log
```

(`<jumphost_username>` defaults to `suse`; `<jumphost ip>` is the
`jumphost_public_ipv4` output, known once pass 1 has created the jumphost.)
Expect tens of minutes: a cold `podman pull` of the elemental customize image
plus the raw build itself. The zones build in parallel, so three zones take
about as long as one.

The wait script confirms each zone reported `done`, and nothing more. A zone
that reports `failed` ends pass 1 at once, naming the zone and the step. It does not
check that the zones built the same software, because an elemental raw image is
not reproducible -- fresh filesystem UUIDs, GPT GUIDs and mtimes every run -- so
the images differ even when the inputs are identical. If a zone-to-zone drift
would matter to you, pin `elemental_image`, `core_platform_override` and
`sysext_image_overrides` to digests instead of tags.

**Pass 2** detaches the now-written disks (destroying the attachments), destroys
the non-primary build hosts, takes a snapshot of each disk, and flips
`image_ready` so every node's boot disk clones from its own zone's snapshot.
This is a normal, comparatively fast apply -- no image build happens in it.

The builders are destroyed here because a default evroc project allows 20 vCPU
and will not hold three build hosts plus three control-plane nodes; the
snapshots depend on that teardown, so it is ordered ahead of the nodes rather
than racing them. The jumphost survives -- it stays the bastion. One
consequence worth knowing before you start pass 2: from this point the build
logs are gone, so a failure here is recovered with `--rebuild`, not a retry.

After pass 2 there is a short **pass 3**, which deletes the image-target disks
and reclaims `image_target_disk_gb` a zone -- 96 GB on a three-zone cluster. It
runs by default; `--keep-build-disks` skips it.
A snapshot does outlive its source disk -- it stays Ready and still creates
disks -- but nothing has yet booted a disk cloned from a snapshot whose source
was already deleted, and after pass 3 the cluster's whole image lives in those
snapshots. Keep the disks if you want that hedge, or as forensics media.

`--keep-build-disks` is **sticky**: `deploy.sh` re-asserts it on every later run
by reading `pass2.auto.tfvars.json` back, because that file is rewritten from
scratch each time and a dropped key would silently delete the disks you chose to
keep. `--reclaim-build-disks` revokes it.

`deploy.sh --rebuild` forces a fresh build on a cluster that already has a
snapshot in state (an edit under `modules/ai-factory-ha/templates/`, for
example); it recreates the image-target disks, since a build needs somewhere to
write. `--yes` passes `-auto-approve` to both passes. `--help` lists all
flags; anything else is forwarded verbatim to both `terraform apply` calls,
except an unrecognised `--flag`, which is a hard error.

## 4. Post-deploy checks

```bash
# Fetch the kubeconfig off any control-plane node. With control_plane_public_ip
# = false the nodes have no public address, so hop through the jumphost --
# terraform output control_plane_private_ips for the target.
ssh <node_username>@<control-plane-ip>
su -                                              # root_password_hash
cat /etc/rancher/rke2/rke2.yaml                   # copy out, rewrite the server: address
                                                   # to the api_vip output

kubectl get nodes -o wide                         # control-plane + GPU workers, right hostnames

# Zone spread: confirm the control plane really is one member per zone before
# trusting the cluster to survive losing one. A cluster that silently landed
# all three in zone a looks identical to a correct one until a zone goes down.
terraform output node_zones
terraform output subnet_cidrs
terraform output snapshot_ids    # one per zone; each node clones its own zone's

curl -k https://$(terraform output -raw api_vip):6443/readyz

# Rancher.
terraform output -raw rancher_url
terraform output -raw rancher_bootstrap_password  # sensitive; -raw prints it plainly

# GPU pools, if configured.
kubectl get pods -n gpu-operator
kubectl run nvidia-smi-check --rm -it --restart=Never \
  --image=registry.suse.com/third-party/nvidia/cuda:sles15-latest \
  --overrides '{"spec":{"nodeSelector":{"nvidia.com/gpu.present":"true"}}}' \
  -- nvidia-smi

# MTU: silent when wrong -- a mismatch here does not error, it fragments
# large packets and hangs TLS handshakes intermittently. On any node:
cat /etc/cni/net.d/10-canal.conflist   # look for the expected veth MTU (vpc_mtu - 50)
```

`kubectl get nodes` failing to reach the API but `curl .../readyz` working (or
vice versa) points at the load balancer's backend pool rather than RKE2
itself -- see Troubleshooting.

## 5. Day-2 operations

**Adding, renaming, or resizing a GPU pool is a plain Terraform add/replace,
not an image rebuild.** Node role and hostname come from per-node Ignition
(`runtime.env`, written from `gpu_pools`'s own keys), not from anything baked
into the image at build time -- `kubernetes/cluster.yaml` carries no static
node list. Edit `gpu_pools` in `terraform.tfvars` and re-run `./deploy.sh` (or
a plain `terraform apply`, since no image-build sequencing is involved in a
node-only change).

**Anything that changes the image forces a full rebuild in every zone and
replaces every node.** Run `./deploy.sh --rebuild` afterward. Variables that do this:
`elemental_image`, `root_password_hash`, `ssh_authorized_keys`,
`node_username`, `node_user_password_hash`, `permit_root_ssh`, `components`,
`aif_version` / `aif_release_manifest_url`, `core_platform_override`,
`sysext_image_overrides`, `gpu_driver_repository` / `gpu_driver_version`,
`image_disk_size`, `fips`. Everything else --
sizing (`control_plane_flavor`, `jumphost_flavor`, `node_disk_gb`,
`gpu_pools`), networking (`vpc_cidr`, `subnet_newbits`, `vpc_mtu`), placement
(`zones`, `gpu_pools[*].zone`, `gpu_pools[*].placement_strategy`), and access
control (`admin_cidrs`, `ingress_cidrs`) -- takes effect without touching the
image, though some of those (e.g. `control_plane_flavor`) still replace the
affected nodes themselves.

**Do not REORDER `zones` on a standing cluster.** Subnet CIDRs are assigned by
position in that list -- `zones[i]` gets `cidrsubnet(vpc_cidr, subnet_newbits,
i)` -- so swapping two entries renumbers both subnets, which replaces them and
every node in them. Appending a zone is safe: it adds a subnet and a placement
group, and existing nodes keep their addresses. Removing one destroys that
zone's subnet along with whatever is in it.

## 6. Teardown

```bash
terraform destroy
```

The snapshots are Terraform-owned (`evroc_snapshot`, not something a build host
creates out of band), so destroy removes all of them along with everything else
-- nothing is left behind to bill for afterward. Check:

```bash
terraform state list   # should be empty
cat pass2.auto.tfvars.json   # safe to delete once state is empty; image_ready
                              # in it is meaningless with no cluster to apply
                              # it to
```

## 7. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| VM shows `Running` but never answers on any port | Missing UEFI label, or the image did not boot | `evroc_virtual_machine` should carry `user_labels["compute-experimental-features-UEFI"] = "true"`; see [`../../PLATFORM-NOTES.md`](../../PLATFORM-NOTES.md#uefi-is-an-experimental-label-gated-feature) |
| `terraform plan` proposes replacing every control-plane/GPU node | `image_ready` reverted to `false`, so the snapshots the node disks clone from are planned for destruction | Check `pass2.auto.tfvars.json` still contains `"image_ready": true`. If it was deleted or edited, re-run `./deploy.sh`, which re-asserts it. **Do not set `snapshot_ids` to this module's own snapshots** to "pin" them -- that variable means "adopt externally-owned snapshots", and setting it destroys the module's own |
| Pass 2 plan shows `terraform_data.image_written must be replaced` | An image-affecting variable was edited between the two passes, so the image on the disk was built from configuration that no longer exists | **Do not approve.** Pass 2 would snapshot the stale image under a build id that never touched the disk. Re-run `./deploy.sh`, which rebuilds the image against the current config before snapshotting it |
| `snapshot "...-snapshot-a" is in zone "a" but disk is in zone "c"` from `disk-webhook.evroc.com` | A node is cloning the wrong zone's snapshot -- with the module as written this should not happen, so it means `snapshot_ids` was set by hand with entries that do not match `zones` | `terraform output snapshot_ids` and confirm one entry per zone. If `snapshot_ids` is set in `terraform.tfvars`, every id must be a snapshot in the zone it is keyed under |
| Cannot reach a builder to read its build log | Builders have no public IP by design | `ssh -J <jumphost_username>@<jumphost ip> <jumphost_username>@<builder ip>`, with the address from `terraform output builder_private_ips` |
| Pass 2 fails: snapshot cannot be created, disk still attached | The detach and the snapshot happen in the same apply and evroc has not finished the detach | Re-run `./deploy.sh`. The detach already succeeded, so the second run creates the snapshot cleanly. Nothing is half-built and the disk still holds the image either way -- see the ordering note in `modules/ai-factory-ha/snapshot.tf` |
| Pass 1 runs far longer than expected, or never finishes | Image build stuck on a step | `curl "$(terraform output -raw build_status_url)/<zone>"` shows the step; `ssh <jumphost_username>@<jumphost ip> tail -f /var/log/elemental-factory.log` shows why. Also check `image_build_timeout` |
| Wait script keeps printing `relay unreachable` | The address `terraform apply` runs from is not in `admin_cidrs`, which is all the relay port is open to. A connection with more than one egress IP may get through only some of the time | `curl -m 5 "$(terraform output -raw build_status_url)/a"` from the same machine. Add every egress address to `admin_cidrs` and re-run `./deploy.sh`; the build itself is unaffected |
| `not enough quota ... no public IPs are available (out of 3)` partway through an apply | `control_plane_public_ip` / `gpu_public_ip` turned on against a default evroc project, which allows 3 public IPs -- two already spent on the API VIP and the jumphost (adding zones does not add to that: only `zones[0]`'s build host gets one) | Set both back to `false` and re-apply; the partially-created IPs are in state and get cleaned up. Nothing is lost by it -- egress works without them, nodes stay reachable via the jumphost, and the control plane answers on the load balancer |
| `not enough quota ... Requested additional N vCPUs` from `virtualmachine-webhook.evroc.com` | A default evroc project allows 20 vCPU. Either `jumphost_flavor` was sized up (it multiplies by the zone count -- three `a1a.l` build hosts are 24 vCPU on their own), or `control_plane_flavor`/`gpu_pools` ask for more than fits alongside the jumphost | The stock defaults budget 12 vCPU in pass 1 and 16 in pass 2; see the quota table in `../../PLATFORM-NOTES.md`. Either restore them, drop to `zones = ["a"]`, or ask evroc to raise the quota -- a GPU pool needs that regardless |
| `Ready: disk is missing DiskImageRef (ProvisioningFailed)` on a GPU VM | The project still enforces the pre-2026-09-23 rule that a GPU flavor's boot disk must come from an evroc-**provided** image, which requires `spec.source.diskImageRef` -- a snapshot clone has no such field, and every disk this module builds is a snapshot clone. Lifted on 2026-09-23; a project seeing it has not picked the change up | Ask evroc. There is no workaround in the module -- until it is lifted, set `gpu_pools = {}` and re-apply (the failed VM's boot disk is in state and gets destroyed). See `../../PLATFORM-NOTES.md` |
| `cannot deploy a GPU VM in zone "b". GPU VMs are currently only supported on zone "a"` | evroc runs GPU VMs in **zone a only**, enforced by an admission webhook. A pool left unpinned used to round-robin across every zone, so two thirds of it landed somewhere illegal | Nothing to do on a current checkout: unpinned pools are now placed only in `gpu_zones` (default `["a"]`). If you pinned a pool with `zone = "b"`, the plan now fails and tells you. If evroc widens the rule, widen `gpu_zones` |
| `not enough quota ... Requested additional 2 "nvidia.com/AD102GL_L40S" GPUs. Only 1 ... (out of 1 in quota)` | GPU quota is counted **per GPU model**, separately from vCPU, and a default project holds one of each | Drop the pool's `count` to what the quota allows, or ask evroc to raise it. No plan-time check exists -- the provider's quota data sources only report object storage. The failed node's boot disk was already created and stays in state; lowering `count` destroys it on the next apply |
| Cannot SSH to a node that has no public IP, even from the jumphost | Expected only if the `ssh-jumphost` rule is missing from the node's security group | Nodes accept 22 from `admin_cidrs` *and* from the jumphost's private /32. Hop through the jumphost: `ssh <jumphost>` then `ssh <node_username>@<private ip>` from the `control_plane_private_ips` / `gpu_node_private_ips` outputs |
| Some nodes of a GPU pool create fine and others fail out of capacity | The pool is spread round-robin across `zones` but the flavor's stock only exists in one of them -- the usual case for GPU profiles | Pin the pool: `gpu_pools = { training = { flavor = ..., zone = "a" } }`. `terraform output node_zones` shows where each node was placed |
| `terraform plan` proposes replacing every subnet and every node after an edit to `zones` | The list was reordered, not appended to | Subnet CIDRs are assigned by position in `zones`. **Do not approve** unless the replacement is intended -- restore the original order, then append |
| `terraform plan` fails with "flavor ... is not currently offering" | Typo'd or withdrawn compute profile | The error names the offending flavor and evroc's current list; fix `control_plane_flavor`/`jumphost_flavor`/`gpu_pools[*].flavor`, or set `verify_flavor_availability = false` to skip the check |
| `kubectl` times out against `api_vip:6443` right after pass 2 | Load balancer backend pool not yet healthy | `evroc_lb_backend_pool` populates from the control-plane nodes as they come up; give RKE2 a minute to start listening |
| Large-packet transfers hang or TLS handshakes stall intermittently | MTU mismatch between `vpc_mtu` and the actual VPC overlay | `cat /etc/cni/net.d/10-canal.conflist` on a node -- wrong value is silent otherwise |

## 8. Security

The state file holds **every secret in plaintext**: `root_password_hash`,
`node_user_password_hash`, the AppCo and SUSE registry credentials, the
NVIDIA NGC key, and the generated RKE2 join token and Rancher bootstrap
password. Treat `terraform.tfstate` as a credential -- back it up like one,
and never commit it.

The same values are baked into the elemental image, so **the snapshots are
credentials too**: each embeds the RKE2 join token and the root password hash,
so anyone who can clone one has both, independent of anything in Terraform
state. There is one per zone, plus the image-target disk each was taken from,
which is kept by default -- so the secrets live in two places per zone, not
one, for the life of the cluster.
Restrict who can read snapshots and disks in the project the same way you would
restrict `terraform.tfstate` access.

Every build host holds the same secrets on disk, in the elemental config
cloud-init unpacked for it. The non-primary ones have no public IP and accept
SSH only from the jumphost, but they are not more disposable than the jumphost
from a credential standpoint.
