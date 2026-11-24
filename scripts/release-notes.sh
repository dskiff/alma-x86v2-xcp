#!/bin/bash
# Write a release's title and notes from its assets and the previous release's.
# Usage: release-notes.sh <work dir>
#
# The work dir holds:
#   current/    this release's *.evidence.tar.gz and *.SHA256SUMS
#   previous/   the previous full release's *.evidence.tar.gz (may be empty)
#   reasons.txt why this release happened, one per line
#   changes.md  the repository changes (GitHub's generated notes)
# and gets title and notes.md. TAG is the release's tag; BASE the previous
# full release's, or empty. The templates are read for each image's ISO.
#
# Most releases change no code, so the notes lead with why the release
# happened and what changed inside each image: the packages.txt diff against
# the previous full release.

set -eu -o pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: TAG=<tag> BASE=<tag or empty> $0 <work dir>" >&2
  exit 2
fi
work=$(cd "$1" && pwd)
tag=${TAG:?set TAG to the release tag}
base=${BASE:-}

cd "$(dirname "$0")/.."

# Evidence assets are <image>-<AlmaLinux version>-<tag>.evidence.tar.gz.
images=()
versions=()
for f in "${work}"/current/*.evidence.tar.gz; do
  [[ -e "${f}" ]] || continue
  name=${f##*/}
  if [[ ! "${name}" =~ ^(alma[0-9]+)-([0-9]+\.[0-9]+)-${tag//./\\.}\.evidence\.tar\.gz$ ]]; then
    echo "ERROR: unexpected asset ${name}" >&2
    exit 1
  fi
  images+=("${BASH_REMATCH[1]}")
  versions+=("${BASH_REMATCH[2]}")
done
if [[ ${#images[@]} -eq 0 ]]; then
  echo "ERROR: no evidence assets in ${work}/current" >&2
  exit 1
fi

# Images in AlmaLinux version order: alma9 before alma10.
order=$(for i in "${!images[@]}"; do echo "${versions[i]} ${i}"; done | sort -n | cut -d' ' -f2)

# The evidence tarball holds the build directory: the evidence itself is under
# build-evidence/, where Packer downloads it.
packages() {
  tar -xzOf "$1" ./build-evidence/packages.txt
}

# Compares two packages.txt files (rpm -qa: name-version-release.arch) by
# package name. Prints "<kind>|<name>|<old>|<new>" for each package that was
# updated (U), added (A) or removed (R), sorted by name. Not tabs: read would
# merge an empty field into its neighbour.
package_diff() {
  awk '
    # gpg-pubkey-<id>-<date> has no arch; everything else ends in .<arch>.
    function split_nevra(s,   n, a, i) {
      if (s !~ /^gpg-pubkey-/ && match(s, /\.[^.]+$/)) {
        s = substr(s, 1, RSTART - 1)
      }
      n = split(s, a, "-")
      if (n < 3) {
        name = s
        vr = ""
        return
      }
      vr = a[n - 1] "-" a[n]
      name = a[1]
      for (i = 2; i <= n - 2; i++) {
        name = name "-" a[i]
      }
    }
    NF {
      f = (FILENAME == ARGV[1]) ? 1 : 2
      split_nevra($0)
      # A package installed more than once (such as gpg-pubkey) lists each.
      # (Assigning to have[key] creates it before the right side is read.)
      key = f SUBSEP name
      if (key in have) {
        v = have[key] ", " vr
      } else {
        v = vr
      }
      have[key] = v
      names[name] = 1
    }
    END {
      for (p in names) {
        o = ((1, p) in have) ? have[1, p] : ""
        c = ((2, p) in have) ? have[2, p] : ""
        if (o == c) continue
        kind = (o == "") ? "A" : (c == "") ? "R" : "U"
        printf "%s|%s|%s|%s\n", kind, p, o, c
      }
    }
  ' "$1" "$2" | sort -t'|' -k2,2
}

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

titles=()
{
  echo "## Why"
  echo
  while IFS= read -r reason; do
    if [[ -n "${reason}" ]]; then
      echo "- ${reason}"
    fi
  done <"${work}/reasons.txt"
  echo
  echo "## Images"
  echo
  echo "| Image | AlmaLinux | Boot ISO | SHA-256 of the .vhd.zst |"
  echo "| --- | --- | --- | --- |"
  for i in ${order}; do
    image=${images[i]}
    version=${versions[i]}
    titles+=("${version}")
    stem="${image}-${version}-${tag}"
    sums="${work}/current/${stem}.SHA256SUMS"
    if [[ ! -f "${sums}" ]]; then
      echo "ERROR: ${stem}.SHA256SUMS is missing" >&2
      exit 1
    fi
    digest=$(awk -v f="${stem}.vhd.zst" '$2 == f { print $1 }' "${sums}")
    iso=$(sed -nE 's|^[[:space:]]*iso_url[[:space:]]*=[[:space:]]*"[^"]*/([^/"]+)".*$|\1|p' "${image}.pkr.hcl")
    echo "| ${image} | ${version} | \`${iso}\` | \`${digest}\` |"
  done
  echo
  echo "Each \`.SHA256SUMS\` also covers the decompressed \`.vhd\`. Each \`.evidence.tar.gz\` holds the build's package list, CIS scan report and serial log."
  echo
  if [[ -z "${base}" ]]; then
    echo "## Package changes"
    echo
    echo "There's no earlier \`v0.YYYYMMDD.N\` release to compare with."
  else
    echo "## Package changes since ${base}"
    for i in ${order}; do
      image=${images[i]}
      version=${versions[i]}
      echo
      previous=("${work}"/previous/"${image}"-*.evidence.tar.gz)
      if [[ ! -e "${previous[0]}" ]]; then
        echo "${image} is new in this release."
        continue
      fi
      if [[ ${#previous[@]} -ne 1 ]]; then
        echo "ERROR: ${base} has ${#previous[@]} evidence assets for ${image}" >&2
        exit 1
      fi
      packages "${previous[0]}" >"${tmp}/old"
      packages "${work}/current/${image}-${version}-${tag}.evidence.tar.gz" >"${tmp}/new"
      package_diff "${tmp}/old" "${tmp}/new" >"${tmp}/diff"
      updated=$(grep -c '^U' "${tmp}/diff" || true)
      added=$(grep -c '^A' "${tmp}/diff" || true)
      removed=$(grep -c '^R' "${tmp}/diff" || true)
      summary="${image} (AlmaLinux ${version}): ${updated} updated, ${added} added, ${removed} removed"
      if [[ ! -s "${tmp}/diff" ]]; then
        echo "${image} (AlmaLinux ${version}): no package changes."
        continue
      fi
      echo "<details>"
      echo "<summary>${summary}</summary>"
      echo
      while IFS='|' read -r kind name old new; do
        case "${kind}" in
          U) echo "- \`${name}\` ${old} → ${new}" ;;
          A) echo "- \`${name}\` added: ${new}" ;;
          R) echo "- \`${name}\` removed: ${old}" ;;
        esac
      done <"${tmp}/diff"
      echo
      echo "</details>"
    done
  fi
  echo
  cat "${work}/changes.md"
} >"${work}/notes.md"

joined=$(printf '%s, ' "${titles[@]}")
echo "${tag} · AlmaLinux ${joined%, }" >"${work}/title"
