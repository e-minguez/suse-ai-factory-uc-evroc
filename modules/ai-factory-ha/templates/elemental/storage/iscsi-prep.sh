# Seed the /etc state open-iSCSI needs, then start iscsid. Run at every boot by
# iscsi-prep.service (butane.yaml.tftpl), and ONLY on an image whose component
# set pulls the suse-storage extension in.
#
# Why it has to exist at all: systemd-sysext merges /usr (and /opt) and nothing
# else. The suse-storage extension therefore delivers /usr/sbin/iscsid and
# /usr/lib/systemd/system/iscsid.{service,socket} -- and NOT one byte of what
# the open-iscsi RPM would normally put in /etc. An extension cannot ship /etc,
# and it has no install scriptlet either, so:
#
#   * /etc/iscsi does not exist at all,
#   * /etc/iscsi/initiatorname.iscsi -- which the RPM generates per machine at
#     install time -- is missing, and iscsid.socket's ExecStartPre fails, so
#     `systemctl start iscsid` reports only "A dependency job for
#     iscsid.service failed",
#   * /etc/iscsi/iscsid.conf is missing, so iscsid logs "can't open ...
#     configuration file" for every setting it reads,
#   * nothing is in any .wants directory, so iscsid is `disabled` and never
#     starts on its own.
#
# The failure that surfaces from this is nowhere near iSCSI: Longhorn installs
# cleanly, every pod is Running, the node objects are Ready and schedulable,
# the PVC BINDS and replicas schedule -- and then the consuming pod sits in
# ContainerCreating for ever with
#
#   AttachVolume.Attach failed for volume "pvc-..." : rpc error:
#   code = DeadlineExceeded desc = volume ... failed to attach to node ...
#
# because the host has no iSCSI initiator to log in to the engine's target
# with. Creating /etc/iscsi, generating an InitiatorName and starting iscsid
# by hand attaches the volume immediately.
set -euo pipefail

log() { echo "iscsi-prep: $*"; }

# The extension may not be merged yet this early in boot. Wait a bounded time,
# then give up QUIETLY -- same principle as write-node-ip.service: a node that
# refuses to boot over a storage extension is worse than a node without
# Longhorn. `systemctl status iscsi-prep` and the journal say what happened.
for _ in $(seq 1 30); do
  if [ -x /usr/sbin/iscsid ]; then
    break
  fi
  sleep 2
done

if [ ! -x /usr/sbin/iscsid ]; then
  log "no /usr/sbin/iscsid after 60s -- the suse-storage extension is not merged; nothing to do"
  exit 0
fi

mkdir -p /etc/iscsi

# Must exist or iscsid will not start, and must be UNIQUE per node -- which is
# exactly why it cannot be baked into the image: one image serves every node.
# Generated once and then left alone, so it is stable across reboots for as
# long as /etc is (and regenerated harmlessly if it is not).
if [ ! -s /etc/iscsi/initiatorname.iscsi ]; then
  if command -v iscsi-iname >/dev/null 2>&1; then
    initiator_name="$(iscsi-iname)"
  else
    # Fallback only. Hostnames are unique per cluster, so this keeps the
    # uniqueness property that matters to Longhorn.
    initiator_name="iqn.2016-04.com.open-iscsi:$(hostname)"
  fi
  printf 'InitiatorName=%s\n' "$initiator_name" >/etc/iscsi/initiatorname.iscsi
  chmod 0600 /etc/iscsi/initiatorname.iscsi
  log "generated InitiatorName=$initiator_name"
fi

# Without this iscsid runs on compiled-in defaults and warns about every
# setting it tried to read ("can't open iscsid.safe_logout configuration file
# /etc/iscsi/iscsid.conf", and one line like it per setting).
#
# The candidate list below finds nothing on the 5.279-4.13 extension
# (/usr/share/doc/packages/open-iscsi holds only README and iface.example, and
# `find /usr -name 'iscsid.conf*'` is empty), so the fallback is the live path.
# The search is kept ahead of it anyway: it costs three stat() calls, and if a
# later extension does carry a stock config that one should win, rather than
# this script pinning defaults for ever.
if [ ! -s /etc/iscsi/iscsid.conf ]; then
  stock_conf=""
  for candidate in \
    /usr/etc/iscsi/iscsid.conf \
    /usr/share/open-iscsi/iscsid.conf \
    /usr/share/doc/packages/open-iscsi/iscsid.conf; do
    if [ -f "$candidate" ]; then
      stock_conf="$candidate"
      break
    fi
  done

  if [ -n "$stock_conf" ]; then
    cp "$stock_conf" /etc/iscsi/iscsid.conf
    log "seeded /etc/iscsi/iscsid.conf from $stock_conf"
  else
    cat >/etc/iscsi/iscsid.conf <<'EOF'
# Written at boot by iscsi-prep.service: the suse-storage systemd extension
# carries no /etc, and open-iscsi's own default config is part of its RPM's
# /etc payload. These are open-iscsi's built-in defaults, restated so iscsid
# stops warning on every start.
iscsid.startup = /bin/systemctl start iscsid.socket
node.startup = manual
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5
EOF
    log "wrote fallback /etc/iscsi/iscsid.conf"
  fi
  chmod 0600 /etc/iscsi/iscsid.conf
fi

# SELinux is Enforcing. A file created under /etc inherits etc_t, which is what
# these two are labelled on a stock install, so this is belt and braces.
if command -v restorecon >/dev/null 2>&1; then
  restorecon -R /etc/iscsi || log "WARNING: restorecon on /etc/iscsi failed"
fi

# The transport module. The extension's modules-load.d normally covers it; this
# is a no-op when it is already loaded and makes the unit self-contained.
modprobe iscsi_tcp || log "WARNING: modprobe iscsi_tcp failed"

# --no-block is load-bearing. A blocking `systemctl start` from inside a unit
# that iscsid is ordered after would wait on a job that cannot run until this
# one finishes; --no-block queues it and returns. The unit deliberately carries
# no Before=iscsid.service for the same reason.
#
# Not `systemctl enable`: that writes a .wants symlink into /etc pointing at a
# unit file that lives in the EXTENSION, which dangles on every boot until
# systemd-sysext has merged. Starting it from here each boot needs no such
# symlink and has no ordering window to get wrong.
systemctl start --no-block iscsid.service
log "iscsid start requested"
