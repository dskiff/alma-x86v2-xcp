#!/bin/bash
# Normalize a finished image's raw disk, after its VM has powered off.
# Usage: sudo normalize.sh <disk.raw> <epoch>
#
# seal.sh cleans the image from inside the VM, but the VM goes on writing
# while it shuts down: systemd saves a fresh random seed, chronyd its drift,
# rsyslog its journal cursor, NetworkManager its lease and timestamps, and
# the logs get the shutdown's own lines. Each of these differs between two
# builds, and the random seed would be shared by every clone. This removes
# them, sets the RPM database's install times to <epoch>, then sets every
# timestamp later than <epoch> (the newest package's build time) to <epoch>,
# so that files the install generated carry the same times in every build. Files from packages keep their own times, which
# are all earlier.
#
# Finally it trims each filesystem, so freed blocks read as zeros.

set -euo pipefail

if [[ $# -ne 2 || ! -f "$1" || ! "$2" =~ ^[1-9][0-9]+$ ]]; then
  echo "Usage: $0 <disk.raw> <epoch>" >&2
  exit 2
fi
raw=$1
epoch=$2
here=$(cd "$(dirname "$0")" && pwd)

mnt=$(mktemp -d)
loop=""
cleanup() {
  set +e
  mountpoint -q "${mnt}" && umount "${mnt}"
  if [[ -n "${loop}" ]]; then
    vgchange --devices "${loop}p3" -an vg0 >/dev/null 2>&1
    losetup -d "${loop}"
  fi
  rmdir "${mnt}"
}
trap cleanup EXIT

# Every image's volume group is vg0, and device-mapper names (vg0-root) are
# global to the host, so two images can't be normalized at once (./build.sh
# builds both in parallel). Wait for the other one; the lock is released when
# this script exits, after the cleanup.
exec 9>/run/lock/alma-x86v2-xcp-normalize.lock
flock 9

loop=$(losetup --find --show --partscan "${raw}")
udevadm settle
# --devices: the host's LVM may only scan devices in its own devices file.
vgchange --devices "${loop}p3" -ay vg0 >/dev/null
udevadm settle

# Rewrite a file in place, keeping its inode and so its SELinux label (this
# host doesn't run SELinux, so a new file would have none).
rewrite() {
  local file=$1 content=$2
  printf '%s\n' "${content}" >"${file}"
}

# One filesystem at a time, at its own mount point. Paths are relative to it.
normalize_fs() {
  local name=$1 dev=$2
  mount -o nouuid "${dev}" "${mnt}"
  # The RPM database records when each package was installed
  # (scripts/rpmdb-times.py). It is on / on AlmaLinux 10, on /var on 9.
  local rpmdb=""
  case "${name}" in
    root) rpmdb="${mnt}/usr/lib/sysimage/rpm/rpmdb.sqlite" ;;
    var) rpmdb="${mnt}/lib/rpm/rpmdb.sqlite" ;;
  esac
  if [[ -n "${rpmdb}" && -f "${rpmdb}" && ! -L "${rpmdb}" ]]; then
    python3 "${here}/rpmdb-times.py" "${rpmdb}" "${epoch}"
  fi
  case "${name}" in
    var)
      rm -f "${mnt}/lib/systemd/random-seed" \
        "${mnt}/lib/chrony/drift" \
        "${mnt}/lib/rsyslog/imjournal.state" \
        "${mnt}/lib/NetworkManager/timestamps" \
        "${mnt}"/lib/NetworkManager/*.lease
      ;;
    logs | auditlogs)
      # As seal.sh does: keep the files (their modes and labels), empty them,
      # except the journal's, which journald would take for corrupt: remove
      # those, with the directories named after the build VM's machine ID.
      if [[ -d "${mnt}/journal" ]]; then
        find "${mnt}/journal" -mindepth 1 -delete
      fi
      find "${mnt}" -type f -exec truncate -s 0 {} +
      ;;
  esac
  # systemd's ConditionNeedsUpdate= compares this with /usr's mtime, which
  # the clamp below sets to the epoch.
  # (/etc/.updated is on the root filesystem, /var/.updated on /var's.)
  for updated in "${mnt}/.updated" "${mnt}/etc/.updated"; do
    if [[ -f "${updated}" ]]; then
      rewrite "${updated}" "$(sed -E "s/^TIMESTAMP_NSEC=.*/TIMESTAMP_NSEC=${epoch}000000000/" "${updated}")"
    fi
  done
  # -h: a symlink's own time, not its target's.
  find "${mnt}" -xdev -newermt "@${epoch}" -exec touch -h -d "@${epoch}" {} +
  fstrim "${mnt}"
  umount "${mnt}"
}

normalize_fs boot "${loop}p2"
for lv in root opt var logs auditlogs home; do
  normalize_fs "${lv}" "/dev/vg0/${lv}"
done

echo "Normalized ${raw} to $(date -u -d "@${epoch}" +%FT%TZ)"
