#!/usr/bin/env bash
# Invoked from image-build.tf's terraform_data.image_written via a local-exec
# provisioner, on the OPERATOR's machine (not on any build host). Polls every
# zone's build host over SSH for /var/lib/image-factory/done and waits until
# each one contains the CURRENT build id. Idempotent: if every sentinel already
# carries that id, this returns immediately, so a re-applied or interrupted
# apply resumes rather than waiting out builds that already finished.
#
# Sentinels are ALL this verifies. It deliberately does not try to confirm the
# zones built the same image -- see "why there is no cross-zone equality check"
# near the bottom, which also records the check that would actually be sound.
#
# Reachability: the jumphost (PRIMARY_ZONE) has the only public IP and is
# dialled directly. Every builder is private-only and is tunnelled through the
# jumphost. Both hops authenticate with the operator's own key --
# the same var.ssh_authorized_keys is installed on every build host, so nothing
# has to generate or carry key material to make the tunnel work.
set -euo pipefail

: "${JUMPHOST_IP:?JUMPHOST_IP must be set}"
: "${JUMPHOST_USER:?JUMPHOST_USER must be set}"
: "${BUILDER_TARGETS:?BUILDER_TARGETS must be set}"
: "${PRIMARY_ZONE:?PRIMARY_ZONE must be set}"
: "${BUILD_ID:?BUILD_ID must be set}"
: "${TIMEOUT_SECONDS:?TIMEOUT_SECONDS must be set}"
: "${POLL_SECONDS:?POLL_SECONDS must be set}"

log() {
  echo "[wait-for-image] $*" >&2
}

# A throwaway known_hosts, discarded when this script exits.
#
# WHY NOT THE OPERATOR'S ~/.ssh/known_hosts: build hosts are cattle on recycled
# addresses. Destroy a cluster and build another and the jumphost very often
# comes back on an address a previous jumphost held, with a different host key.
# Against the operator's known_hosts that is a HOST KEY CHANGE, and ssh refuses
# the connection outright -- exit 255, which this script cannot tell apart from
# "the host has not booted yet", so it waits out the entire
# image_build_timeout (90 minutes by default) on a failure that was permanent
# from the first second. That happened; it is why this file looks like this.
# The operator's file also gets polluted with an entry per build host per
# cluster, and the next `ssh` they type by hand fails the same way.
#
# TOFU is still enforced WITHIN one run -- accept-new against a file that
# starts empty means the first probe pins each host's key and a key that
# changes mid-build is still refused, which for a host that is supposed to be
# sitting there building an image is a genuine red flag. What is given up is
# recognition ACROSS runs, which was never worth anything here: these hosts did
# not exist before this apply created them.
KNOWN_HOSTS=$(mktemp "${TMPDIR:-/tmp}/evroc-known-hosts.XXXXXX")
# shellcheck disable=SC2064 # expand KNOWN_HOSTS now, not at trap time
trap "rm -f '$KNOWN_HOSTS'" EXIT

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  # accept-new, not the default (ask) or "no": a local-exec provisioner has no
  # terminal to answer an interactive host-key prompt on, so the default would
  # hang forever on the very first connection ever made to this host.
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$KNOWN_HOSTS"
  -o GlobalKnownHostsFile=/dev/null
  # Quiets the per-connection post-quantum-key-exchange warning recent OpenSSH
  # clients print against older servers -- with two hops per probe and a probe
  # every POLL_SECONDS it otherwise buries this script's own output. ERROR, not
  # QUIET: a connection that actually fails still says why, which the transient
  # /absent distinction below depends on being able to report.
  -o LogLevel=ERROR
)

