#!/bin/bash
# Fail the build unless rpm verifies every installed package's signature with
# a key from /etc/pki/rpm-gpg/.
#
# Anaconda doesn't check signatures: it installs from the kickstart's url and
# repo sources on the strength of HTTPS and the repo metadata's checksums. dnf
# checks later updates against the keys in /etc/pki/rpm-gpg/ (the repo files'
# gpgkey=), so this holds the installed packages to the same keys. Those keys
# arrive with the install (almalinux-gpg-keys, epel-release), so this catches
# unsigned packages and packages signed by any other key, not a source that
# serves its own keys. Compare the key IDs it prints with the publishers'
# fingerprints, which end in them.
set -euo pipefail

keydir=/etc/pki/rpm-gpg

# Work on a copy of the rpmdb that trusts exactly the keys in ${keydir}, so the
# result doesn't depend on which keys the image has imported so far, and the
# image's own rpmdb stays as it is.
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
db="${tmp}/rpmdb"
mkdir "${db}"
cp -a "$(rpm --eval '%{_dbpath}')/." "${db}/"
rpmcopy() { rpm --dbpath "${db}" "$@"; }

if rpmcopy -q gpg-pubkey >/dev/null; then
  rpmcopy -e --allmatches gpg-pubkey
fi
rpmcopy --import "${keydir}"/*
echo "Trusted keys (from ${keydir}):"
rpmcopy -q gpg-pubkey --qf '  %{VERSION}-%{RELEASE} %{SUMMARY}\n'

# rpm checks each header's signature against its keys as it reads the header.
# A bad one is reported on stderr and the package is left out, while rpm still
# exits 0.
sigs=$(rpmcopy -qa \
  --qf '%{NAME} %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} %{RSAHEADER:pgpsig}\n' \
  2>"${tmp}/errors")
if [[ -s "${tmp}/errors" ]]; then
  echo "ERROR: rpm rejected installed packages:" >&2
  cat "${tmp}/errors" >&2
  exit 1
fi

# "<package> <key ID that signed its header, or none>". The pgpsig text ends
# in "Key ID <64-bit key ID>"; an unsigned package shows "(none)".
signers=$(awk '$1 != "gpg-pubkey" {
  print $2, (($(NF-2) == "Key" && $(NF-1) == "ID" && $NF ~ /^[0-9a-f]{16}$/) ? $NF : "none")
}' <<<"${sigs}")
failed=0

unsigned=$(awk '$2 == "none" { print "  " $1 }' <<<"${signers}")
if [[ -n "${unsigned}" ]]; then
  echo "ERROR: these packages have no header signature:" >&2
  echo "${unsigned}" >&2
  failed=1
fi

# rpm can't check a signature whose key it doesn't have. It reports that as
# NOKEY, silently, so check each signer is one of the keys imported above.
while read -r keyid count; do
  if key=$(rpmcopy -q --whatprovides "gpg(${keyid})" --qf '%{SUMMARY}\n'); then
    echo "ok: ${count} packages signed by key ID ${keyid}: ${key}"
  else
    echo "ERROR: ${count} packages are signed by key ID ${keyid}, which isn't in ${keydir}:" >&2
    awk -v keyid="${keyid}" '$2 == keyid { print "  " $1 }' <<<"${signers}" >&2
    failed=1
  fi
done < <(awk '$2 != "none" { n[$2]++ } END { for (k in n) print k, n[k] }' <<<"${signers}")

exit "${failed}"
