#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")"/common.sh

shopt -s nullglob

usage() {
  log "Usage: $0 ORG ACTIVITY_REPO MEMBER_REPO DIR NOTICE_CUTOFF CLOSE_CUTOFF CONFIRM_CUTOFF"
  log ""
  log "Optionally set CACHE_FILE to a path for persisting activity observations between runs."
  exit 1
}

ORG=${1:-$(usage)}
ACTIVITY_REPO=${2:-$(usage)}
MEMBER_REPO=${3:-$(usage)}
DIR=${4:-$(usage)}
NOTICE_CUTOFF=${5:-$(usage)}
CLOSE_CUTOFF=${6:-$(usage)}
CONFIRM_CUTOFF=${7:-$(usage)}

mainBranch=$(git branch --show-current)
noticeCutoff=$(date --date="$NOTICE_CUTOFF" +%s)

nowEpoch=$(date +%s)

# People that received the commit bit after this date won't be retired
newCutoff=$(date --date="1 year ago" +%s)
# Users whose retirement PRs were closed after this date won't be retired
closeCutoff=$(date --date="$CLOSE_CUTOFF" +%s)
# Users first observed as inactive after this date won't be retired yet;
# they keep being checked until the observation is old enough.
# This prevents a single spurious empty response from the /commits endpoint
# from causing an accidental retirement PR (see issue #100).
confirmCutoff=$(date --date="$CONFIRM_CUTOFF" +%s)

# People are considered active if they merged a PR after this date
yearAgo=$(date --date='1 year ago' +%s)
# Cached merges newer than this are trusted without querying GitHub again.
# The gap until the 1-year mark means the /commits endpoint gets queried
# for about a month of daily runs before a retirement PR can be opened,
# so a retirement is backed by many independent queries agreeing.
queryCutoff=$(date --date='11 months ago' +%s)

# We need to know when people received their commit bit to avoid retiring them within the first year.
# For now this is done either with the git creation date of the file, or its contents:
#
# | commit bit reception date  | file creation date | file contents  |
# | -------------------------- | ------------------ | -------------- |
# | A)         -∞ - 2024-10-06 | 2025-07-16         | empty          |
# | B) 2024-10-07 - 2025-04-22 | 2025-07-16         | reception date |
# | C) 2025-08-13 - ∞          | reception date     | empty          |
#
# After 2026-04-23 (one year after C started), the file creation date
# for all first-year committers will match the reception date,
# while everybody else will have been a committer for more than one year.
# This means the code can then be simplified to just
# check if the file creation date is in the last year.
#
# For now however, the code needs to check if the file creation date
# is before 2025-07-17 to distinguish between periods A and C,
# so we hardcode that date for the code to use.
createdOnReceptionEpoch=$(date --date=2025-07-17 +%s)

if [[ -z "${PROD:-}" ]]; then
  tmp=$(git rev-parse --show-toplevel)/.tmp
  rm -rf "$tmp"
  mkdir "$tmp"
  log -e "\e[33mPROD=1 is not set, skipping effects and keeping temporary files in $tmp until the next run\e[0m"
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' exit
fi

# Activity observed by previous runs, so that the unreliable /commits
# endpoint doesn't need to be trusted on a single response (see issue #100).
# The cache only holds positive evidence (merges the API actually returned)
# plus the time somebody was first observed as inactive,
# so a spurious empty response can never make a cached-active user look inactive.
# Bump this version to invalidate all previously cached data.
cacheVersion=1
declare -A cachedMergeEpoch cachedMergePr cachedFirstInactive
if [[ -n "${CACHE_FILE:-}" ]]; then
  CACHE_FILE=$(realpath -m -- "$CACHE_FILE")
  if [[ -f "$CACHE_FILE" ]] && [[ $(head -n 1 "$CACHE_FILE") == "# retire-cache v$cacheVersion" ]]; then
    while IFS=, read -r cLogin cMergeEpoch cMergePr cFirstInactive; do
      [[ "$cLogin" == '#'* ]] && continue
      cachedMergeEpoch[$cLogin]=$cMergeEpoch
      cachedMergePr[$cLogin]=$cMergePr
      cachedFirstInactive[$cLogin]=$cFirstInactive
    done < "$CACHE_FILE"
    log "Loaded activity cache with ${#cachedMergeEpoch[@]} entries from $CACHE_FILE"
  else
    log "No usable activity cache at $CACHE_FILE, starting fresh"
  fi
fi

# Matches the merge lines produced by the jq filter below,
# capturing the merge date and PR number for the cache
mergeLineRegex='^- `([^`]+)` .*(#[0-9]+)$'

