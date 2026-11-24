#!/bin/bash
# Decide whether this run of the release workflow releases, and why.
# Usage: release-plan.sh < published-releases
#
# stdin: one line per published, non-pre-release release, "<tag> <published_at>"
# (an ISO 8601 UTC time, as GitHub gives it; without one, the tag's date
# stands in). Any order; tags outside the v0.<YYYYMMDD>.<patch> scheme are
# ignored. The latest of them is the base every check compares against.
#
# Environment:
#   RELEASE_EVENT   the workflow's event: schedule, push or workflow_dispatch
#   RELEASE_REF     the ref it runs on, such as refs/heads/main
#   RELEASE_REASON  the reason given for a manual run
#   RELEASE_TODAY   YYYYMMDD to plan for (default: today, UTC), for testing
#   GITHUB_OUTPUT   where the result goes (default: stdout)
#
# It releases when any of these holds:
#   - scheduled: no release published on or after the latest first or third
#     Monday of a month. (Published, not tagged: a run planned before a Monday
#     may finish after it.) The workflow runs daily, so a Monday run that
#     GitHub drops, or that fails, is retried the next day.
#   - a template's source ISO differs from the base's, by checksum: the same
#     file at a new URL (such as after a move to vault) isn't a new ISO.
#   - first: no release in this scheme exists yet.
#   - manual: a manual run always releases. Off main, it makes a pre-release,
#     and the other checks are skipped.
#
# The commit being released must descend from the base. A re-run keeps its
# run's commit but plans again for today, so re-running an old run would
# otherwise release old code under today's version. That fails the plan,
# except on a push, where an older commit just means a later release already
# covers it.
#
# Output: release, prerelease (true/false), date (YYYYMMDD), base (a tag, or
# empty) and reasons (one per line). Needs the base's tag in the local clone.

set -eu -o pipefail

cd "$(dirname "$0")/.."

event=${RELEASE_EVENT:-}
ref=${RELEASE_REF:-}
today=${RELEASE_TODAY:-$(date -u +%Y%m%d)}
out=${GITHUB_OUTPUT:-/dev/stdout}

if [[ ! "${today}" =~ ^[1-9][0-9]{7}$ ]]; then
  echo "ERROR: RELEASE_TODAY must be YYYYMMDD, not '${today}'" >&2
  exit 2
fi

months=(January February March April May June July August September October November December)

