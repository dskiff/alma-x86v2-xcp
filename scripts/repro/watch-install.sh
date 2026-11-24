#!/bin/bash
# Follow a build's installer from CI, and stop the build if the install fails.
# Usage: watch-install.sh <image> &     (in the background of ./build.sh)
#
# Copies the guest's serial console into the job log as it is written, each
# line prefixed so that it can't start a workflow command. When Anaconda
# stops with an error, Packer would otherwise go on waiting for SSH until
# its timeout (an hour). Instead this prints the installer's own log, which
# the templates' virtio port (org.fedoraproject.anaconda.log.0) writes to
# anaconda.log next to serial.log and which holds the reason, then
# interrupts Packer so the build fails at once.

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
    sleep 15 # let the installer finish logging the reason
    echo "::error::The ${image} install failed; the installer's log follows"
    if [[ -f "${dir}anaconda.log" ]]; then
      sed 's/^/anaconda| /' "${dir}anaconda.log"
    else
      echo "(no anaconda.log)"
    fi
    pkill -INT -f "packer build" || true
    break
  fi
done
