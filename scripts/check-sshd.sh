#!/bin/bash
# Fail the build if sshd would accept passwords by default. The kickstart turns
# them off, but the CIS scan rewrites sshd's configuration (it moves sshd_config
# into sshd_config.d/ and strips the settings it manages from every drop-in), so
# check the effective configuration after it. A clone's user-data can still turn
# passwords on with ssh_pwauth (see the kickstart).
set -euxo pipefail

cfg=$(sshd -T)
grep -x 'passwordauthentication no' <<<"${cfg}"
grep -x 'kbdinteractiveauthentication no' <<<"${cfg}"
