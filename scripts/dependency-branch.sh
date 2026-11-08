#!/usr/bin/env bash
# The steps behind dependency-branch.yml: keep the dependency branch current with main, auto-merge
# Dependabot PRs into it, keep the promotion PR to main open, and merge it and security updates.
#
#   scripts/dependency-branch.sh [--branch updates/dependencies] [--base main] [--dry-run] [--auto-promote] [--window "Sat 10:00-18:00 America/New_York"] [--now 2026-11-07T15:00:00Z]
#
# Runs in a clone whose `origin` is the repo, with `gh` logged in for that repo (GH_TOKEN and
# GH_REPO in the workflow). In the workflow both act as the automation app, the integration
# ruleset's bypass actor (ops ADR-0007), so the sync push is allowed and the PRs it opens get `ci`.
#
# 1. Sync: if origin/<base> isn't an ancestor of origin/<branch>, merge it in and push. That is a
#    fast-forward when the branch isn't ahead, so it can't conflict. A conflicting merge is
#    abandoned and remembered.
# 2. Auto-merge: every open PR into <branch> by Dependabot that has no auto-merge and whose `ci`
#    hasn't finished gets it, as a merge commit, majors included. One whose `ci` is green and that
#    is mergeable (CLEAN) is merged directly, because GitHub refuses auto-merge on it. One whose
#    `ci` is red is left for a person. The script reads `ci` itself rather than trusting GitHub to
#    hold the merge back: the app is a bypass actor on <branch>.
# 3. Promotion PR: while the synced branch differs in content from <base>, a PR <branch> -> <base>
#    is kept open, its body listing the Dependabot PRs merged into <branch> since <base> last
#    contained it, and ending in the hold reasons when step 4 holds. After a conflicting sync it
#    gets one comment per <base> commit, with the steps to resolve the conflict.
# 4. Promote: the promotion PR is merged (merge commit) when no guard holds. Every guard that
#    fails is recorded, in this order: opted-out (no --auto-promote), conflict, major (a Dependabot
#    commit in <base>..HEAD bumps a major, or has no update metadata), ci-red, unsettled (an open
#    Dependabot PR into <branch> whose `ci` isn't red), ci-pending (`ci` unfinished, or the PR head
#    isn't HEAD), outside-window (left out when opted-out). The PR body carries the reasons as
#    `<!-- dependency-branch:hold <reason>... -->` for the digest.
# 5. Security: every open Dependabot PR into <base> is merged (merge commit) when none of
#    opted-out, major, ci-red, ci-pending, outside-window holds. A PR with no Dependabot commit
#    has no update metadata at all, so it counts as major too.
#
# The window is `<Day> <HH:MM>-<HH:MM> <IANA zone>`, start inclusive, end exclusive, within one day.
# --now (ISO-8601 UTC, default the current time) is for the self-test. A malformed window or --now
# exits 2.
#
# Prints the action list on stdout, one line per action:
#   sync none|fast-forward|merge|conflict
#   push <branch>
#   auto-merge <n>      merge <n>      red <n>
#   promotion-pr none|create|update <n>|keep <n>
#   conflict-comment <n>|new [exists]
#   promote <n>         hold <n> <reason>...
#   security-merge <n>  security-hold <n> <reason>...
# Everything else goes to stderr. --dry-run decides every action the way a real run would,
# including whether the sync conflicts (git merge-tree, which leaves the worktree alone), and makes
# no push and no gh write. gh reads still run. The checkout is left detached at the synced commit.
set -euo pipefail

BRANCH=updates/dependencies
BASE=main
DRY_RUN=false
AUTO_PROMOTE=false
WINDOW='Sat 10:00-18:00 America/New_York'
NOW=
PROMOTION_TITLE='chore(deps): promote dependency updates'
DEPENDABOT=app/dependabot
# The author name on the commits Dependabot makes.
DEPENDABOT_AUTHOR='dependabot[bot]'
CONFLICT_MARKER=dependency-branch:sync-conflict
HOLD_MARKER=dependency-branch:hold