# What to suggest when telling the operator to go and look for themselves. The
# build hosts are deliberately not in their known_hosts (above), so a bare
# `ssh` would prompt, or worse, refuse on a recycled address.
SSH_HINT_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ProxyJump does NOT pass this script's -o options down to the ssh it spawns
# for the jump hop, so that hop would go back to the operator's known_hosts and
# reintroduce exactly the failure described above -- on the one host every
# builder is reached through. An explicit ProxyCommand is the way to control
# the inner client's options. %q-quoted because the string is handed to a
# shell, and mktemp's path is not guaranteed to be free of anything a shell
# cares about.
PROXY_COMMAND="ssh $(printf '%q ' "${SSH_OPTS[@]}")-W %h:%p"

# --- targets ---------------------------------------------------------------
#
# Parallel arrays rather than an associative array: bash 3.2 is still what
# /bin/bash is on macOS, where this provisioner most often runs, and it has no
# `declare -A`.
ZONES=()
HOSTS=()

ZONES+=("$PRIMARY_ZONE")
HOSTS+=("$JUMPHOST_IP")

# BUILDER_TARGETS is [{"zone":...,"host":...}, ...], possibly []. Parsed with
# python3 rather than jq: jq is not installed by default on macOS, python3 is.
if [ "$BUILDER_TARGETS" != "[]" ]; then
  while IFS=$'\t' read -r zone host; do
    [ -n "$zone" ] || continue
    ZONES+=("$zone")
    HOSTS+=("$host")
  done < <(printf '%s' "$BUILDER_TARGETS" | python3 -c '
import json, sys
for t in json.load(sys.stdin):
    print("%s\t%s" % (t["zone"], t["host"]))
')
fi

TARGET_COUNT=${#ZONES[@]}

# How to reach index $1: the jumphost directly, everything else tunnelled
# through it.
ssh_to() {
  local idx=$1
  shift
  if [ "$idx" -eq 0 ]; then
    ssh "${SSH_OPTS[@]}" "$JUMPHOST_USER@${HOSTS[$idx]}" "$@"
  else
    ssh "${SSH_OPTS[@]}" \
      -o "ProxyCommand=$PROXY_COMMAND $JUMPHOST_USER@$JUMPHOST_IP" \
      "$JUMPHOST_USER@${HOSTS[$idx]}" "$@"
  fi
}

# Everything that goes after `ssh` for a human to reach index $1 themselves.
# Carries the host-key options for the same reason this script does: these
# hosts are not in the operator's known_hosts, and on a recycled address they
# may be in it with the WRONG key, which is precisely the situation someone
# reading this hint is likely to be in. The jump hop needs its own copy --
# ProxyJump does not pass -o options down to the client it spawns, so a bare
# `-J` here would reproduce the failure the hint exists to diagnose.
ssh_hint() {
  local idx=$1
  if [ "$idx" -eq 0 ]; then
    printf '%s %s@%s' "$SSH_HINT_OPTS" "$JUMPHOST_USER" "${HOSTS[$idx]}"
  else
    printf '%s -o "ProxyCommand=ssh %s -W %%h:%%p %s@%s" %s@%s' \
      "$SSH_HINT_OPTS" "$SSH_HINT_OPTS" \
      "$JUMPHOST_USER" "$JUMPHOST_IP" \
      "$JUMPHOST_USER" "${HOSTS[$idx]}"
  fi
}

# Three-way outcome, because the caller has to tell "the build hasn't
# finished yet" apart from "SSH itself could not be attempted right now":
#   0  found: the sentinel exists and carries BUILD_ID
#   1  definitively absent: SSH answered, but the file is missing OR carries a
#      DIFFERENT build id -- a sentinel left over from a PREVIOUS build reads
#      as absent, not found, since it says nothing about this one
#   2  transient: SSH itself failed (connection refused, host not up yet,
#      network blip, timeout) -- nothing was learned about the build, which
#      proceeds on the build host regardless of whether SSH happens to answer
#
# On a 2, PROBE_ERR carries ssh's own stderr. Never throw that away: "not up
# yet" and "misconfigured, will never work" are the same exit code, and the
# whole point of reporting a transient is that the operator can see WHICH.
PROBE_ERR=""
probe() {
  local idx=$1 content rc=0 errfile
  errfile=$(mktemp "${TMPDIR:-/tmp}/evroc-probe-err.XXXXXX")
  content=$(ssh_to "$idx" 'cat /var/lib/image-factory/done 2>/dev/null' 2>"$errfile") || rc=$?
  PROBE_ERR=$(tr '\n' ' ' <"$errfile" | sed 's/  */ /g; s/^ //; s/ $//')
  rm -f "$errfile"

  # OpenSSH's ssh client reserves exit code 255 for a connection/session that
  # never came up at all; any other code is the REMOTE command's own exit
  # status, which for a plain `cat` on a reachable host is only ever 0 (read)
  # or 1 (file missing) -- both of which say something real about the
  # sentinel, not about SSH. A failure at EITHER hop is still reported as 255,
  # which is the outcome we want: a jumphost that is not up yet is transient
  # for the builders behind it too.
  if [ "$rc" -eq 255 ]; then
    return 2
  fi

  content=$(printf '%s' "$content" | tr -d '[:space:]')
  if [ "$content" = "$BUILD_ID" ]; then
    return 0
  fi
  return 1
}

log "polling $TARGET_COUNT build host(s) for build id \"$BUILD_ID\" (timeout ${TIMEOUT_SECONDS}s, every ${POLL_SECONDS}s)"
for i in $(seq 0 $((TARGET_COUNT - 1))); do
  if [ "$i" -eq 0 ]; then
    log "  zone ${ZONES[$i]}: $JUMPHOST_USER@${HOSTS[$i]} (jumphost, direct)"
  else
    log "  zone ${ZONES[$i]}: $JUMPHOST_USER@${HOSTS[$i]} (builder, via jumphost)"
  fi
done

# DONE[i] is "1" once that host's sentinel has been seen carrying BUILD_ID.
# Latched, never re-checked: the builds are independent and finish at different
# times, so a host that reported done must not be re-probed on every later poll
# -- N zones would otherwise mean N SSH round trips per poll for the whole
# duration of the slowest build.
DONE=()
# Consecutive transient (255) probes per host, reset by any probe that reaches
# the host. A build host that has never once answered after several minutes is
# not "still booting" -- see the escalation in the poll loop.
STREAK=()
# The last thing ssh said about each host, kept per-host so the timeout report
# quotes that host's failure and not whichever host happened to be probed last.
LASTERR=()
for i in $(seq 0 $((TARGET_COUNT - 1))); do
  DONE+=("0")
  STREAK+=("0")
  LASTERR+=("")
done

# How many consecutive transients before this stops being plausible as "still
# coming up". The VM was created by the same apply that is running now, so the
# first poll or two legitimately hit a host with no sshd yet; five minutes of
# nothing is a different animal.
STREAK_WARN=$((300 / POLL_SECONDS))
[ "$STREAK_WARN" -lt 2 ] && STREAK_WARN=2

START_TIME=$(date +%s)
LAST_PROGRESS_LOG=$START_TIME

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))

  REMAINING=0
  for i in $(seq 0 $((TARGET_COUNT - 1))); do
    [ "${DONE[$i]}" = "1" ] && continue

    RC=0
    probe "$i" || RC=$?

    case "$RC" in
      0)
        DONE[$i]="1"
        log "zone ${ZONES[$i]}: sentinel confirms build \"$BUILD_ID\" complete after ${ELAPSED}s"
        ;;
      1)
        # SSH answered, sentinel absent or stale -- keep waiting, clock keeps
        # running.
        STREAK[$i]="0"
        REMAINING=$((REMAINING + 1))
        ;;
      2)
        # NOT fatal and does NOT reset the clock: the build proceeds on the
        # host whether or not SSH happens to answer any single poll --
        # cloud-init may still be finishing, sshd may not be up yet, or this is
        # just an ordinary transient network blip.
        #
        # But "transient" is an assumption, not an observation, and it used to
        # be made silently: a permanently broken SSH path logged the same
        # reason-free line every 30s and burned the entire timeout. So always
        # print ssh's own words, and once the streak makes "still booting"
        # implausible, say out loud that this is probably not transient at all.
        STREAK[$i]=$(( ${STREAK[$i]} + 1 ))
        REASON="${PROBE_ERR:-no output from ssh}"
        LASTERR[$i]="$REASON"
        if [ "${STREAK[$i]}" -eq "$STREAK_WARN" ]; then
          # Once, on the crossing. Repeating the hint every poll for the rest of
          # a 90-minute timeout would bury it.
          log "zone ${ZONES[$i]}: WARNING: SSH has failed ${STREAK[$i]} times in a row (~$((STREAK[i] * POLL_SECONDS))s) and has never once succeeded -- this is probably NOT transient: $REASON"
          log "zone ${ZONES[$i]}: check by hand: ssh $(ssh_hint "$i") true"
          log "zone ${ZONES[$i]}: this script no longer uses (or touches) your known_hosts, so a stale host key is not the cause; suspect the host, the key, or the security group."
          log "zone ${ZONES[$i]}: still waiting until the ${TIMEOUT_SECONDS}s timeout in case the host really is just slow. Ctrl-C if you would rather fix it now (${ELAPSED}s elapsed)."
        elif [ "${STREAK[$i]}" -gt "$STREAK_WARN" ]; then
          log "zone ${ZONES[$i]}: SSH still failing (${STREAK[$i]} in a row, ${ELAPSED}s elapsed): $REASON"
        else
          log "zone ${ZONES[$i]}: transient, SSH did not complete this poll; still waiting (${ELAPSED}s elapsed): $REASON"
        fi
        REMAINING=$((REMAINING + 1))
        ;;
    esac
  done

  [ "$REMAINING" -eq 0 ] && break

  if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
    log "ERROR: timed out after ${ELAPSED}s waiting for build \"$BUILD_ID\"."
    log "A build still in progress and one that failed silently look identical from here, by design."
    log "Still unconfirmed, with the log to check on each:"
    for i in $(seq 0 $((TARGET_COUNT - 1))); do
      [ "${DONE[$i]}" = "1" ] && continue
      log "  zone ${ZONES[$i]}: ssh $(ssh_hint "$i") tail -f /var/log/elemental-factory.log"
      if [ "${STREAK[$i]}" -gt 0 ]; then
        log "    NOTE: SSH never succeeded on the last ${STREAK[$i]} attempt(s), so the build's state here was never observed: ${LASTERR[$i]:-no output from ssh}"
      fi
    done
    exit 1
  fi

  if [ $((NOW - LAST_PROGRESS_LOG)) -ge 60 ]; then
    log "still waiting: $REMAINING of $TARGET_COUNT build host(s) not yet confirmed (${ELAPSED}s elapsed)"
    LAST_PROGRESS_LOG=$NOW
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
# image from its siblings, silently: every sentinel reports the same build id,
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
# Dumped here because THIS is the last moment the build hosts exist: pass 2
# destroys every builder to stay inside the vCPU quota, taking the file with
# it. Best-effort -- a missing or unreadable file is not worth failing an
# otherwise successful build over.
for i in $(seq 0 $((TARGET_COUNT - 1))); do
  DIAG=$(ssh_to "$i" 'cat /var/lib/image-factory/boot-diagnostics.txt 2>/dev/null' 2>/dev/null) || DIAG=""
  if [ -n "$DIAG" ]; then
    log "--- boot diagnostics, zone ${ZONES[$i]} ---"
    printf '%s\n' "$DIAG" >&2
  else
    log "zone ${ZONES[$i]}: no boot diagnostics recorded (build still succeeded)"
  fi
done

log "build \"$BUILD_ID\" ready in ${TARGET_COUNT} zone(s)"
