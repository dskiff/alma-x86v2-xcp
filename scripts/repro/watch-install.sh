#!/bin/bash
# Follow a build's installer from CI, and stop the build if the install fails.
# Usage: watch-install.sh <image> &     (in the background of ./build.sh)
#
# Copies the guest's serial console into the job log as it is written, each
# line prefixed so that it can't start a workflow command. When Anaconda
# stops with an error, Packer would otherwise go on waiting for SSH until
# its timeout (an hour); this interrupts it so the build fails at once. The
# reason is in the serial log: the storage %pre (http/storage.ks.pkrtpl)
# copies its own output there, and Anaconda's storage log if the install
# stops on storage.
#
# (A virtio port for Anaconda's log would be tidier, but any -device in a
# template's qemuargs makes the qemu builder drop its own disk device.)

set -uo pipefail

image=${1:?usage: watch-install.sh <image>}
shopt -s nullglob

until dirs=(output/"alma_${image#alma}"_*/) && ((${#dirs[@]})) && [[ -e "${dirs[0]}serial.log" ]]; do
  sleep 5
done
dir=${dirs[0]}

tail -n +1 -F "${dir}serial.log" 2>/dev/null | while IFS= read -r line; do
  printf 'serial| %s\n' "${line}"
  if [[ "${line}" == *"The installation was stopped due to an error"* || "${line}" == *"pyanaconda.errors.ScriptError"* ]]; then
    echo "::error::The ${image} install failed; see the serial lines above and below"
    sleep 30 # the storage %pre's watchdog copies the storage log to the console
    # Packer stops and deletes the build directory; the lines logged in the
    # meantime still print, until the workflow step's trap stops this.
    pkill -INT -f "packer build" || true
  fi
done
