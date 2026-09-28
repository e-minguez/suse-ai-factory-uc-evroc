#!/usr/bin/env bash
#
# Two-pass apply for the HA cluster example.
#
# WHY TWO PASSES:
# evroc has no import-image-from-URL (see ../../PLATFORM-NOTES.md). The
# jumphost writes the built elemental image onto a blank disk that is
# already attached to it; only once that disk is DETACHED can a consistent
# snapshot be taken from it, and only once the snapshot exists can any
# node's boot disk be cloned from it. Terraform can't attach and detach the
# same disk within one apply, so this is sequenced across two:
#
#   Pass 1 (image_ready = false, the module's default): the blank disk stays
#   attached to the jumphost, which dd's the built image onto it.
#   Pass 2 (image_ready = true): the attachment is destroyed -- which is the
#   detach -- a snapshot is taken from the now-free disk, and every node's
#   boot disk is cloned from that snapshot.
#
# WHY AN AUTO-LOADED TFVARS FILE RATHER THAN A -var FLAG:
# Terraform auto-loads any *.auto.tfvars.json in the working directory on
# every subsequent plan/apply, whereas a -var flag only lives for the one
# command it's passed to. Without this file, a plain `terraform apply` run
# any time after this script finishes would see image_ready revert to its
# false default -- which detaches image_target from nowhere (it is already
# detached) but ALSO drops every node's boot disk back to depending on a
# snapshot that no longer resolves the way it did, forcing them to be
# replaced and tearing the cluster's own backends out of the load balancer's
# backend pool. Pinning image_ready = true in an auto-loaded file is what
# makes a later bare `terraform apply` safe.
#
# WHY THIS SCRIPT NEVER WRITES snapshot_ids:
# It is tempting to pin `terraform output -json snapshot_ids` back into the
# file so the values are plan-known on later runs. Do not. var.snapshot_ids is
# an override meaning "do not build an image, adopt these EXTERNALLY-owned
# snapshots instead", and evroc_snapshot.ai_factory is gated on it being
# EMPTY. Feeding the module its own output therefore destroys the snapshot
# resources while every node's boot disk still refers to those FQIDs -- the
# ids stay literally correct in the config and point at nothing on the
# platform. The pin is not needed anyway: once the snapshots have been created
# their FQIDs are recorded in state, so they are already plan-known on every
# subsequent run with no help from this script. Pass snapshot_ids in
# terraform.tfvars by hand, and only for snapshots this module did not build.
#
# WHY A STANDING CLUSTER GETS ONE APPLY AND NOT TWO:
# Once the handoff has happened, image_ready must STAY true. Resetting it to
# false to "re-run pass 1" would drop evroc_snapshot.ai_factory to count = 0
# and take the whole cluster down with it, on a run the operator expected to
# be a no-op. So when state already holds a snapshot, this script re-asserts
# image_ready = true and applies exactly once. Only --rebuild deliberately
# goes back through both passes, and it says so before it does.
#
# WHAT TO EXPECT:
# Before the first apply, a preflight plans the run and stops if an evroc
# object it would create already exists outside state (typically left by an
# interrupted or crashed apply; it writes import blocks for those), or if the
# cluster's peak does not fit in the organization's FREE quota. See
# check_orphans and check_quota. It costs one extra plan per run.
#
# Pass 1 blocks for tens of minutes with NO console output while the
# jumphost builds the elemental image. This is normal -- watch progress from
# another terminal with the command this script prints once pass 1 starts.
#
# USAGE:
#   ./deploy.sh [--rebuild] [--reclaim-build-disks|--keep-build-disks] [--yes]
#               [--skip-quota-check]
#               [-- | terraform apply args...]
#
# Double-dash flags are this script's own and are consumed here; everything
# else is forwarded verbatim to both `terraform apply` calls. An unrecognised
# --flag is a hard error rather than being forwarded, so a typo surfaces here
# instead of as a confusing Terraform error. Use `--` to stop flag parsing.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [--rebuild] [--reclaim-build-disks|--keep-build-disks] [--yes]
                   [--skip-quota-check]
                   [terraform apply args...]

  --rebuild   Go back through both passes against a cluster that is already
              standing, building a fresh image. DESTRUCTIVE: pass 1 sets
              image_ready = false, which destroys the current snapshot, and
              every node's boot disk is a clone of it -- so the nodes are
              replaced and the cluster is rebuilt from scratch. Only meaningful
              on a standing cluster; from an empty state every run builds fresh
              anyway.
  --reclaim-build-disks
              Delete the image-target disks once their snapshots exist,
              recovering image_target_disk_gb per zone (96 GB on a default
              three-zone cluster) of billed storage.

              ON BY DEFAULT. A snapshot survives its source disk being deleted
              -- it stays Ready, keeps reporting a restore_size and still
              creates disks (verified 2026-09-22, PLATFORM-NOTES.md). What
              nobody has tested is BOOTING one of those disks: the first thing
              to exercise it is a scale-out or node replacement after the
              reclaim. Build one node from the snapshot afterwards and confirm
              it boots if that matters. The flag itself only exists to revoke
              a sticky --keep-build-disks.
  --keep-build-disks
              Keep the image-target disks as a hedge (and as forensics media --
              they hold the exact bytes the snapshots were taken from).

              STICKY. Once asked for, it is re-asserted on every later run from
              pass2.auto.tfvars.json, so a plain ./deploy.sh does not quietly
              delete them. --reclaim-build-disks revokes it.
  --yes       Pass -auto-approve to both terraform apply passes.
  --skip-quota-check
              Do not stop when the preflight finds the cluster does not fit in
              the organization's free quota (e.g. usage still counting VMs
              deleted a minute ago).
  --help      Show this message.
  --          Stop parsing this script's flags; forward the rest verbatim.

