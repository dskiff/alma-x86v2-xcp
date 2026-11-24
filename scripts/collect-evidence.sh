#!/bin/bash
# Collect the build's records so they ship next to the VHD. They describe the
# build VM, so they don't belong inside the image itself.
set -euxo pipefail

evidence=/tmp/build-evidence

# The CIS scan writes its results here; a missing result means it didn't run.
test -s "${evidence}/oscap_arf.xml"
test -s "${evidence}/oscap_report.html"

cp /tmp/build_info.yaml /root/anaconda-post.log "${evidence}/"
rpm -qa | sort >"${evidence}/packages.txt"
# The newest installed package's build time. scripts/finalize.sh clamps every
# later timestamp in the image to it, so timestamps depend on the packages,
# not on when the image was built. Nothing installs packages after this
# script: seal.sh only removes state.
rpm -qa --qf '%{BUILDTIME}\n' | sort -n | tail -n 1 >"${evidence}/source_date_epoch"
grep -Eqx '[1-9][0-9]+' "${evidence}/source_date_epoch"
# The AlmaLinux version actually installed, which names the release assets. The
# kickstart installs from the floating repositories, not the ISO, so this can
# be newer than the ISO's version. (-L: /etc/os-release is a symlink.)
cp -L /etc/os-release "${evidence}/os-release"

# Packer downloads the directory as the (unprivileged) build user.
chown -R "${SUDO_USER:?run this script via sudo}:" "${evidence}"
