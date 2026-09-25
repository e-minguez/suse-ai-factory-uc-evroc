#!/usr/bin/env bash
# Invoked from image-build.tf's terraform_data.image_written via a local-exec
# provisioner, on the OPERATOR's machine (not on any build host). Polls the
# status relay on the jumphost (templates/status-relay.py) until every zone
# reports "done <BUILD_ID>". A zone reporting "failed <BUILD_ID> ..." fails the
# apply at once, instead of waiting out the timeout. Idempotent: if every zone
# already reports done for this build, this returns immediately, so a
# re-applied or interrupted apply resumes rather than waiting out builds that
# already finished.
#
# Status line format, one per zone: "<state> <build_id> <free text>", state
# being building, done or failed. A line carrying a DIFFERENT build id was
# left by a previous build and says nothing about this one.
#
# Plain HTTP GETs, no SSH: every build host pushes its own status to the relay
# (the jumphost on localhost, the builders across the VPC), so nothing on the
# operator's side needs a key, a known_hosts entry, or a tunnel.
#
# "done" is ALL this verifies. It deliberately does not try to confirm the
# zones built the same image -- see "why there is no cross-zone equality check"
# near the bottom, which also records the check that would actually be sound.
set -euo pipefail

: "${STATUS_URL:?STATUS_URL must be set}"
: "${ZONES:?ZONES must be set}"
: "${BUILD_ID:?BUILD_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"
IMAGE_READY=${IMAGE_READY:-false}
HEARTBEAT_SECONDS=${HEARTBEAT_SECONDS:-300}
# Consecutive failed polls before a zone is reported as "relay unreachable".
# The jumphost is created by this same apply, so the first poll or two
# legitimately find nothing listening yet.
UNREACHABLE_AFTER=3

log() {
  echo "[wait-for-image] $*" >&2
}

# With image_ready = true nothing is building and security-groups.tf has
# closed the relay port, so the only way to get here is a build id that
# changed AFTER pass 1 -- see the comment on terraform_data.image_written.
# Waiting would only burn image_build_timeout on a build that cannot happen.
if [ "$IMAGE_READY" = "true" ]; then
  log "ERROR: build \"$BUILD_ID\" has to be waited for, but image_ready = true -- nothing is building."
  log "An image-affecting input changed since pass 1, so the images on the disks are from a build that no longer matches the config."
  log "Rebuild against the current config: ./deploy.sh --rebuild (or set image_ready = false and apply)."
  exit 1
fi

# Parallel arrays rather than associative ones: bash 3.2 is still what
# /bin/bash is on macOS, where this provisioner most often runs, and it has no
# `declare -A`.
read -r -a ZONE_LIST <<<"$ZONES"
N=${#ZONE_LIST[@]}
ZONE_DONE=() # "1" once the zone reported done for BUILD_ID; latched, never re-polled
LAST=()      # the last line logged for the zone, so output is print-on-change
FAILS=()     # consecutive polls on which the relay could not be reached
for ((i = 0; i < N; i++)); do
  ZONE_DONE[i]=0
  LAST[i]=""
  FAILS[i]=0
done

log "waiting for build \"$BUILD_ID\" in zone(s) $ZONES via $STATUS_URL (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"
START=$SECONDS
LAST_BEAT=$SECONDS
while :; do
  pending=0
  for ((i = 0; i < N; i++)); do
    [[ ${ZONE_DONE[i]} == 1 ]] && continue
    z=${ZONE_LIST[i]}

    rc=0
    body=$(curl -fsS -m 10 "$STATUS_URL/$z" 2>/dev/null) || rc=$?
    case "$rc" in
      0)
        FAILS[i]=0
        line=${body%%$'\n'*}
        ;;
      22)
        # HTTP error: the relay answered, but this zone has published nothing.
        FAILS[i]=0
        line="waiting (no status published yet)"
        ;;
      *)
        FAILS[i]=$((FAILS[i] + 1))
        if ((FAILS[i] >= UNREACHABLE_AFTER)); then
          line="waiting (relay unreachable ${FAILS[i]} polls in a row, curl exit $rc)"
        else
          line=${LAST[i]}
        fi
        ;;
    esac

    state="" id=""
    read -r state id _ <<<"$line"
    if [[ $state == "done" || $state == failed || $state == building ]] && [[ $id != "$BUILD_ID" ]]; then
      line="waiting (stale status from build $id)"
      state=stale
    fi
    # The unreachable count changes every poll; log only the crossing and then
    # every time it would have been a heartbeat anyway.
    if [[ $line != "${LAST[i]}" ]] && { ((FAILS[i] == 0 || FAILS[i] == UNREACHABLE_AFTER)); }; then
      log "zone $z: $line"
    fi
    LAST[i]=$line

    case "$state" in
      done)
        ZONE_DONE[i]=1
        log "zone $z: confirmed after $((SECONDS - START))s"
        continue
        ;;
      failed)
        log "zone $z FAILED -- read /var/log/elemental-factory.log on that zone's build host:"
        log "  terraform output jumphost_ssh_login / builder_private_ips, then ssh (-J <jumphost login> for a builder)"
        exit 1
        ;;
    esac
    pending=$((pending + 1))
  done

  ((pending == 0)) && break

  if ((SECONDS - START >= TIMEOUT_SECONDS)); then
    log "TIMEOUT after ${TIMEOUT_SECONDS}s. Last state per zone:"
    for ((i = 0; i < N; i++)); do
      [[ ${ZONE_DONE[i]} == 1 ]] || log "  zone ${ZONE_LIST[i]}: ${LAST[i]:-nothing heard}"
    done
    log "A zone still at \"building\" is stuck on that step; one that never published at all never started or cannot reach the relay."
    exit 1
  fi
  if ((SECONDS - LAST_BEAT >= HEARTBEAT_SECONDS)); then
    log "still waiting after $((SECONDS - START))s: $pending of $N zone(s) not yet done"
    LAST_BEAT=$SECONDS
  fi
  sleep "$POLL_SECONDS"