Any other argument is forwarded to both `terraform apply` invocations.


USAGE
}

REBUILD=false
# ON by default, unlike the module variable (which stays true so a hand-driven
# two-pass apply cannot race a snapshot against its source). This script does
# the sequencing that makes it safe: the reclaim is a pass of its own, after the
# snapshots exist. See reclaim_build_disks.
RECLAIM=true
# Explicit requests, as opposed to the default. EXPLICIT_RECLAIM revokes a
# KEEP_BUILD_DISKS recovered from pass2.auto.tfvars.json below.
EXPLICIT_RECLAIM=false
KEEP_BUILD_DISKS=false
SKIP_QUOTA_CHECK=false
TF_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild) REBUILD=true; shift ;;
    --reclaim-build-disks) EXPLICIT_RECLAIM=true; shift ;;
    --keep-build-disks) KEEP_BUILD_DISKS=true; shift ;;
    --yes) TF_ARGS+=(-auto-approve); shift ;;
    --skip-quota-check) SKIP_QUOTA_CHECK=true; shift ;;
    --help | -h)
      usage
      exit 0
      ;;
    --)
      shift
      TF_ARGS+=("$@")
      break
      ;;
    --*)
      echo "ERROR: unknown option '$1'." >&2
      echo >&2
      usage >&2
      exit 2
      ;;
    *) TF_ARGS+=("$1"); shift ;;
  esac
done

if [[ "$EXPLICIT_RECLAIM" == true && "$KEEP_BUILD_DISKS" == true ]]; then
  echo "ERROR: --reclaim-build-disks and --keep-build-disks contradict each other." >&2
  echo "       Pass exactly one: the first deletes the image-target disks (the default," >&2
  echo "       and revokes an earlier --keep-build-disks), the second keeps them." >&2
  exit 2
fi

if [[ ! -f "${HOME}/.evroc/config.yaml" ]]; then
  echo "ERROR: ${HOME}/.evroc/config.yaml not found." >&2
  echo "The evroc provider (an empty provider \"evroc\" {} block) reads its context from" >&2
  echo "that file. Run: evroc login" >&2
  exit 1
fi

# Unconditional, because it has to be: the FIRST terraform command below is a
# `terraform output`, whose failure is deliberately swallowed, and the next is
# an apply that would stop with "Module not installed" in a fresh checkout.
# Leaving init to the operator made the documented quickstart fail on its first
# run. It is idempotent and near-instant once .terraform/ exists, and
# -input=false keeps it from blocking on a prompt inside a script.
#
# No -upgrade: the lock file is what pins the provider set, and re-resolving it
# silently is exactly what versions.tf's `~> 0.9.4` comment argues against.
echo "==> terraform init"
terraform init -input=false