# jq definitions shared by the queries below.
# shellcheck disable=SC2016 # jq variables, not shell ones.
JQ_DEFS='
  # The latest `ci` result: a check run reports a conclusion once it finishes, a commit status a
  # state. No `ci` yet, or one still running, is PENDING.
  def ci_state:
    ([.statusCheckRollup[]? | select((.name // .context) == "ci")] | last)
    | if . == null then "PENDING"
      else ((.conclusion // "") as $c | if $c != "" then $c else (.state // "PENDING") end) end;
  # Why a Dependabot commit message makes the batch major, or empty when it does not. Missing or
  # incomplete update metadata counts as major.
  def major_reason:
    if test("(^|\n)updated-dependencies:") | not then "no updated-dependencies metadata"
    elif ([scan("(^|\n)[ \t-]*update-type:")] | length)
      < ([scan("(^|\n)[ \t-]*dependency-name:")] | length) then "an update without update-type"
    elif test("update-type: version-update:semver-major") then "semver-major"
    else empty end;
'

usage() {
  sed -n '5p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
  exit 2
}
fatal() {
  echo "::error title=dependency-branch::$*" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --branch) BRANCH=${2:?--branch needs a value}; shift 2 ;;
    --base) BASE=${2:?--base needs a value}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --auto-promote) AUTO_PROMOTE=true; shift ;;
    --window) WINDOW=${2:?--window needs a value}; shift 2 ;;
    --now) NOW=${2:?--now needs a value}; shift 2 ;;
    *) usage ;;
  esac
done

log() { echo "$*" >&2; }
action() { echo "$*"; }
warn() { echo "::warning title=dependency-branch::$*" >&2; }
# Runs a write (push, gh write), or only logs it under --dry-run.
write() {
  if [[ $DRY_RUN == true ]]; then
    log "dry run, skipped: $1 $2 ..."
    return 0
  fi
  "$@"
}

# Open PRs into $1, or only from head $2 when given, in the shape `gh pr list --json` gives them.
# The query is written out rather than left to `gh pr list --json statusCheckRollup`, because
# gh's own rollup query asks for checkSuite.workflowRun, which needs the Actions: read permission
# the app doesn't have (it fails with "Resource not accessible by integration").
# shellcheck disable=SC2016 # GraphQL variables, not shell ones.
PR_QUERY='
query($owner: String!, $name: String!, $base: String!, $head: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(baseRefName: $base, headRefName: $head, states: OPEN, first: 100) {
      nodes {
        number body headRefOid mergeStateStatus
        author { __typename login }
        autoMergeRequest { enabledAt }
        commits(last: 100) { nodes { commit { oid messageBody authors(first: 10) { nodes { name } } } } }
        head: commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { name status conclusion }
          ... on StatusContext { context state }
        } } } } } }
      }
    }
  }
}'
open_prs_into() {
  local args=(-H 'Accept: application/vnd.github.merge-info-preview+json' -f query="$PR_QUERY"
    -F owner='{owner}' -F name='{repo}' -f base="$1")
  if [[ -n ${2:-} ]]; then args+=(-f head="$2"); fi
  # gh shows a bot author as app/<login>.
  gh api graphql "${args[@]}" | jq '[.data.repository.pullRequests.nodes[] | {
    number, body, headRefOid, mergeStateStatus, autoMergeRequest,
    author: {login: (if .author.__typename == "Bot" then "app/\(.author.login)" else .author.login end)},
    commits: [.commits.nodes[].commit | {oid, messageBody, authors: .authors.nodes}],
    statusCheckRollup: (.head.nodes[0].commit.statusCheckRollup.contexts.nodes // [])
  }]'
}

# Adds a hold reason to $reasons, a space-separated list.
hold_reason() { reasons="${reasons:+$reasons }$1"; }

# --- The window ------------------------------------------------------------------

