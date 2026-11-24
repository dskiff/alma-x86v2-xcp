#!/bin/bash
# Build a specific target or all targets (in parallel).
# Usage: ./build.sh [alma9|alma10]

set -eu -o pipefail

# Rerun this script under a private ssh-agent, which holds the throwaway build
# key below so that its private half never stays on disk. The agent exits
# within seconds of this script's process ending, even after a SIGKILL or crash
# that skips the EXIT trap, and takes the key with it.
if [[ -z "${BUILD_SH_AGENT:-}" ]]; then
  export BUILD_SH_AGENT=1
  exec ssh-agent "${BASH}" "$0" "$@"
fi
unset BUILD_SH_AGENT

cd "$(dirname "$0")"

if [[ $# -gt 1 || ($# -eq 1 && "$1" != "alma9" && "$1" != "alma10") ]]; then
  echo "Usage: $0 [alma9|alma10]" >&2
  exit 2
fi

# Record exactly what the image is built from. Uncommitted changes in the
# repository are flagged, since the hash alone wouldn't describe them.
git_hash=$(git rev-parse HEAD)
changes=$(git status --porcelain -- .)
if [[ -n "${changes}" ]]; then
  echo "WARNING: the repository has uncommitted changes; labelling the build ${git_hash}-dirty" >&2
  git_hash="${git_hash}-dirty"
fi

# Throwaway SSH key for Packer's build session. Its public half goes into the
# kickstart, and scripts/seal.sh removes it from the image again. Its private
# half is on disk only until the agent has loaded it; Packer signs with the
# agent (ssh_agent_auth).
key_dir=$(mktemp -d)
# Stopping the agent here clears the key at once instead of seconds later.
trap 'rm -rf "${key_dir}"; ssh-agent -k >/dev/null' EXIT
ssh-keygen -q -t ed25519 -N '' -C packer-build -f "${key_dir}/id_ed25519"
ssh-add -q "${key_dir}/id_ed25519"
build_ssh_public_key=$(<"${key_dir}/id_ed25519.pub")
rm -rf "${key_dir}"

# Keep the build directories private. Each holds the disk being installed and
# the VM's QMP socket (see vnc_use_password), and anyone who can open either can
# change the image before it's sealed. Locking the parent works whatever the
# umask, and leaves the modes of the files themselves (and so of the release
# assets) unchanged.
mkdir -p output
chmod 700 output

vars=(
  -var "git_hash=${git_hash}"
  -var "build_ssh_public_key=${build_ssh_public_key}"
)

set -x

packer init .

# Validate templates before building
packer validate "${vars[@]}" .

if [[ $# -eq 1 ]]; then
  packer build "${vars[@]}" -only="qemu.$1" .
else
  packer build "${vars[@]}" .
fi