# Scratch space for this run -- the apply logs and the preflight's saved plan
# -- in .deploy-tmp/ next to the state, not in $TMPDIR. The saved plan holds
# every input in plaintext, exactly as terraform.tfstate beside it does, so
# the directory that already has to be protected is the one place that adds
# no new exposure; and whatever a hard kill leaves behind sits in plain sight
# instead of under /var/folders.
#
# Removed on ANY exit. bash runs EXIT traps on SIGINT by itself; TERM and HUP
# are turned into exits so it runs for those too. INT is deliberately not
# trapped: Terraform handles Ctrl-C itself (graceful stop, state written), and
# the script must keep running after it to report a crash. Only a SIGKILL
# leaves the directory behind, and the next run's exit removes it.
SCRATCH="$PWD/.deploy-tmp"
mkdir -p "$SCRATCH"
chmod 700 "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT
trap 'exit 143' TERM
trap 'exit 129' HUP

# A --keep-build-disks asked for on some EARLIER run STAYS asked for, unless
# --reclaim-build-disks revokes it.
#
# pin_image_ready rewrites pass2.auto.tfvars.json from scratch every run, so
# without this a keep asked for once and then a plain ./deploy.sh would fall
# back to the reclaim default and delete the disks the operator chose to keep.
# The keep is recorded as an explicit `"retain_image_target_disks": true` --
# never written otherwise -- so its presence is unambiguous.
#
# A reclaim needs no recovery: it is the default, so every run re-asserts it
# anyway, and always through reclaim_build_disks below, i.e. a pass of its OWN
# after pass 2. That is what keeps a --rebuild's pass 2 from creating each
# snapshot and deleting its source disk in one apply.
if [[ "$KEEP_BUILD_DISKS" == true ]]; then
  RECLAIM=false
elif [[ "$EXPLICIT_RECLAIM" == false && -f pass2.auto.tfvars.json ]] && python3 -c '
import json, sys
try:
    pinned = json.load(open("pass2.auto.tfvars.json")).get("retain_image_target_disks")
except Exception:
    sys.exit(1)
sys.exit(0 if pinned is True else 1)
' 2>/dev/null; then
  RECLAIM=false
  KEEP_BUILD_DISKS=true
fi

# Whether the file pin_image_ready writes should also reclaim the image_target
# disks. Never set before the snapshots exist -- see reclaim_build_disks below.
PIN_RECLAIM=false

pin_image_ready() {
  if [[ "$PIN_RECLAIM" == true ]]; then
    printf '{\n  "image_ready": true,\n  "retain_image_target_disks": false\n}\n' \
      > pass2.auto.tfvars.json
  elif [[ "$KEEP_BUILD_DISKS" == true ]]; then
    # Explicit rather than omitted, so the sticky recovery above can tell a
    # deliberate keep from a pass 2 whose pass 3 has not run yet.
    printf '{\n  "image_ready": true,\n  "retain_image_target_disks": true\n}\n' \
      > pass2.auto.tfvars.json
  else
    printf '{\n  "image_ready": true\n}\n' > pass2.auto.tfvars.json
  fi
}

# Delete the image_target disks, recovering image_target_disk_gb per zone --
# 96 GB on a default three-zone cluster, billed until something deletes it.
# ON by default; --keep-build-disks opts out.
#
# THE KNOWN GAP. Deleting a source disk leaves its snapshot Ready and still
# able to create disks -- that much was verified on 2026-09-22. What was not
# verified is BOOTING one of those disks; the probe was created and never
# started. After a reclaim the snapshots are the only copy of the cluster's
# image, and the first thing that would exercise the gap is a scale-out or a
# node replacement, possibly weeks later. Pass 2's nodes do not test it: they
# are cloned before this pass runs.
#
# A THIRD APPLY, DELIBERATELY, when it is asked for. The disks are the source
# the snapshots are taken FROM. Ask one apply to create a snapshot and destroy
# its source and the outcome depends on an ordering the dependency graph does
# not pin down; lose that race and the image exists nowhere at all. Running it
# afterwards, against snapshots already in state, at least has no race to lose.
#
# Written into pass2.auto.tfvars.json rather than terraform.tfvars on purpose.
# That file is reset before every pass 1, so the setting cannot survive into a
# later --rebuild and turn its pass 2 back into the racy version.
reclaim_build_disks() {
  [[ "$RECLAIM" == true ]] || return 0

  echo "==> Pass 3: reclaiming the image-target disks (their snapshots hold the same image)"
  PIN_RECLAIM=true
  pin_image_ready
  apply_with_retry "Pass 3"
}

