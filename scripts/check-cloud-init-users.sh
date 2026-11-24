#!/bin/bash
# Fail the build unless ansible is the only user cloud-init would set up on a
# clone's first boot, as its default user. The kickstart's cloud.cfg.d drop-in
# puts ansible in place of the stock default user (almalinux or cloud-user),
# which would be a second account with passwordless sudo. This asks
# cloud-init's own code what the merged config means, so a later drop-in or a
# cloud.cfg change that brings the stock user back fails here.
# cloud-init doesn't apply groups or shell to a user that already exists, so
# it also checks them against the account the kickstart created: a mismatch
# would otherwise only show in the config, never on a VM.
# User-data can still create users; this only checks the image's defaults.
set -euxo pipefail

python3 - <<'EOF'
import grp
import pwd

from cloudinit import util
from cloudinit.distros import ug_util

# cloud.cfg merged with cloud.cfg.d/*.cfg, as cloud-init reads it at boot.
cfg = util.read_conf_with_confd("/etc/cloud/cloud.cfg")


class Distro:
    # normalize_users_groups only asks the distro for its default user, which
    # cloud-init's distros read from system_info.
    def get_default_user(self):
        return cfg.get("system_info", {}).get("default_user")


users, _groups = ug_util.normalize_users_groups(cfg, Distro())
default, default_cfg = ug_util.extract_default(users)
print(f"users cloud-init would set up: {sorted(users)}; default user: {default}")
if sorted(users) != ["ansible"] or default != "ansible":
    raise SystemExit("ERROR: cloud-init must set up ansible as its only user, its default user")


def group_set(groups):
    # cloud-init accepts a list or a comma-separated string.
    if isinstance(groups, str):
        groups = groups.split(",")
    return {g.strip() for g in groups or [] if g.strip()}


account = pwd.getpwnam("ansible")
want = {
    "groups": sorted(g.gr_name for g in grp.getgrall() if "ansible" in g.gr_mem),
    "shell": account.pw_shell,
    "lock_passwd": True,
}
got = {
    "groups": sorted(group_set(default_cfg.get("groups"))),
    "shell": default_cfg.get("shell"),
    # create_user locks the password unless lock_passwd is false.
    "lock_passwd": default_cfg.get("lock_passwd", True),
}
print(f"account: {want}")
print(f"cloud-init's default user: {got}")
if got != want:
    raise SystemExit("ERROR: cloud-init's default user doesn't match the ansible account")
EOF
