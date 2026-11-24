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
#   RUN_URL            this workflow run's URL, the same for every attempt
#   GITHUB_OUTPUT      where tag=<tag> goes (default: stdout)
#
# Until the publish job replaces them, a draft's notes are "Building in <run
# URL>". That marks the drafts this workflow made, and which run made each:
#   - This run's own draft, from an earlier attempt ("Re-run all jobs", or a
#     re-run of a failed draft job), is reused, so the re-run finishes it.
#   - Another run's draft is left over from a run that failed. Release runs
#     never overlap (see release.yml's concurrency), so it's deleted, with
#     whatever images it holds. Its tag stays: that version stays used.
#
# Otherwise this tags SHA with the next version (release-version.sh), which
# reserves it, and creates the draft. When either fails it deletes a tag it
# just made and tries the next version, a few times: GitHub won't reuse the
# tag name of a deleted immutable release, no longer lists it, and may refuse
# it at either step.

set -eu -o pipefail

cd "$(dirname "$0")/.."

: "${GH_REPO:?}" "${DATE:?}" "${PRERELEASE:?}" "${SHA:?}" "${RUN_URL:?}"
out=${GITHUB_OUTPUT:-/dev/stdout}
marker="Building in ${RUN_URL}"

# "<tag>\t<draft notes>" for each draft this workflow made.
drafts=$(gh api --paginate "repos/${GH_REPO}/releases?per_page=100" \
  --jq '.[] | select(.draft and ((.body // "") | startswith("Building in "))) | [.tag_name, .body] | @tsv')

own=""
while IFS=$'\t' read -r tag body; do
  [[ -n "${tag}" ]] || continue
  if [[ "${body}" == "${marker}" ]]; then
    own=${tag}
  else
    echo "Deleting the draft ${tag}, left by a failed run (${body#Building in }); its tag stays"
    gh release delete "${tag}" --yes </dev/null
  fi
done <<<"${drafts}"

if [[ -n "${own}" ]]; then
  echo "Reusing this run's draft ${own}"
  echo "tag=${own}" >>"${out}"
  exit 0
fi

flags=(--draft --verify-tag --notes "${marker}")
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
  done
  echo "::warning::Couldn't create a release for ${tag}; deleting the tag and trying the next version"
  if ! gh api --method DELETE "repos/${GH_REPO}/git/refs/tags/${tag}" >/dev/null; then
    echo "::warning::Couldn't delete the tag ${tag}"
  fi
done

echo "::error::Couldn't create a draft release for ${DATE}"
exit 1