# `terraform apply`, retried when -- and only when -- it fails with an evroc
# 409 Conflict.
#
# The load-balancer objects are Kubernetes objects underneath
# (l4routes.loadbalancer.evroc.com, backendservices.loadbalancer.evroc.com):
# they carry a resourceVersion and a controller reconciles them. Change more
# than one of them in a single apply and Terraform writes them in PARALLEL,
# the controller reconciles the siblings mid-write, and every write built
# against the now-stale resourceVersion is rejected:
#
#   Error: error updating L4 route suse-ai-factory-supervisor-route:
#   API error (409): Conflict - Operation cannot be fulfilled on
#   l4routes.loadbalancer.evroc.com "...": the object has been modified;
#   please apply your changes to the latest version and try again
#
# Typically one of the four succeeds and the rest fail, which reads like a
# flaky API and is not: 409 means "re-read and try again", and the provider
# does not. So this does. Each retry re-plans from current state, so it picks
# up wherever the failed apply stopped rather than repeating it.
#
# NOT a blanket retry loop. The grep is what keeps this honest -- any other
# failure (a webhook rejection, a quota refusal, a bad credential) surfaces
# immediately and unretried, instead of being run three more times and buried
# under its own repetitions.
#
# -parallelism=1 would also avoid the collision and is the wrong tool: it is
# global, so it would serialise the whole apply including the image build.
# Forward it yourself for a load-balancer-only run if you want it.
#
# See ../../PLATFORM-NOTES.md, "...but a REAL change to several LB objects at
# once conflicts too".
apply_with_retry() {
  local label="$1"
  local attempt=1
  local max_attempts=3
  local log rc

  log=$(mktemp "$SCRATCH/apply.XXXXXX")  # -t is not portable
  # shellcheck disable=SC2064 # expand $log now, not at trap time
  trap "rm -f '$log'" RETURN

  while :; do
    rc=0
    # tee, so the operator still sees the apply stream live -- and stdin is
    # left alone, so an interactive (no --yes) approval prompt still works.
    # tee -i: Ctrl-C reaches the whole pipeline, and a tee that dies with it
    # takes the errors Terraform prints while stopping -- including those of
    # creates that failed earlier in the run -- down with it.
    terraform apply ${TF_ARGS[@]+"${TF_ARGS[@]}"} 2>&1 | tee -i "$log" || rc=$?

    if [[ $rc -eq 0 ]]; then
      return 0
    fi

    # A Terraform panic can drop the state of everything created during the
    # apply, not just the resource it panicked on. Seen on 1.16.4 after one
    # Ctrl-C (hashicorp/terraform#39283, fixed in 1.16.5): an interrupted create
    # tripped "has status ObjectStatus(0), which cannot be saved in state", and
    # the objects that HAD completed never reached terraform.tfstate. A later
    # `terraform destroy` then reports nothing to destroy while the objects are
    # still in the project, billed. The next ./deploy.sh finds them, which is
    # what check_orphans is for, but say so now: this is the moment someone
    # reaches for `terraform destroy` or deletes the state.
    if grep -q 'TERRAFORM CRASH' "$log"; then
      echo >&2
      echo "ERROR: ${label}: Terraform itself crashed (exit $rc)." >&2
      echo "       Objects it created during this apply may be missing from terraform.tfstate" >&2
      echo "       while still existing in the evroc project. Do NOT delete the state or rely" >&2
      echo "       on 'terraform destroy' now; it can only see what is in state." >&2
      echo "       Re-run ./deploy.sh: its orphan check lists what exists but is not in state" >&2
      echo "       and writes import blocks for it. If the stack trace mentions" >&2
      echo "       'ObjectStatus(0)', upgrade Terraform to 1.16.5 or later first" >&2
      echo "       (hashicorp/terraform#39283)." >&2
      return "$rc"
    fi

    if ! grep -q 'API error (409)' "$log"; then
      return "$rc"
    fi

    if [[ $attempt -ge $max_attempts ]]; then
      echo >&2
      echo "ERROR: ${label} still failing with 409 Conflict after ${max_attempts} attempts." >&2
      echo "       The evroc load-balancer controller is rejecting writes as stale. Re-running" >&2
      echo "       './deploy.sh' is safe and usually clears it; if it does not, apply just the" >&2
      echo "       load balancer serially:" >&2
      echo "         terraform apply -parallelism=1 -target=module.ai_factory.evroc_lb_l4_route.cluster \\" >&2
      echo "                                        -target=module.ai_factory.evroc_lb_backend_service.cluster" >&2
      return "$rc"
    fi

    echo
    echo "==> ${label} hit a 409 Conflict on evroc's load-balancer API (optimistic concurrency:"
    echo "    the controller modified the object while Terraform was writing it). Re-planning and"
    echo "    retrying -- attempt $((attempt + 1)) of ${max_attempts}."
    attempt=$((attempt + 1))
    sleep 5
  done
}