done

# --- why there is no cross-zone equality check -----------------------------
#
# Every zone ran its own build. Nothing coordinated them, and nothing could:
# evroc snapshots are zonal, so one image cannot be built once and cloned
# outward (see locals.tf's primary_zone). They all pulled the same OCI
# references at roughly the same moment -- but OCI TAGS ARE MUTABLE, and the
# elemental customize image, the core platform image and the sysext images are
# all referenced by tag. A tag that moves mid-build gives one zone a different
# image from its siblings, silently: every zone reports the same build id,
# every snapshot is created, the cluster comes up, and one zone runs software
# the others do not.
#
# An earlier version of this script tried to catch that by comparing the sha256
# each host recorded for the raw image it produced. THAT CHECK CANNOT WORK, and
# it is worth saying why so nobody adds it back. `elemental customize` does not
# produce a reproducible artefact: it lays down fresh filesystems, so every run
# gets new filesystem UUIDs and new GPT partition GUIDs, and file mtimes come
# from the moment of the build. Two runs from byte-identical inputs on one host
# already differ; three hosts that started minutes apart differ by construction.
# The check failed on every multi-zone build, including ones where nothing had
# moved upstream -- an alarm that is always on is worse than no alarm, because
# the real response to it becomes "rerun with the check disabled".
#
# image-factory.sh still records /var/lib/image-factory/image.sha256. It is
# useful for confirming a disk holds the image that was built next to it; it is
# not evidence about any other zone.
#
# The check that WOULD be sound compares inputs rather than outputs: resolve
# every OCI reference to a digest on each host (`podman image inspect --format
# '{{.Digest}}'`, or `skopeo inspect` before pulling) and require the digests to
# agree across zones. That is a real invariant -- same digests in, same software
# out -- and it is unaffected by build nondeterminism. Not implemented yet;
# until it is, pinning elemental_image, core_platform_override and
# sysext_image_overrides to digests rather than tags is what actually prevents
# the divergence, rather than detecting it afterwards.

# --- boot diagnostics ------------------------------------------------------
#
# image-factory.sh loop-mounts the image it just built and records two facts
# into /var/lib/image-factory/boot-diagnostics.txt: the kernel command line as
# it survived into the installed GRUB config, and the device labels this
# image's own Ignition binary searches for. Both decide whether a node will
# boot, and evroc gives no way to find out afterwards -- there is no serial
# console and no VNC, so a node that hangs in the initrd is indistinguishable
# from one that is merely slow (see PLATFORM-NOTES.md).
#
# Each build host copies that file to the relay, because pass 2 destroys every
# builder to stay inside the vCPU quota, taking the original with it. Printed
# here so it lands in the apply output. Best-effort -- a missing copy is not
# worth failing an otherwise successful build over.
for z in "${ZONE_LIST[@]}"; do
  DIAG=$(curl -fsS -m 10 "$STATUS_URL/$z/diag" 2>/dev/null) || DIAG=""
  if [ -n "$DIAG" ]; then
    log "--- boot diagnostics, zone $z ---"
    printf '%s\n' "$DIAG" >&2
  else
    log "zone $z: no boot diagnostics recorded (build still succeeded)"
  fi
done

log "build \"$BUILD_ID\" ready in $N zone(s)"
