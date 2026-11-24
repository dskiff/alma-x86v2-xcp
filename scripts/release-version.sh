#!/bin/bash
# Print the next release version for a UTC date, given the tags already taken.
# Usage: release-version.sh <YYYYMMDD> <true|false (pre-release)> < taken-tags
#
# Versions are SemVer: v0.<date>.<patch>. The major is the scheme's version, so
# a later scheme starts at v1 and sorts above every tag of this one. The patch
# counts that day's releases:
#
#   - It's one more than the highest patch already tagged that day, not a count,
#     so a release that failed or was deleted never has its number reused.
#   - A pre-release doesn't use a patch. It's a pre-release of the next one,
#     v0.<date>.<patch>-pre.<n>, which SemVer sorts before the release that
#     later takes that patch.
#
# Pass every tag that exists, including those of failed attempts: the release
# workflow creates the tag before the draft, so tags are the reservations. A
# name that can't be created anyway (GitHub keeps a deleted immutable release's
# tag name from being reused, but no longer lists it) is the caller's to skip:
# add it to the input and ask again.

set -eu -o pipefail

if [[ $# -ne 2 || ! "$1" =~ ^[1-9][0-9]{7}$ || ! "$2" =~ ^(true|false)$ ]]; then
  echo "Usage: $0 <YYYYMMDD> <true|false> < taken-tags" >&2
  exit 2
fi
date=$1
prerelease=$2

# Numeric parts never have leading zeros (SemVer forbids them).
num='(0|[1-9][0-9]*)'
full_re="^v0\\.${date}\\.${num}\$"

tags=$(cat)

patch=-1
while IFS= read -r tag; do
  if [[ "${tag}" =~ ${full_re} ]] && ((BASH_REMATCH[1] > patch)); then
    patch=${BASH_REMATCH[1]}
  fi
done <<<"${tags}"
patch=$((patch + 1))

if [[ "${prerelease}" == false ]]; then
  echo "v0.${date}.${patch}"
  exit 0
fi

pre=-1
pre_re="^v0\\.${date}\\.${patch}-pre\\.${num}\$"
while IFS= read -r tag; do
  if [[ "${tag}" =~ ${pre_re} ]] && ((BASH_REMATCH[1] > pre)); then
    pre=${BASH_REMATCH[1]}
  fi
done <<<"${tags}"
echo "v0.${date}.${patch}-pre.$((pre + 1))"