# Day of the week, 0 = Sunday (Sakamoto's method). Plain arithmetic rather than
# date -d, which BSD date (macOS) doesn't have.
weekday() {
  local y=$1 m=$2 d=$3
  local t=(0 3 2 5 0 3 5 1 4 6 2 4)
  if ((m < 3)); then
    y=$((y - 1))
  fi
  echo $(((y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7))
}

# The first and third Mondays of a month, as YYYYMMDD.
release_mondays() {
  local y=$1 m=$2 first
  first=$((1 + (8 - $(weekday "${y}" "${m}" 1)) % 7))
  printf '%04d%02d%02d %04d%02d%02d\n' "${y}" "${m}" "${first}" "${y}" "${m}" $((first + 14))
}

# "first Monday of December 2026", for a YYYYMMDD that is one.
describe_monday() {
  local d=$((10#${1:6:2})) m=$((10#${1:4:2}))
  local nth=first
  if ((d > 7)); then
    nth=third
  fi
  echo "${nth} Monday of ${months[m - 1]} ${1:0:4}"
}

y=$((10#${today:0:4}))
m=$((10#${today:4:2}))
read -r first third <<<"$(release_mondays "${y}" "${m}")"
if ((today >= third)); then
  last_monday=${third}
elif ((today >= first)); then
  last_monday=${first}
else
  if ((m == 1)); then
    read -r _ last_monday <<<"$(release_mondays $((y - 1)) 12)"
  else
    read -r _ last_monday <<<"$(release_mondays "${y}" $((m - 1)))"
  fi
fi
if ((today < first)); then
  next_monday=${first}
elif ((today < third)); then
  next_monday=${third}
elif ((m == 12)); then
  read -r next_monday _ <<<"$(release_mondays $((y + 1)) 1)"
else
  read -r next_monday _ <<<"$(release_mondays "${y}" $((m + 1)))"
fi

# The latest published release in this scheme, and the UTC day it was
# published.
base_line=$(grep -E '^v0\.[1-9][0-9]{7}\.(0|[1-9][0-9]*)( |$)' | sort -t. -k2,2n -k3,3n | tail -n 1 || true)
base=${base_line%% *}
base_day=$(cut -d. -f2 <<<"${base}")
published_re=' ([0-9]{4})-([0-9]{2})-([0-9]{2})T'
if [[ "${base_line}" =~ ${published_re} ]]; then
  base_day="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
fi

reasons=""
stale=""
add_reason() {
  reasons+="${reasons:+$'\n'}$1"
}

prerelease=false
if [[ "${event}" == workflow_dispatch ]]; then
  # One line, whatever was typed: it goes into the release notes.
  reason=$(printf '%s' "${RELEASE_REASON:-}" | tr '\r\n\t' '   ' | sed -E 's/^ +//; s/ +$//')
  if [[ "${ref}" != refs/heads/main ]]; then
    prerelease=true
    reason="${reason:-no reason given} (pre-release from ${ref#refs/*/})"
  fi
  add_reason "Manual: ${reason:-no reason given}"
fi

# "url checksum" for each ISO in a template.
isos() {
  awk -F'"' '
    /^[[:space:]]*iso_url[[:space:]]*=/ { url = $2 }
    /^[[:space:]]*iso_checksum[[:space:]]*=/ { print url, $2 }
  '
}

if [[ "${prerelease}" == true ]]; then
  : # A pre-release is for testing a branch; nothing else is a reason for it.
elif [[ -z "${base}" ]]; then
  add_reason "First release in the v0.YYYYMMDD.N scheme"
elif ! git rev-parse -q --verify "refs/tags/${base}^{commit}" >/dev/null; then
  echo "ERROR: the latest release's tag, ${base}, isn't in this clone (fetch it with its history)" >&2
  exit 1
elif ! git merge-base --is-ancestor "refs/tags/${base}^{commit}" HEAD; then
  head=$(git rev-parse --short HEAD)
  if [[ "${event}" != push ]]; then
    echo "ERROR: this run's commit, ${head}, doesn't descend from the latest release, ${base}." >&2
    echo "A re-run of an old run would release old code under today's version; start a new run instead." >&2
    exit 1
  fi
  stale="this run's commit, ${head}, is older than the latest release, ${base}, which covers it"
else
  if ((base_day < last_monday)); then
    add_reason "Scheduled: $(describe_monday "${last_monday}")"
  fi

  for template in *.pkr.hcl; do
    now=$(isos <"${template}")
    [[ -n "${now}" ]] || continue
    # Empty when the template is newer than the base (a new image).
    was=$(git show "refs/tags/${base}:${template}" 2>/dev/null | isos || true)
    [[ "$(cut -d' ' -f2 <<<"${now}")" != "$(cut -d' ' -f2 <<<"${was}")" ]] || continue
    now_iso=$(awk '{ n = split($1, p, "/"); printf "%s%s", sep, p[n]; sep = ", " }' <<<"${now}")
    was_iso=$(awk '{ n = split($1, p, "/"); printf "%s%s", sep, p[n]; sep = ", " }' <<<"${was}")
    if [[ -z "${was}" ]]; then
      add_reason "Source ISO changed: ${template%.pkr.hcl} is new, from ${now_iso}"
    elif [[ "${now_iso}" == "${was_iso}" ]]; then
      add_reason "Source ISO changed: ${template%.pkr.hcl}'s ${now_iso} has a new checksum"
    else
      add_reason "Source ISO changed: ${template%.pkr.hcl} now installs from ${now_iso} (was ${was_iso})"
    fi
  done
fi

release=false
if [[ -n "${reasons}" ]]; then
  release=true
fi

{
  echo "Base: ${base:-none}${base:+, published ${base_day}}. Latest release Monday: ${last_monday}. Next: ${next_monday}."
  if [[ -n "${stale}" ]]; then
    echo "Nothing to release: ${stale}."
  elif [[ "${release}" == true ]]; then
    echo "Releasing (pre-release: ${prerelease}):"
    while IFS= read -r line; do
      echo "  - ${line}"
    done <<<"${reasons}"
  else
    echo "Nothing to release. The next scheduled release is on the $(describe_monday "${next_monday}")."
  fi
} >&2

# A random delimiter, so a reason can't end the value early.
delimiter="EOF_$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
{
  echo "release=${release}"
  echo "prerelease=${prerelease}"
  echo "date=${today}"
  echo "base=${base}"
  echo "reasons<<${delimiter}"
  if [[ -n "${reasons}" ]]; then
    echo "${reasons}"
  fi
  echo "${delimiter}"
} >>"${out}"