# Plan once, then run the checks that need to see the plan before anything is
# created. Both read the plan and this directory's state; neither writes
# either. A plan that fails skips them: the apply that follows fails on the
# same error and shows it better.
preflight() {
  local probe a
  local -a plan_args=()
  for a in ${TF_ARGS[@]+"${TF_ARGS[@]}"}; do
    [[ "$a" == -auto-approve ]] || plan_args+=("$a")
  done

  probe=$(mktemp -d "$SCRATCH/preflight.XXXXXX")
  # shellcheck disable=SC2064 # expand $probe now, not at trap time
  trap "rm -rf '$probe'" RETURN

  echo "==> Preflight: planning this apply to check it against the project"

  # The saved plan and its JSON hold every sensitive input in plaintext. They
  # go with $probe on return, and with $SCRATCH on the checks' exit paths.
  if ! terraform plan -input=false -refresh=false -out="$probe/plan.bin" \
      ${plan_args[@]+"${plan_args[@]}"} >"$probe/plan.log" 2>&1 ||
     ! terraform show -json "$probe/plan.bin" >"$probe/plan.json" 2>>"$probe/plan.log" ||
     ! terraform providers schema -json >"$probe/schema.json" 2>>"$probe/plan.log"; then
    echo "    skipped: planning failed (the apply below will show why)."
    return 0
  fi

  # Orphans first: they hold quota without being in state, so on a run that
  # has them the quota check would only report their symptom.
  check_orphans "$probe"
  check_quota "$probe"
}

