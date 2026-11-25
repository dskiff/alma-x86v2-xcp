#!/bin/bash
# Turn a finished build's qcow2 disk into the release VHD.
# Usage: finalize.sh <build dir> <image>     (Packer's post-processor runs it)
#
# 1. Converts the disk to a raw file.
# 2. Runs scripts/normalize.sh on it, which needs root and Linux (losetup,
#    LVM, XFS): it removes what the VM wrote after seal.sh, while it shut
#    down, and clamps timestamps. On other hosts, or without passwordless
#    sudo, it is skipped with a warning; such a VHD works the same but isn't
#    reproducible. Release builds always normalize (FINALIZE_REQUIRE_NORMALIZE=1).
# 3. Converts the raw file to <build dir>/<build dir name>.vhd, with a fixed
#    VHD footer (scripts/vhd-footer.py), and writes SHA256SUMS.
#
# The timestamp everything is clamped to is the newest package's build time,
# from the build evidence (scripts/collect-evidence.sh).

set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" ]]; then
  echo "Usage: $0 <build dir> <image>" >&2
  exit 2
fi
here=$(cd "$(dirname "$0")" && pwd)
dir=$(cd "$1" && pwd)
image=$2
name=${dir##*/}
disk="${dir}/packer-${image}"
vhd="${dir}/${name}.vhd"
epoch_file="${dir}/build-evidence/source_date_epoch"

[[ -f "${disk}" ]] || {
  echo "ERROR: ${disk} not found" >&2
  exit 1
}
epoch=$(<"${epoch_file}")
[[ "${epoch}" =~ ^[1-9][0-9]+$ ]] || {
  echo "ERROR: ${epoch_file} doesn't hold a Unix time" >&2
  exit 1
}

raw="${dir}/disk.raw"
trap 'rm -f "${raw}"' EXIT
qemu-img convert -O raw "${disk}" "${raw}"

can_normalize=false
if [[ "$(uname -s)" == Linux ]] && { [[ ${EUID} -eq 0 ]] || sudo -n true 2>/dev/null; }; then
  can_normalize=true
fi
if [[ "${can_normalize}" == true ]]; then
  if [[ ${EUID} -eq 0 ]]; then
    "${here}/normalize.sh" "${raw}" "${epoch}"
  else
    sudo -n "${here}/normalize.sh" "${raw}" "${epoch}"
  fi
elif [[ "${FINALIZE_REQUIRE_NORMALIZE:-0}" == 1 ]]; then
  echo "ERROR: normalizing needs Linux and root (or passwordless sudo)" >&2
  exit 1
else
  echo "WARNING: not normalizing ${name} (needs Linux and root or passwordless sudo); the VHD won't be reproducible" >&2
fi

# vpc => vhd; see https://docs.openstack.org/image-guide/convert-images.html
qemu-img convert -O vpc "${raw}" "${vhd}"
python3 "${here}/vhd-footer.py" "${vhd}" "${epoch}" "${image}"

cd "${dir}"
{ sha256sum "${name}.vhd" 2>/dev/null || shasum -a 256 "${name}.vhd"; } >SHA256SUMS
cat SHA256SUMS
