#!/bin/bash
# Seal the image: remove everything specific to this build VM so every clone
# starts clean. This must be the last provisioner: the first boot, Packer's SSH
# session and the CIS scan all create per-instance state.
set -euxo pipefail

# The CIS scan sets a 365-day maximum age and a 45-day INACTIVE period on every
# account with a password, overriding the kickstart's "don't expire". Once the
# password expires, key-based SSH fails too ("Password change required but no
# TTY available"), locking ansible out. Restore "never expires".
chage -M -1 -I -1 -E -1 ansible

# Machine identity. An empty machine-id makes systemd generate a new one on the
# first boot; "uninitialized" (cloud-init clean --machine-id) would also mark it
# as a first boot and re-apply unit presets, undoing the kickstart's choices.
truncate -s 0 /etc/machine-id
if [[ -f /var/lib/dbus/machine-id && ! -L /var/lib/dbus/machine-id ]]; then
  rm -f /var/lib/dbus/machine-id
fi
rm -f /var/lib/systemd/random-seed
# cloud-init (or sshd-keygen) generates new host keys on each clone's first boot.
# Overwrite the build's keys before deleting them: the fstrim below can leave a
# small deleted file's data in the image (see there).
find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -type f \
  -exec shred --iterations=0 --zero --remove {} +

# Build-time state.
cloud-init clean --logs --seed
# The CIS scan builds an AIDE baseline mid-build. It would be stale on every
# clone, so each VM should run `aide --init` once it is configured.
rm -f /var/lib/aide/aide.db.gz /var/lib/aide/aide.db.new.gz
# Kickstart copies and installer logs.
rm -rf /root/anaconda-ks.cfg /root/original-ks.cfg /root/anaconda-post.log /var/log/anaconda
dnf clean all
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f -not -path '/var/log/journal/*' -exec truncate -s 0 {} +

# Hand freed blocks back to the disk image (disk_discard / disk_detect_zeroes =
# unmap), which also drops most of the files deleted above from the published
# image. A failed trim fails the build.
# Trim each filesystem by path, not with -a: -a skips a disk that doesn't
# advertise discard with no error, so it can trim nothing and exit 0.
# Every filesystem in the kickstart is XFS.
# Even a successful trim can't free part of a 64 KiB qcow2 cluster, so a small
# deleted file that shares a cluster with live data stays in the image.
# Overwrite anything secret before deleting it, as the host keys are above.
findmnt -rn -t xfs -o TARGET | while read -r mnt; do fstrim -v "$mnt"; done

# Last: remove the throwaway build key; Use cloud-init to install per-VM keys.
# Packer keeps its current SSH connection open for the shutdown command.
rm -f /home/ansible/.ssh/authorized_keys