day_re='(Mon|Tue|Wed|Thu|Fri|Sat|Sun)'
time_re='([01][0-9]|2[0-3]):([0-5][0-9])'
if ! [[ $WINDOW =~ ^$day_re\ $time_re-$time_re\ ([A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*)$ ]]; then
  fatal "malformed window '$WINDOW': expected '<Day> <HH:MM>-<HH:MM> <IANA zone>', e.g. 'Sat 10:00-18:00 America/New_York'"
fi
window_day=${BASH_REMATCH[1]}
window_start=$((10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
window_end=$((10#${BASH_REMATCH[4]} * 60 + 10#${BASH_REMATCH[5]}))
window_zone=${BASH_REMATCH[6]}
if [[ $window_start -ge $window_end ]]; then
  fatal "malformed window '$WINDOW': the start must be before the end, within one day"
fi
# TZ falls back to UTC for a zone it doesn't know, so check the zone database instead.
if [[ ! -f /usr/share/zoneinfo/$window_zone ]]; then
  fatal "unknown time zone '$window_zone' in window '$WINDOW'"
fi
if [[ -n $NOW ]]; then
  now_epoch=$(jq -n --arg now "$NOW" '$now | fromdateiso8601' 2>/dev/null) ||
    fatal "malformed --now '$NOW': expected an ISO-8601 UTC instant, e.g. 2026-11-07T15:00:00Z"
else
  now_epoch=$(jq -n 'now | floor')
fi
# The weekday (Sun = 0) and minute of the day, in the window's zone.
read -r now_wday now_minute < <(TZ=$window_zone jq -nr --argjson t "$now_epoch" \
  '$t | localtime | "\(.[6]) \(.[3] * 60 + .[4])"')
days=(Sun Mon Tue Wed Thu Fri Sat)
in_window=false
if [[ ${days[$now_wday]} == "$window_day" && $now_minute -ge $window_start && $now_minute -lt $window_end ]]; then
  in_window=true
fi
log "Now is $(TZ=$window_zone jq -nr --argjson t "$now_epoch" '$t | localtime | strftime("%a %H:%M")') in $window_zone: $(
  [[ $in_window == true ]] && echo inside || echo outside) the window $WINDOW."

# --- 1. Sync ---------------------------------------------------------------

git fetch --quiet origin \
  "+refs/heads/$BASE:refs/remotes/origin/$BASE" \
  "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
git checkout --quiet --detach "origin/$BRANCH"

base_sha=$(git rev-parse "origin/$BASE")
conflict=false

if git merge-base --is-ancestor "origin/$BASE" HEAD; then
  log "$BRANCH already contains $BASE ($base_sha)."
  action "sync none"
elif git merge-base --is-ancestor HEAD "origin/$BASE"; then
  log "$BRANCH is behind $BASE and not ahead: fast-forwarding to $base_sha."
  action "sync fast-forward"
  git merge --quiet --ff-only "origin/$BASE"
  action "push $BRANCH"
  write git push --quiet origin "HEAD:refs/heads/$BRANCH"
else
  # Exit 1 is a conflict; anything above 1 is an error.
  status=0
  merged_tree=$(git merge-tree --write-tree --name-only HEAD "origin/$BASE") || status=$?
  if [[ $status -eq 0 ]]; then
    log "$BRANCH is behind and ahead of $BASE: merging $base_sha in."
    action "sync merge"
    if [[ $DRY_RUN == true ]]; then
      # The commit a real run would make, so the content check below sees the merged tree.
      merge_commit=$(git commit-tree -p HEAD -p "origin/$BASE" -m "dry run" "${merged_tree%%$'\n'*}")
      git checkout --quiet --detach "$merge_commit"
    else
      git merge --quiet --no-ff -m "chore(deps): merge $BASE into $BRANCH" "origin/$BASE"
    fi
    action "push $BRANCH"
    write git push --quiet origin "HEAD:refs/heads/$BRANCH"
  elif [[ $status -eq 1 ]]; then
    log "Merging $BASE ($base_sha) into $BRANCH conflicts in:"
    log "$(sed '1d;/^$/,$d' <<<"$merged_tree")"
    action "sync conflict"
    conflict=true
  else
    log "git merge-tree failed (exit $status): $merged_tree"
    exit 1
  fi
fi

# --- 2. Auto-merge Dependabot PRs into the branch -----------------------------

open_prs=$(open_prs_into "$BRANCH")
while IFS=$'\t' read -r number merge_state ci; do
  [[ -n $number ]] || continue
  case $ci in
    SUCCESS | PENDING) ;;
    *)
      log "#$number: ci is $ci, so it stays open for a person."
      action "red $number"
      continue
      ;;
  esac
  if [[ $ci == SUCCESS && $merge_state == CLEAN ]]; then
    action "merge $number"
    write gh pr merge --merge "$number" || warn "couldn't merge #$number; the next run tries again."
  else
    action "auto-merge $number"
    write gh pr merge --auto --merge "$number" ||
      warn "couldn't enable auto-merge on #$number; the next run tries again."
  fi
done < <(jq -r --arg bot "$DEPENDABOT" "$JQ_DEFS"'
  sort_by(.number)[]
  | select(.author.login == $bot and .autoMergeRequest == null)
  | [.number, .mergeStateStatus, ci_state] | @tsv
' <<<"$open_prs")

# --- 3. Promotion PR, with step 4's decision ---------------------------------------

promotion=$(open_prs_into "$BASE" "$BRANCH")
promotion_number=$(jq -r '.[0].number // empty' <<<"$promotion")
# Step 4's hold reasons, decided here so the body written below carries them.
reasons=
promotion_needed=false

if git diff --quiet "origin/$BASE" HEAD; then
  log "$BRANCH has the same content as $BASE: no promotion PR needed."
  action "promotion-pr none"
else
  promotion_needed=true
  # Dependabot PRs whose merge commit is on the branch but not yet in the base.
  unpromoted=$(git rev-list "origin/$BASE..HEAD" | jq -R . | jq -s .)
  merged_prs=$(gh pr list --base "$BRANCH" --state merged --limit 200 \
    --json number,title,author,mergeCommit)
  list=$(jq -r --arg bot "$DEPENDABOT" --argjson unpromoted "$unpromoted" '
    sort_by(.number)[]
    | select(.author.login == $bot and (.mergeCommit.oid as $oid | $unpromoted | index($oid)))
    | "- #\(.number) \(.title)"
  ' <<<"$merged_prs")
  body="Promotes \`$BRANCH\` into \`$BASE\`. The dependency-branch workflow keeps this PR open while the two differ in content. Merge it with a merge commit.

Dependabot PRs merged into \`$BRANCH\` since \`$BASE\` last contained it:

${list:-"- none: the difference is commits made by hand"}"

  # --- 4. The promotion guards, every failing one recorded, in a fixed order ---
  [[ $AUTO_PROMOTE == true ]] || hold_reason opted-out
  if [[ $conflict == true || $(jq -r '.[0].mergeStateStatus // ""' <<<"$promotion") == DIRTY ]]; then
    hold_reason conflict
  fi
  # The batch: the Dependabot commits the merged Dependabot PRs brought in, merges excluded.
  major_commits=$(git log -z --no-merges --format='%H%x1f%an%x1f%B' "origin/$BASE..HEAD" |
    jq -r -R -s --arg author "$DEPENDABOT_AUTHOR" "$JQ_DEFS"'
      split("\u0000")[] | select(length > 0) | split("\u001f")
      | select(.[1] == $author) | (.[2] | major_reason) as $why | "\(.[0][0:7]): \($why)"')
  if [[ -n $major_commits ]]; then
    log "The batch is major:"
    log "$major_commits"
    hold_reason major
  fi
  promotion_ci=$(jq -r "$JQ_DEFS"'.[0] // {} | ci_state' <<<"$promotion")
  case $promotion_ci in
    SUCCESS | PENDING) ;;
    *) log "ci on the promotion PR is $promotion_ci."; hold_reason ci-red ;;
  esac
  unsettled=$(jq -r --arg bot "$DEPENDABOT" "$JQ_DEFS"'
    [sort_by(.number)[] | select(.author.login == $bot) | select(ci_state | IN("SUCCESS", "PENDING"))
     | "#\(.number)"] | join(" ")' <<<"$open_prs")
  if [[ -n $unsettled ]]; then
    log "The batch isn't settled: $unsettled still open."
    hold_reason unsettled
  fi
  head_oid=$(jq -r '.[0].headRefOid // ""' <<<"$promotion")
  if [[ $promotion_ci == PENDING || $head_oid != "$(git rev-parse HEAD)" ]]; then
    log "ci on the promotion PR is pending, or its head (${head_oid:-none yet}) isn't $(git rev-parse HEAD)."
    hold_reason ci-pending
  fi
  if [[ $AUTO_PROMOTE == true && $in_window == false ]]; then hold_reason outside-window; fi

  if [[ -n $reasons ]]; then
    body="$body

**Held:** ${reasons// /, }
<!-- $HOLD_MARKER $reasons -->"
  fi
  log "Promotion PR body:"
  log "$body"

  if [[ -z $reasons ]]; then
    # Step 4 merges it, so the body is left as it is.
    action "promotion-pr keep $promotion_number"
  elif [[ -z $promotion_number ]]; then
    action "promotion-pr create"
    if [[ $DRY_RUN == true ]]; then
      promotion_number=new
    else
      url=$(gh pr create --base "$BASE" --head "$BRANCH" --title "$PROMOTION_TITLE" --body "$body")
      promotion_number=${url##*/}
      log "Opened $url"
    fi
  elif [[ $(jq -r '.[0].body' <<<"$promotion") != "$body" ]]; then
    action "promotion-pr update $promotion_number"
    write gh pr edit "$promotion_number" --body "$body"
  else
    action "promotion-pr keep $promotion_number"
  fi
fi

# --- Conflict comment ----------------------------------------------------------

if [[ $conflict == true ]]; then
  marker="<!-- $CONFLICT_MARKER $BASE=$base_sha -->"
  if [[ -z $promotion_number ]]; then
    # Only when the branch has the base's content but not its history, which a conflict rules out.
    warn "the sync conflicted but there is no promotion PR to comment on."
  elif [[ $promotion_number != new ]] &&
    gh pr view "$promotion_number" --json comments |
    jq -e --arg marker "$marker" 'any(.comments[]; .body | contains($marker))' >/dev/null; then
    log "#$promotion_number already has the conflict comment for $base_sha."
    action "conflict-comment $promotion_number exists"
  else
    action "conflict-comment $promotion_number"
    comment="$marker
**\`$BASE\` doesn't merge cleanly into \`$BRANCH\`.** The dependency-branch workflow tried to merge \`$BASE\` (\`${base_sha:0:7}\`) in and hit a conflict, so it left \`$BRANCH\` as it was. This PR can't merge until the conflict is resolved. The workflow tries again on every run, and comments again only when \`$BASE\` moves.

Only the automation app can push to \`$BRANCH\`, so resolve the conflict on a branch of your own and merge that in with a PR:

\`\`\`bash
git fetch origin
git switch -c resolve/dependencies-sync origin/$BRANCH
git merge origin/$BASE
# fix the conflicts, then:
git add -A
git commit --no-edit
git push -u origin resolve/dependencies-sync
gh pr create --base $BRANCH --title \"chore(deps): merge $BASE into $BRANCH\" --body \"Resolves the sync conflict.\"
gh pr merge --auto --merge
\`\`\`

Use a **merge commit**, not a squash. The merge commit is what makes \`$BASE\` an ancestor of \`$BRANCH\` again. Once it lands, the next run has nothing to sync and this PR can merge."
    if [[ $promotion_number == new ]]; then
      log "dry run, skipped: comment on the new promotion PR"
    else
      write gh pr comment "$promotion_number" --body "$comment"
    fi
  fi
fi

# --- 4. Promote ------------------------------------------------------------------

if [[ $promotion_needed == true ]]; then
  if [[ -z $reasons ]]; then
    action "promote $promotion_number"
    write gh pr merge --merge "$promotion_number" ||
      warn "couldn't merge the promotion PR #$promotion_number; the next run tries again."
  else
    action "hold $promotion_number $reasons"
  fi
fi

# --- 5. Security updates ---------------------------------------------------------

# Dependabot ignores target-branch for security updates, so they are PRs into the base.
security_prs=$(open_prs_into "$BASE")
while IFS=$'\t' read -r number ci why; do
  [[ -n $number ]] || continue
  reasons=
  [[ $AUTO_PROMOTE == true ]] || hold_reason opted-out
  if [[ -n $why ]]; then
    log "#$number is major: $why"
    hold_reason major
  fi
  case $ci in
    SUCCESS) ;;
    PENDING) hold_reason ci-pending ;;
    *) hold_reason ci-red ;;
  esac
  if [[ $AUTO_PROMOTE == true && $in_window == false ]]; then hold_reason outside-window; fi
  if [[ -z $reasons ]]; then
    action "security-merge $number"
    write gh pr merge --merge "$number" || warn "couldn't merge #$number; the next run tries again."
  else
    action "security-hold $number $reasons"
  fi
done < <(jq -r --arg bot "$DEPENDABOT" --arg author "$DEPENDABOT_AUTHOR" "$JQ_DEFS"'
  sort_by(.number)[]
  | select(.author.login == $bot)
  | [.commits[]? | select(any(.authors[]?; .name == $author))] as $commits
  | (if ($commits | length) == 0 then ["no Dependabot commits"]
     else [$commits[] | .oid[0:7] as $oid | .messageBody | major_reason | "\($oid): \(.)"] end) as $why
  | [.number, ci_state, ($why | join("; "))] | @tsv
' <<<"$security_prs")