# Stop before an apply that would CREATE an evroc object whose name already
# exists in the project: an orphan, i.e. an object Terraform created but that
# never made it into this directory's state (see the crash note in
# apply_with_retry; deleted state or reusing a cluster_name get you the same).
#
# Why not let the apply find out: a create over an existing name fails with
# a 409, which apply_with_retry takes for the load balancer's optimistic-
# concurrency race and retries. And even when the create fails cleanly, the
# orphan stays outside state, so `terraform destroy` will never remove it.
#
# How: plan (no refresh, never saved to this directory), take every evroc
# create and its planned name, then look each name up with the provider's own
# data sources from a throwaway root module under .deploy-tmp/, so this
# directory's state is only read. A 404 means free. Success means an orphan. Any other
# error makes the check inconclusive, and it gets out of the way rather than
# block a deploy on a probe failure.
#
# Found orphans are written as import blocks (evroc import IDs are the object
# names) to orphan-imports.tf.proposed. The suffix keeps Terraform from loading
# it until an operator has reviewed it and renamed it.
check_orphans() {
  local probe="$1" found

  echo "==> Orphan check: does anything this apply would create already exist in the project?"

  # Every line of every data block is mapped to its lookup, so a diagnostic's
  # line number names the lookup it belongs to. Only types that have a data source, and only project/region
  # arguments that data source accepts.
  mkdir "$probe/root"
  if ! python3 - "$probe" <<'PY'
import json, sys
d = sys.argv[1]
plan = json.load(open(d + "/plan.json"))
schema = json.load(open(d + "/schema.json"))
ds = {}
for src, p in schema.get("provider_schemas", {}).items():
    if src.endswith("/evroc"):
        ds = {k: v["block"].get("attributes", {})
              for k, v in p.get("data_source_schemas", {}).items()}
# One list entry per file line: the diagnostics map back by line number.
lines = ['terraform {',
         '  required_providers {',
         '    evroc = { source = "evroc-oss/evroc" }',
         '  }',
         '}',
         'provider "evroc" {}']
rows = {}
for rc in plan.get("resource_changes", []):
    change = rc.get("change") or {}
    after = change.get("after") or {}
    t = rc.get("type", "")
    if rc.get("mode") != "managed" or t not in ds or change.get("actions") != ["create"] \
            or not isinstance(after.get("name"), str):
        continue
    args = ["name = %s" % json.dumps(after["name"])]
    for k in ("project", "region"):
        if k in ds[t] and isinstance(after.get(k), str):
            args.append("%s = %s" % (k, json.dumps(after[k])))
    # HCL allows only one argument in a one-line block, so each lookup spans
    # several lines, and every one of them maps back to it.
    n = len(set(r[0] for r in rows.values()))
    for text in ['data "%s" "p%d" {' % (t, n)] + ["  " + a for a in args] + ["}"]:
        lines.append(text)
        rows[len(lines)] = [rc["address"], after["name"]]
open(d + "/root/main.tf", "w").write("\n".join(lines) + "\n")
json.dump(rows, open(d + "/rows.json", "w"))
PY
  then
    echo "    skipped: could not read the plan."
    return 0
  fi

  if [[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$probe/rows.json")" == 0 ]]; then
    echo "    nothing to create."
    return 0
  fi

  # The provider already installed here, pinned by the same lock file: no
  # download, and the lookups run the exact provider the apply will.
  cp .terraform.lock.hcl "$probe/root/"
  if ! terraform -chdir="$probe/root" init -input=false -plugin-dir="$PWD/.terraform/providers" \
      >>"$probe/plan.log" 2>&1; then
    echo "    skipped: could not initialise the lookup module."
    return 0
  fi
  # Fails whenever any lookup 404s, i.e. almost always. The diagnostics are the
  # result, so the exit code is not.
  terraform -chdir="$probe/root" plan -input=false -json >"$probe/lookup.json" 2>>"$probe/plan.log" || true

  # Prints the orphans as "address<TAB>name", writes their import blocks, and
  # exits 3 if some lookup failed for a reason other than 404.
  found=$(python3 - "$probe" <<'PY'
import json, sys
d = sys.argv[1]
rows = {int(k): v for k, v in json.load(open(d + "/rows.json")).items()}
missing, unsure = set(), False
for raw in open(d + "/lookup.json"):
    try:
        msg = json.loads(raw)
    except ValueError:
        continue
    diag = msg.get("diagnostic") if msg.get("type") == "diagnostic" else None
    if not diag or diag.get("severity") != "error":
        continue
    line = ((diag.get("range") or {}).get("start") or {}).get("line")
    text = "%s %s" % (diag.get("summary", ""), diag.get("detail", ""))
    if line in rows and "API error (404)" in text:
        missing.add(line)
    else:
        unsure = True
if unsure:
    sys.exit(3)
# Rows repeat once per line of their block; keep each lookup once, in order.
missing = set(rows[l][0] for l in missing)
orphans, seen = [], set()
for l in sorted(rows):
    addr = rows[l][0]
    if addr not in missing and addr not in seen:
        seen.add(addr)
        orphans.append(rows[l])
if orphans:
    with open("orphan-imports.tf.proposed", "w") as f:
        f.write("# Written by deploy.sh's orphan check. Review, then rename to imports.tf,\n"
                "# re-run ./deploy.sh, and delete imports.tf once the apply succeeds.\n")
        for addr, name in orphans:
            f.write('\nimport {\n  to = %s\n  id = %s\n}\n' % (addr, json.dumps(name)))
for addr, name in orphans:
    print("%s\t%s" % (addr, name))
PY
  ) || {
    echo "    skipped: some lookups failed for a reason other than 'not found'."
    return 0
  }

  if [[ -z "$found" ]]; then
    echo "    none."
    return 0
  fi

  echo >&2
  echo "ERROR: these objects already exist in the evroc project but are not in this" >&2
  echo "       directory's state; the apply would try to create them again:" >&2
  printf '%s\n' "$found" | awk -F'\t' '{ printf "         %-60s %s\n", $1, $2 }' >&2
  echo >&2
  echo "       Most likely left behind by an interrupted or crashed apply. To adopt them:" >&2
  echo "         1. review orphan-imports.tf.proposed (just written, one import block each)" >&2
  echo "         2. mv orphan-imports.tf.proposed imports.tf" >&2
  echo "         3. terraform plan    (expect 'N to import'; stop if any show as destroy)" >&2
  echo "         4. ./deploy.sh, then delete imports.tf once it succeeds" >&2
  echo "       Or, if they belong to some other deployment, pick a different cluster_name." >&2
  exit 1
}

