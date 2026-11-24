#!/bin/bash
# Fail the build if cloud-init would create any user on a clone's first boot.
# The stock cloud.cfg creates a default user (almalinux or cloud-user) with
# passwordless sudo, and the kickstart's cloud.cfg.d drop-in turns that off.
# This asks cloud-init's own code what the merged config means, so a later
# drop-in or a cloud.cfg change that brings the user back fails here.
# User-data can still create users; this only checks the image's defaults.
set -euxo pipefail

python3 - <<'EOF'
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
print(f"users cloud-init would create: {sorted(users)}")
if users:
    raise SystemExit("ERROR: cloud-init would create users on first boot")
EOF
