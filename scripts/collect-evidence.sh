#!/bin/bash
# Collect the build's records so they ship next to the VHD. They describe the
# build VM, so they don't belong inside the image itself.
set -euxo pipefail

evidence=/tmp/build-evidence

# The CIS scan writes its results here; a missing result means it didn't run.
test -s "${evidence}/oscap_arf.xml"
test -s "${evidence}/oscap_report.html"

cp /root/build_info.yaml /root/anaconda-post.log "${evidence}/"
rpm -qa | sort >"${evidence}/packages.txt"
# The AlmaLinux version actually installed, which names the release assets. The
# kickstart installs from the floating repositories, not the ISO, so this can
# be newer than the ISO's version. (-L: /etc/os-release is a symlink.)
cp -L /etc/os-release "${evidence}/os-release"

# Packer downloads the directory as the (unprivileged) build user.
chown -R "${SUDO_USER:?run this script via sudo}:" "${evidence}"
