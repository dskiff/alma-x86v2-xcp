#!/bin/bash
# Run the guest agent's binaries here, so a build for a newer x86-64 level
# (Fedora's EPEL 10 targets x86-64-v3) fails the image build instead of
# silently failing on every VM.
#
# Under TCG (the default), a newer instruction raises SIGILL. Under KVM (CI's
# release builds), CPUID still reports Ivy Bridge, so Go's startup check fires,
# but a binary that uses newer instructions without checking runs on the host.
set -euo pipefail

pkg=xe-guest-utilities-latest
rpm -q "${pkg}"

checked=0
failed=0
while IFS= read -r f; do
  [[ -f "${f}" && -x "${f}" ]] || continue
  # ELF executables only (skips shell scripts).
  [[ "$(head -c 4 "${f}" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] || continue

  rc=0
  out=$(timeout 10 "${f}" --help </dev/null 2>&1) || rc=$?
  checked=$((checked + 1))
  # 132 = SIGILL. Go binaries built for a newer level refuse to start with
  # "This program can only be run on AMD64 processors with v3 microarchitecture support."
  if [[ ${rc} -eq 132 ]] || grep -q 'microarchitecture' <<<"${out}"; then
    echo "ERROR: ${f} does not run on the target CPU (exit ${rc}): ${out}" >&2
    failed=1
  else
    echo "ok: ${f}"
  fi
done < <(rpm -ql "${pkg}")

if [[ ${checked} -eq 0 ]]; then
  echo "ERROR: found no executables in ${pkg} to check" >&2
  exit 1
fi
exit "${failed}"
