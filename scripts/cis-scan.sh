#!/bin/bash
# Run the CIS Server Level 1 scan and remediation, writing its results to
# /tmp/build-evidence. Run via sudo.
#
# DATASTREAM: the SCAP data stream, from the locked scap-security-guide.
# RPM_REPO_URL: the repository of locked packages that the installer used
#   (see build.sh); empty for an unlocked build.
#
# The scan doesn't fetch the remote resources the data stream refers to (the
# vendor's security advisory OVAL feed, which changes daily): no rule of this
# profile reads them.
#
# Some remediations install packages with dnf (AIDE, systemd-journal-remote).
# In a locked build they must come from the locked repository too, so for the
# scan the image's own repositories are set aside and dnf sees only that one.
set -euxo pipefail

: "${DATASTREAM:?}"
install -d -m 0755 /tmp/build-evidence

if [[ -n "${RPM_REPO_URL:-}" ]]; then
  # On the same filesystem, so that moving them back restores the same files.
  aside=/etc/cis-scan-repos
  install -d -m 0700 "${aside}"
  mv /etc/yum.repos.d/*.repo "${aside}/"
  restore() {
    rm -f /etc/yum.repos.d/locked.repo
    # dnf clean leaves the cache directory of a repository that is no longer
    # configured, and its name derives from the URL, whose port changes.
    rm -rf /var/cache/dnf/locked-*
    mv "${aside}"/*.repo /etc/yum.repos.d/
    rmdir "${aside}"
    dnf clean all
  }
  trap restore EXIT
  # The same keys the image's own repositories check packages against.
  keys=$(find /etc/pki/rpm-gpg -maxdepth 1 -type f -printf 'file://%p\n' | sort | paste -sd ' ')
  cat >/etc/yum.repos.d/locked.repo <<REPO
[locked]
name=Locked packages for this build
baseurl=${RPM_REPO_URL}
gpgcheck=1
gpgkey=${keys}
REPO
  dnf clean all
fi

# oscap exits 2 when a rule fails, which is expected before remediation.
oscap xccdf eval \
  --progress \
  --remediate \
  --results-arf /tmp/build-evidence/oscap_arf.xml \
  --report /tmp/build-evidence/oscap_report.html \
  --profile xccdf_org.ssgproject.content_profile_cis_server_l1 \
  "${DATASTREAM}" </dev/null || true
