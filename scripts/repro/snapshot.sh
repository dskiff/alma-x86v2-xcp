#!/bin/bash
# Record everything about one finished build that a second build could differ
# in, so scripts/repro/compare.py can diff two of them.
# Usage: sudo snapshot.sh <build dir> <out dir>
#
# <build dir> is a Packer output directory (output/alma_<N>_<id>/), with the
# qcow2 disk, the .vhd, SHA256SUMS and the downloaded build evidence. The
# snapshot is of the .vhd: the release asset, after scripts/finalize.sh.
# <out dir> gets:
#   files.sha256    digests of the build directory's files (disk, vhd, evidence)
#   evidence/       a copy of the build evidence
#   sfdisk.txt      the partition table
#   blkid.txt       filesystem and LVM UUIDs and labels
#   lvm.txt         PV, VG and LV metadata
#   blocks/<dev>    a digest of every 4 KiB block of each partition and LV
#   manifest/<fs>   one JSON line per path in each filesystem (see manifest.py)
#   tree/<fs>/      a copy of each filesystem, for diffing file contents
#
# The disk is converted to a raw sparse file and attached with losetup, which
# every runner kernel has (nbd may not be). The copy is throwaway, so nothing
# here can change the build's own disk.

set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" ]]; then
  echo "Usage: $0 <build dir> <out dir>" >&2
  exit 2
fi
build_dir=$(cd "$1" && pwd)
out=$2
here=$(cd "$(dirname "$0")" && pwd)

shopt -s nullglob
disks=("${build_dir}"/*.vhd)
if [[ ${#disks[@]} -ne 1 ]]; then
  echo "ERROR: expected one .vhd in ${build_dir}, found ${#disks[@]}" >&2
  exit 1
fi
disk=${disks[0]}

mkdir -p "${out}"/{blocks,manifest,tree}
out=$(cd "${out}" && pwd)

work=$(mktemp -d)
loop=""
mnt="${work}/mnt"
mkdir -p "${mnt}"
cleanup() {
  set +e
  mountpoint -q "${mnt}" && umount "${mnt}"
  if [[ -n "${loop}" ]]; then
    vgchange --devices "${loop}p3" -an vg0 >/dev/null 2>&1
    losetup -d "${loop}"
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

(cd "${build_dir}" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"${out}/files.sha256"
if [[ -d "${build_dir}/build-evidence" ]]; then
  cp -a "${build_dir}/build-evidence" "${out}/evidence"
fi

qemu-img convert -O raw "${disk}" "${work}/disk.raw"
loop=$(losetup --find --show --partscan "${work}/disk.raw")
udevadm settle

sfdisk -d "${loop}" | sed "s|${loop}|DISK|g" >"${out}/sfdisk.txt"
# The PV is the third partition (biosboot, /boot, pv.01 in the kickstarts).
# --devices: Ubuntu's LVM only scans devices in its devices file otherwise.
vgchange --devices "${loop}p3" -ay vg0 >/dev/null
udevadm settle
{
  pvs --devices "${loop}p3" -o pv_name,pv_uuid,pv_size,pe_start --noheadings
  vgs --devices "${loop}p3" -o vg_name,vg_uuid,vg_extent_size,vg_seqno --noheadings
  lvs --devices "${loop}p3" -o lv_name,lv_uuid,seg_start_pe,seg_size_pe,devices,lv_time --noheadings
} | sed "s|${loop}|DISK|g" >"${out}/lvm.txt"

# name:device for every partition and LV, in a fixed order.
devices=(
  "p1-biosboot:${loop}p1"
  "p2-boot:${loop}p2"
  "p3-pv:${loop}p3"
  "lv-root:/dev/vg0/root"
  "lv-opt:/dev/vg0/opt"
  "lv-var:/dev/vg0/var"
  "lv-logs:/dev/vg0/logs"
  "lv-auditlogs:/dev/vg0/auditlogs"
  "lv-home:/dev/vg0/home"
  "lv-swap:/dev/vg0/swap"
)

: >"${out}/blkid.txt"
for entry in "${devices[@]}"; do
  name=${entry%%:*}
  dev=${entry#*:}
  echo "${name}: $(blkid -p -o export "${dev}" 2>/dev/null | grep -v '^DEVNAME=' | tr '\n' ' ')" >>"${out}/blkid.txt"
  # The whole disk's blocks, too, are in p3-pv; the LVs are listed separately
  # so a difference can be put down to a filesystem.
  python3 "${here}/blocks.py" "${dev}" >"${out}/blocks/${name}"
done
python3 "${here}/blocks.py" "${loop}" >"${out}/blocks/disk"

for entry in "${devices[@]}"; do
  name=${entry%%:*}
  dev=${entry#*:}
  case "${name}" in
    p2-boot | lv-*) ;;
    *) continue ;;
  esac
  [[ "${name}" == lv-swap ]] && continue
  # norecovery: never replay the log, which would write. nouuid: don't care
  # whether another filesystem with this UUID was mounted before.
  mount -o ro,norecovery,nouuid "${dev}" "${mnt}"
  python3 "${here}/manifest.py" "${mnt}" >"${out}/manifest/${name}"
  mkdir -p "${out}/tree/${name}"
  rsync -aH --numeric-ids "${mnt}/" "${out}/tree/${name}/"
  umount "${mnt}"
done

echo "Snapshot of ${build_dir} written to ${out}"
