#!/bin/bash
# Check each template's iso_checksum against AlmaLinux's signed CHECKSUM file.
# Usage: ./verify-iso.sh [template.pkr.hcl ...]   (default: every template)
#
# Renovate bumps iso_url and iso_checksum from the CHECKSUM file next to the
# ISO, but it only parses that file and never checks its signature, so a bump
# is only as trustworthy as the TLS connection Renovate fetched it over. This
# fetches the same CHECKSUM, verifies its clearsigned signature against the
# AlmaLinux release key pinned below, and fails unless the signed part lists
# the template's ISO with the template's digest. Packer then checks the ISO it
# downloads against iso_checksum, which ties the image to AlmaLinux's key.

set -eu -o pipefail

cd "$(dirname "$0")"

# Primary key fingerprints, as published in the AlmaLinux 9.0 and 10.0 release
# notes (wiki.almalinux.org/release-notes/). The keys themselves are in keys/,
# copied from repo.almalinux.org/almalinux/. A new major release needs its key
# added to both.
pinned_fingerprint() {
  case "$1" in
    9) echo BF18AC2876178908D6E71267D36CB86CB86B3716 ;;
    10) echo EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572 ;;
    *) return 1 ;;
  esac
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Prints "<iso_url> <sha256>" for each ISO in a template. Anything that would
# slip past this check (an iso_url without an adjacent sha256 iso_checksum,
# iso_urls, a checksum file reference) is an error rather than skipped.
iso_pairs() {
  local file=$1 line url=""
  while IFS= read -r line; do
    if [[ -n "${url}" ]]; then
      [[ "${line}" =~ ^[[:space:]]*iso_checksum[[:space:]]*=[[:space:]]*\"sha256:([0-9a-f]{64})\"[[:space:]]*$ ]] ||
        die "${file}: iso_url must be immediately followed by iso_checksum = \"sha256:<hex>\""
      echo "${url} ${BASH_REMATCH[1]}"
      url=""
    elif [[ "${line}" =~ ^[[:space:]]*iso_url[[:space:]]*=[[:space:]]*\"(https://[^\"]+)\"[[:space:]]*$ ]]; then
      url=${BASH_REMATCH[1]}
    elif [[ "${line}" =~ ^[[:space:]]*iso_(url|urls|checksum)[[:space:]]*= ]]; then
      die "${file}: can't check this line: ${line}"
    fi
  done <"${file}"
  [[ -z "${url}" ]] || die "${file}: iso_url isn't followed by iso_checksum"
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
export GNUPGHOME="${work}/gnupg"
mkdir -m 700 "${GNUPGHOME}"

verify() {
  local file=$1 url=$2 want=$3
  local iso=${url##*/} dir=${url%/*}
  local major fingerprint keyfile signers got

  [[ "${iso}" =~ ^AlmaLinux-([0-9]+)[.-] ]] || die "${file}: ${iso} isn't an AlmaLinux ISO"
  major=${BASH_REMATCH[1]}
  fingerprint=$(pinned_fingerprint "${major}") || die "${file}: no pinned key for AlmaLinux ${major}"
  keyfile="keys/RPM-GPG-KEY-AlmaLinux-${major}"
  [[ -f "${keyfile}" ]] || die "${file}: ${keyfile} is missing"

  rm -f "${work}"/CHECKSUM* "${work}"/keyring.gpg "${work}"/status
  curl -fsSL --retry 3 --max-time 60 -o "${work}/CHECKSUM" "${dir}/CHECKSUM" ||
    die "${file}: couldn't fetch ${dir}/CHECKSUM"
  gpg --batch --quiet --dearmor -o "${work}/keyring.gpg" "${keyfile}"

  # --output keeps only the signed text: a clearsigned file can carry unsigned
  # lines around the signed block, and those must not count.
  if ! gpgv --keyring "${work}/keyring.gpg" --status-fd 3 \
    --output "${work}/CHECKSUM.signed" "${work}/CHECKSUM" \
    3>"${work}/status" 2>"${work}/gpgv.log"; then
    cat "${work}/gpgv.log" >&2
    die "${file}: ${dir}/CHECKSUM has no valid signature from the AlmaLinux ${major} key"
  fi

  # VALIDSIG's last field is the signing key's primary fingerprint. Every
  # signature must come from the pinned key, whatever else the keyring holds.
  signers=$(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $12 }' "${work}/status" | sort -u)
  [[ "${signers}" == "${fingerprint}" ]] ||
    die "${file}: ${dir}/CHECKSUM is signed by '${signers//$'\n'/, }', not the pinned ${fingerprint}"

  got=$(awk -v name="(${iso})" '$1 == "SHA256" && $2 == name && $3 == "=" { print tolower($4) }' "${work}/CHECKSUM.signed")
  [[ -n "${got}" ]] ||
    die "${file}: the signed ${dir}/CHECKSUM doesn't list ${iso} (a newer point release may have moved it to vault.almalinux.org)"
  [[ "${got}" != *$'\n'* ]] || die "${file}: the signed CHECKSUM lists ${iso} more than once"
  [[ "${got}" == "${want}" ]] ||
    die "${file}: iso_checksum is sha256:${want}, but AlmaLinux's signed CHECKSUM says ${got} for ${iso}"

  echo "OK ${file}: ${iso} sha256:${want} (signed by ${fingerprint})"
}

templates=("$@")
if [[ ${#templates[@]} -eq 0 ]]; then
  templates=(*.pkr.hcl)
fi

checked=0
for file in "${templates[@]}"; do
  [[ -f "${file}" ]] || die "${file} not found"
  pairs=$(iso_pairs "${file}")
  while read -r url sha <&3; do
    [[ -n "${url}" ]] || continue
    verify "${file}" "${url}" "${sha}"
    checked=$((checked + 1))
  done 3<<<"${pairs}"
done

# Fails closed if the templates stop matching the pattern above.
((checked > 0)) || die "no iso_url found in ${templates[*]}"
