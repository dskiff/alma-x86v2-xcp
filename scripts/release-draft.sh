#!/bin/bash
# Find or create the draft release this run of the release workflow builds into,
# and output its tag.
# Usage: release-draft.sh
#
# Environment:
#   GH_REPO, GH_TOKEN  the repository, and a token that can write its contents
#   DATE               the plan's YYYYMMDD
#   PRERELEASE         true or false
#   SHA                the commit to tag
#   BASE               the latest full release when the plan ran, or empty
#   RUN_URL            this workflow run's URL, the same for every attempt
#   GITHUB_OUTPUT      where tag=<tag> goes (default: stdout)
#
# Until the publish job replaces them, a draft's notes are "Building in <run
# URL>". That marks the drafts this workflow made, and which run made each:
#   - This run's own draft, from an earlier attempt ("Re-run all jobs", or a
#     re-run of a failed draft job), is reused, so the re-run finishes it, as
#     long as its tag still points at SHA.
#   - Another run's draft is left over from a run that failed. Release runs
#     never overlap (see release.yml's concurrency), so it's deleted, with
#     whatever images it holds. Its tag stays: that version stays used.
#
# Otherwise this tags SHA with the next version (release-version.sh), which
# reserves it, and creates the draft. When either fails it tries the next
# version, a few times: GitHub won't reuse the tag name of a deleted immutable
# release, no longer lists it, and may refuse it at either step. A failed
# create may still have made the draft (a lost response), so the tag is only
# deleted once the draft is known not to exist.
#
# A new full release also needs the latest release to still be the plan's
# BASE. "Re-run failed jobs" reuses the plan, so without this, retrying an old
# run after a newer release would release the older commit under a higher
# version, past the plan's check that the commit descends from the base.

set -eu -o pipefail

cd "$(dirname "$0")/.."

: "${GH_REPO:?}" "${DATE:?}" "${PRERELEASE:?}" "${SHA:?}" "${RUN_URL:?}"
base=${BASE:-}
out=${GITHUB_OUTPUT:-/dev/stdout}
marker="Building in ${RUN_URL}"

# Tags and notes of the drafts this workflow made: their notes are exactly
# the marker, so a hand-written draft is never touched.
drafts=$(gh api --paginate "repos/${GH_REPO}/releases?per_page=100" \
  --jq '.[] | select(.draft and ((.body // "") | test("^Building in https://\\S+/actions/runs/[0-9]+$"))) | [.tag_name, .body] | @tsv')

own=()
while IFS=$'\t' read -r tag body; do
  [[ -n "${tag}" ]] || continue
  if [[ "${body}" == "${marker}" ]]; then
    own+=("${tag}")
  else
    echo "Deleting the draft ${tag}, left by a failed run (${body#Building in }); its tag stays"
    gh release delete "${tag}" --yes </dev/null
  fi
done <<<"${drafts}"

if ((${#own[@]} > 1)); then
  echo "::error::This run has more than one draft (${own[*]}); delete the extra ones by hand"
  exit 1
fi
if ((${#own[@]} == 1)); then
  tag=${own[0]}
  # Publishing a draft whose tag is gone would tag whatever its target is now.
  if ! points=$(gh api "repos/${GH_REPO}/git/ref/tags/${tag}" --jq .object.sha); then
    echo "::error::This run's draft ${tag} has no tag; delete the draft and start a new run"
    exit 1
  fi
  if [[ "${points}" != "${SHA}" ]]; then
    echo "::error::This run's draft ${tag} is tagged at ${points}, not ${SHA}"
    exit 1
  fi
  echo "Reusing this run's draft ${tag}"
  echo "tag=${tag}" >>"${out}"
  exit 0
fi

if [[ "${PRERELEASE}" == false ]]; then
  latest=$(gh api --paginate "repos/${GH_REPO}/releases?per_page=100" \
    --jq '.[] | select((.draft or .prerelease) | not) | .tag_name' |
    { grep -E '^v0\.[1-9][0-9]{7}\.(0|[1-9][0-9]*)$' || true; } | sort -t. -k2,2n -k3,3n | tail -n 1)
  if [[ "${latest}" != "${base}" ]]; then
    echo "::error::${latest} was published after this run planned against ${base:-no release}; start a new run rather than re-running this one"
    exit 1
  fi
fi

# Whether this run's draft for a tag exists. Fails the script, keeping the
# tag, if that can't be told.
draft_exists() {
  local found
  if ! found=$(gh api --paginate "repos/${GH_REPO}/releases?per_page=100" \
    --jq ".[] | select(.draft and .tag_name == \"$1\" and .body == \"${marker}\") | .tag_name"); then
    echo "::error::Couldn't check whether the draft for $1 was created; its tag stays"
    exit 1
  fi
  [[ -n "${found}" ]]
}

flags=(--draft --verify-tag --target "${SHA}" --notes "${marker}")
if [[ "${PRERELEASE}" == true ]]; then
  flags+=(--prerelease)
fi

taken=$(gh api --paginate "repos/${GH_REPO}/git/matching-refs/tags/v0.${DATE}." \
  --jq '.[].ref | ltrimstr("refs/tags/")')
for _ in 1 2 3; do
  tag=$(scripts/release-version.sh "${DATE}" "${PRERELEASE}" <<<"${taken}")
  taken+=$'\n'"${tag}"

  if ! gh api --method POST "repos/${GH_REPO}/git/refs" \
    -f "ref=refs/tags/${tag}" -f "sha=${SHA}" >/dev/null; then
    echo "::warning::Couldn't create the tag ${tag}; trying the next version"
    continue
  fi
  echo "Tagged ${SHA} as ${tag}"

  # A tag made a moment ago may not be visible to the releases API yet.
  for delay in 0 5 15; do
    sleep "${delay}"
    if gh release create "${tag}" --title "${tag}" "${flags[@]}"; then
      echo "tag=${tag}" >>"${out}"
      exit 0
    fi
    if draft_exists "${tag}"; then
      echo "The draft for ${tag} was created despite the error"
      echo "tag=${tag}" >>"${out}"
      exit 0
    fi
  done
  echo "::warning::Couldn't create a release for ${tag}; deleting the tag and trying the next version"
  if ! gh api --method DELETE "repos/${GH_REPO}/git/refs/tags/${tag}" >/dev/null; then
    echo "::warning::Couldn't delete the tag ${tag}"
  fi
done

echo "::error::Couldn't create a draft release for ${DATE}"
exit 1