# Stop before an apply whose cluster cannot fit in what the organization has
# FREE. The module's own quota_check compares the cluster alone with the limit
# and deliberately ignores usage (see availability.tf), so a second cluster in
# an org that already runs one passes the plan and then dies at the admission
# webhook, possibly in pass 2, after the whole image build.
#
# Usage counts this cluster's own objects too, which is why the module cannot
# use it. This can: the plan's prior state says exactly which public IPs and
# VMs this directory already holds, and the plan's compute-profile lookup
# gives each VM's vCPU and memory. So headroom = limit - usage + own, compared
# with the cluster's peak demand (the quota_request output). GPU workers are
# excluded, as in the module: they are not drawn from this quota, and the GPU
# quota is not exposed to Terraform at all.
#
# Only a shortage stops the run. Anything the check cannot work out (no
# quota_request output, an unknown flavor) skips that part with a note.
# Recently deleted VMs can keep counting against usage for a while
# (PLATFORM-NOTES.md), so a shortage right after a teardown may clear by
# itself; --skip-quota-check exists for when you know better.
check_quota() {
  local probe="$1" report rc=0

  if [[ "$SKIP_QUOTA_CHECK" == true ]]; then
    echo "==> Quota check: skipped (--skip-quota-check)"
    return 0
  fi
  echo "==> Quota check: does this cluster's peak fit in what the organization has free?"

  # Exit 0: fits. 1: shortage. 3: could not tell (reason on stdout).
  report=$(python3 - "$probe" <<'PY'
import json, re, sys
plan = json.load(open(sys.argv[1] + "/plan.json"))
q = ((plan.get("output_changes") or {}).get("quota_request") or {}).get("after")
if not isinstance(q, dict) or not all(isinstance(q.get(k), dict) for k in ("demand", "limit", "usage")):
    print("no plan-time quota_request output.")
    sys.exit(3)
demand, limit, usage = q["demand"], q["limit"], q["usage"]

def walk(mod):
    for r in mod.get("resources") or []:
        yield r
    for c in mod.get("child_modules") or []:
        for r in walk(c):
            yield r
prior = list(walk((((plan.get("prior_state") or {}).get("values")) or {}).get("root_module") or {}))
managed = [r for r in prior if r.get("mode") == "managed"]

GB = {"KB": 1e-6, "MB": 1e-3, "GB": 1.0, "TB": 1e3}
def gb(v):
    m = re.match(r"^\s*([0-9.]+)\s*([A-Za-z]+)\s*$", str(v))
    return float(m.group(1)) * GB[m.group(2).upper()] if m and m.group(2).upper() in GB else None

profiles = {}
for r in prior:
    if r.get("mode") == "data" and r.get("type") == "evroc_compute_profiles":
        for p in (r.get("values") or {}).get("details") or []:
            profiles[p.get("name")] = p
own_vcpus, own_mem, unknown = 0, 0.0, []
for r in managed:
    if r.get("type") == "evroc_virtual_machine" and r.get("name") != "gpu":
        f = (r.get("values") or {}).get("flavor")
        p = profiles.get(f)
        if p is None:
            unknown.append(str(f))
            continue
        own_vcpus += p.get("vcpus") or 0
        m = gb("%s%s" % (p.get("memory_amount"), p.get("memory_unit")))
        own_mem = None if m is None or own_mem is None else own_mem + m
own_ips = sum(1 for r in managed if r.get("type") == "evroc_public_ip")

rows = [("public IPs", demand.get("public_ips"), limit.get("public_ips"), usage.get("public_ips"), own_ips, "")]
if unknown:
    print("    vCPU/memory not checked: no compute profile for flavor(s) %s" % ", ".join(sorted(set(unknown))))
else:
    rows.append(("vCPUs", demand.get("vcpus"), limit.get("vcpus"), usage.get("vcpus"), own_vcpus, ""))
    rows.append(("memory", demand.get("memory_gb"), gb(limit.get("memory")), gb(usage.get("memory")), own_mem, " GB"))

short = False
for what, need, lim, used, own, unit in rows:
    if None in (need, lim, used, own):
        print("    %-10s not checked: value not known at plan time" % what)
        continue
    free = lim - used + own
    ok = need <= free
    short = short or not ok
    fmt = lambda x: ("%g" % round(x, 1)) + unit
    print("    %-10s %s  needs %s, free %s  (limit %s, in use %s, %s of it this cluster's)"
          % (what, "ok   " if ok else "SHORT", fmt(need), fmt(free), fmt(lim), fmt(used), fmt(own)))
sys.exit(1 if short else 0)
PY
  ) || rc=$?

  case "$rc" in
    0)
      printf '%s\n' "$report"
      ;;
    1)
      printf '%s\n' "$report" >&2
      echo >&2
      echo "ERROR: this cluster does not fit in the organization's free quota; the apply" >&2
      echo "       would fail at evroc's admission webhook partway through (possibly in" >&2
      echo "       pass 2, after the image build). Free capacity by tearing something down," >&2
      echo "       use smaller flavors or control_plane_count, or ask evroc for more quota." >&2
      echo "       Just deleted something? evroc can keep counting it for a while; retry in" >&2
      echo "       a few minutes, or pass --skip-quota-check if you are sure it will fit." >&2
      exit 1
      ;;
    *)
      echo "    skipped: ${report:-could not evaluate the quota}"
      ;;
  esac
}