mkdir -p "$DIR"
cd "$DIR"
for login in *; do

  # Figure out when this person received the commit bit
  # Get the unix epoch of the last commit that added this file
  # --first-parent is important to get the time of when the main branch was changed
  fileCommitEpoch=$(git log \
    --first-parent \
    --no-follow \
    --diff-filter=A \
    --max-count=1 \
    --format=%cd \
    --date=unix \
    -- "$login")
  if (( fileCommitEpoch < createdOnReceptionEpoch )); then
    # If it was created before creation actually matched the reception date
    # This branch can be removed after 2026-04-23

    if [[ -s "$login" ]]; then
      # If the file is non-empty it indicates an explicit reception date
      receptionEpoch=$(date --date="$(<"$login")" +%s)
    else
      # Otherwise they received the commit bit more than a year ago (start of unix epoch, 1970)
      receptionEpoch=0
    fi
  else
    # Otherwise creation matches reception
    receptionEpoch=$fileCommitEpoch
  fi

  # Latest retirement PR, whether draft, open or closed
  branchName=retire-$login
  prInfo=$(trace gh api -X GET /repos/"$ORG"/"$MEMBER_REPO"/pulls \
    -f state=all \
    -f head="$ORG":"$branchName" \
    --jq '.[0]')
  if [[ -n "$prInfo" ]]; then
    prState=$(jq -r .state <<< "$prInfo")
  else
    prState=none
  fi

  if [[ "$prState" == closed ]] && resetEpoch=$(jq '.closed_at | fromdateiso8601' <<< "$prInfo") && (( closeCutoff < resetEpoch )); then
    log "$login had a retirement PR that was closed recently, skipping retirement check"
    continue
  fi

  # If the commit bit was received after the cutoff date, don't retire in any case
  if (( newCutoff < receptionEpoch )); then
    log "$login became a committer less than 1 year ago, skipping retirement check"
    continue
  fi

  # What previous runs observed about this person's merge activity
  mergeEpoch=${cachedMergeEpoch[$login]:-0}
  mergePr=${cachedMergePr[$login]:-}
  firstInactive=${cachedFirstInactive[$login]:-0}

  : > "$tmp/$login"
  mergeCount=0
  queried=
  if [[ "$prState" != open ]] && (( mergeEpoch > queryCutoff )); then
    # Recent cached activity already rules out retirement,
    # no need to bother the unreliable /commits endpoint
    :
  else
    queried=1
    if [[ "$prState" == open ]]; then
      # The PR comment lists activity from the whole past year
      sinceEpoch=$yearAgo
    else
      # Otherwise only merges newer than the cached one are of interest
      sinceEpoch=$(( mergeEpoch > yearAgo ? mergeEpoch + 1 : yearAgo ))
    fi
    PR_PREFIX="$ORG/$ACTIVITY_REPO" \
    trace gh api -X GET /repos/"$ORG"/"$ACTIVITY_REPO"/commits \
      -f since="$(date --date=@"$sinceEpoch" --iso-8601=seconds)" \
      -f author="$login" \
      -f committer=web-flow \
      -f per_page=100 \
      --jq '.[] |
        # PR merge commits have two parents. We also check it’s an
        # authentic GitHub commit, because… why not?
        select((.parents | length) == 2 and .commit.verification.verified) |
        (.commit.message | capture(" \\((?<pr>#[0-9]+)\\)$").pr) as $pr |
        "- `\(.commit.committer.date)` – \(env.PR_PREFIX)\($pr)"' \
      > "$tmp/$login"
    mergeCount=$(wc -l <"$tmp/$login")
  fi

  if (( mergeCount > 0 )); then
    # Cache the newest merge (first line, the endpoint returns newest first)
    if [[ $(head -n 1 "$tmp/$login") =~ $mergeLineRegex ]]; then
      newestMergeEpoch=$(date --date="${BASH_REMATCH[1]}" +%s)
      if (( newestMergeEpoch > mergeEpoch )); then
        mergeEpoch=$newestMergeEpoch
        mergePr=${BASH_REMATCH[2]}
      fi
    fi
    firstInactive=0
  elif [[ -n "$queried" ]] && (( firstInactive == 0 )); then
    # An empty response might just be a timeout of the endpoint (issue #100),
    # so this only starts the inactivity clock; retirement additionally needs
    # all queries until the confirmation cutoff to keep coming back empty
    firstInactive=$nowEpoch
  fi

  # Remember the observations for the cache written at the end of the run
  cachedMergeEpoch[$login]=$mergeEpoch
  cachedMergePr[$login]=$mergePr
  cachedFirstInactive[$login]=$firstInactive

  if [[ "$prState" == open ]]; then
    if (( mergeCount == 0 && mergeEpoch > yearAgo )); then
      # The query came back empty even though the cache proves activity
      # (issue #100), so reconstruct the activity list from the cache
      echo "- \`$(date --date=@"$mergeEpoch" --iso-8601=seconds)\` – $ORG/$ACTIVITY_REPO$mergePr" > "$tmp/$login"
      mergeCount=1
    fi
    # If there is an open PR already
    prNumber=$(jq .number <<< "$prInfo")
    epochCreatedAt=$(jq '.created_at | fromdateiso8601' <<< "$prInfo")
    if jq -e .draft <<< "$prInfo" >/dev/null && (( epochCreatedAt < noticeCutoff )); then
      log "$login has a retirement PR due, unmarking PR as draft and commenting with next steps"
      effect gh pr ready --repo "$ORG/$MEMBER_REPO" "$prNumber"
      {
        if (( mergeCount > 0 )); then
          echo "One month has passed, and @$login has been active again:"
          cat "$tmp/$login"
          echo ""
          echo "If still appropriate, this PR may be merged and implemented by:"
        else
          echo "One month has passed, so this PR should now be merged and implemented by:"
        fi
        echo "- Adding @$login to the [Retired Nixpkgs Contributors team](https://github.com/orgs/NixOS/teams/retired-nixpkgs-contributors)"
        echo '  ```sh'
        echo '  gh api \'
        echo '    --method PUT \'
        echo "    '/orgs/NixOS/teams/retired-nixpkgs-contributors/memberships/$login' \\"
        echo '    -f role=member'
        echo '  ```'
        echo "- Removing @$login from the [Nixpkgs Committers team](https://github.com/orgs/NixOS/teams/nixpkgs-committers)"
        echo '  ```sh'
        echo '  gh api \'
        echo '    --method DELETE \'
        echo "    '/orgs/NixOS/teams/nixpkgs-committers/memberships/$login'"
        echo '  ```'
      } | effect gh api --method POST /repos/"$ORG"/"$MEMBER_REPO"/issues/"$prNumber"/comments -F "body=@-" >/dev/null
    else
      log "$login has a retirement PR pending"
    fi
  elif (( mergeEpoch > yearAgo )); then
    if (( mergeCount > 0 )); then
      log "$login is active with $mergeCount new merges"
    else
      log "$login is active, last known merge $mergePr on $(date --date=@"$mergeEpoch" --iso-8601=seconds) (cached)"
    fi
  elif (( firstInactive > confirmCutoff )); then
    log "$login appears inactive since $(date --date=@"$firstInactive" --iso-8601=seconds), continuing to check before opening a PR"
  else
    log "$login has become inactive, opening a PR"
    # If there is no PR yet, but they have become inactive
    (
      trace git switch -C "$branchName"
      trap 'trace git checkout "$mainBranch" && trace git branch -D "$branchName"' exit
      trace git rm "$login"
      trace git commit -m "Automatic retirement of @$login"
      effect git push -f -u origin "$branchName"
      prNumber=$({
        echo "This is an automated PR to retire @$login as a Nixpkgs committer because they have not used their commit access in the past year."
        echo ""
        echo "@$login: You can make a comment stating why you believe your commit access should be kept. Otherwise, this PR will be merged and implemented in one month."
        echo ""
        echo "> [!NOTE]"
        echo -n "> Commit access is not required for most forms of contributing, including being a maintainer and reviewing PRs."
        echo ' It is only needed for things that require `write` permissions to Nixpkgs, such as merging PRs.'
      } | effect gh api \
        --method POST \
        /repos/"$ORG"/"$MEMBER_REPO"/pulls \
         -f "title=Automatic retirement of @$login" \
         -F "body=@-" \
         -f "head=$ORG:$branchName" \
         -f "base=$mainBranch" \
         -F "draft=true" \
         --jq .number
      )

      effect gh api \
        --method POST \
        /repos/"$ORG"/"$MEMBER_REPO"/issues/"$prNumber"/labels \
        -f "labels[]=retirement" >/dev/null
    )
  fi
  log ""
done

if [[ -n "${CACHE_FILE:-}" ]]; then
  mkdir -p "$(dirname -- "$CACHE_FILE")"
  {
    echo "# retire-cache v$cacheVersion"
    for login in *; do
      echo "$login,${cachedMergeEpoch[$login]:-0},${cachedMergePr[$login]:-},${cachedFirstInactive[$login]:-0}"
    done
  } > "$CACHE_FILE".tmp
  mv "$CACHE_FILE".tmp "$CACHE_FILE"
  log "Wrote activity cache to $CACHE_FILE"
fi