# Reads this directory's last-applied state directly -- no plan, no refresh,
# nothing that could itself be perturbed by what this run is about to do.
#
# snapshot_ids is a MAP keyed by zone (evroc snapshots are zonal, so a
# multi-zone cluster has one per zone), and it is present but full of nulls
# before the handoff has happened. So "has the handoff already happened?" is
# "does this map have at least one non-null value?", not "is the output
# non-empty". -json rather than -raw, which cannot print a map at all.
EXISTING_SNAPSHOT_IDS=$(
  terraform output -json snapshot_ids 2>/dev/null |
    python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(", ".join(sorted("%s=%s" % (z, s) for z, s in (v or {}).items() if s)))
' || true
)

if [[ -n "$EXISTING_SNAPSHOT_IDS" && "$REBUILD" == false ]]; then
  # The handoff already happened on some previous run. Both passes have
  # nothing left to sequence, and going back through pass 1 would set
  # image_ready = false and destroy the snapshot the whole cluster is cloned
  # from. Re-assert image_ready -- in case the file was deleted or edited --
  # and apply once.
  echo "==> Snapshots already in state ($EXISTING_SNAPSHOT_IDS): the image handoff is done."
  echo "    Re-asserting image_ready = true and applying once (pass --rebuild to build a fresh image)."
  # Safe to fold the reclaim into this single apply, unlike the two-pass path
  # below: the snapshots already exist, so nothing is being created from the
  # disks this deletes. That only addresses the ordering race, not the lasting
  # cost of deleting a snapshot's source -- see reclaim_build_disks.
  if [[ "$RECLAIM" == true ]]; then
    echo "    Also reclaiming the image-target disks: the snapshots become the only copy of the image."
    PIN_RECLAIM=true
  fi
  pin_image_ready
  preflight
  apply_with_retry "Apply"
  echo "==> Done. See outputs for jumphost_public_ipv4, kubernetes_api_endpoint, api_vip and rancher_url."
  exit 0
fi

if [[ -n "$EXISTING_SNAPSHOT_IDS" ]]; then
  echo "==> --rebuild against a standing cluster: pass 1 sets image_ready = false, which DESTROYS"
  echo "    every snapshot in state ($EXISTING_SNAPSHOT_IDS). Each node's boot disk is a clone of"
  echo "    its own zone's snapshot, so the nodes will be replaced and the cluster rebuilt."
  echo "    Review the plan before approving."
fi

# The key is omitted entirely rather than set to false: absent means
# var.image_ready's own default applies, which is the same thing and leaves
# one place -- the module -- defining what the default is.
echo "==> Resetting pass2.auto.tfvars.json before pass 1 (see the comment above for why)"
cat > pass2.auto.tfvars.json <<'EOF'
{}
EOF

preflight

# No nodes in pass 1, deliberately: control-plane and GPU VMs are gated on
# local.snapshot_expected, which is false until image_ready flips. Saying
# otherwise here sent someone looking for VMs that pass 2 had not created yet.
echo "==> Pass 1: network, load balancer and the per-zone image factories. No cluster"
echo "    nodes yet -- their boot disks are clones of a snapshot pass 2 has not taken."
echo "    (this blocks for tens of minutes once the jumphost starts building the image;"
echo "     progress: curl \"\$(terraform output -raw build_status_url)/<zone>\"; full log:"
echo "     ssh <jumphost_username>@<jumphost ip> tail -f /var/log/elemental-factory.log)"
apply_with_retry "Pass 1"

echo "==> Pass 2: detach the image-build disk, snapshot it, and flip image_ready so nodes clone from it"
# Auto-loaded, so every plan/apply after this one -- including a bare
# `terraform apply` -- keeps image_ready true instead of silently reverting
# it to its false default and tearing the snapshot (and the cluster cloned
# from it) back down.
pin_image_ready
apply_with_retry "Pass 2"

# A no-op under --keep-build-disks. Separate from pass 2 on purpose.
reclaim_build_disks

echo "==> Done. See outputs for jumphost_public_ipv4, kubernetes_api_endpoint, api_vip and rancher_url."
echo "==> pass2.auto.tfvars.json now pins image_ready for every future plan/apply in this"
echo "    directory -- do not delete it. A bare 'terraform apply' is safe from here; re-run this"
echo "    script only to rebuild the image."
