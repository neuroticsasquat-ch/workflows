#!/usr/bin/env bash
# The steps behind dependency-branch.yml: keep the dependency branch current with main, auto-merge
# Dependabot PRs into it, and keep the promotion PR to main open.
#
#   scripts/dependency-branch.sh [--branch updates/dependencies] [--base main] [--dry-run]
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
#    contained it. After a conflicting sync it gets one comment per <base> commit, with the steps
#    to resolve the conflict.
#
# Prints the action list on stdout, one line per action:
#   sync none|fast-forward|merge|conflict
#   push <branch>
#   auto-merge <n>      merge <n>      red <n>
#   promotion-pr none|create|update <n>|keep <n>
#   conflict-comment <n>|new [exists]
# Everything else goes to stderr. --dry-run decides every action the way a real run would,
# including whether the sync conflicts (git merge-tree, which leaves the worktree alone), and makes
# no push and no gh write. gh reads still run. The checkout is left detached at the synced commit.
set -euo pipefail

BRANCH=updates/dependencies
BASE=main
DRY_RUN=false
PROMOTION_TITLE='chore(deps): promote dependency updates'
DEPENDABOT=app/dependabot
CONFLICT_MARKER=dependency-branch:sync-conflict

usage() {
  sed -n '5p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --branch) BRANCH=${2:?--branch needs a value}; shift 2 ;;
    --base) BASE=${2:?--base needs a value}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
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

open_prs=$(gh pr list --base "$BRANCH" --state open --limit 100 \
  --json number,author,autoMergeRequest,mergeStateStatus,statusCheckRollup)
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
done < <(jq -r --arg bot "$DEPENDABOT" '
  sort_by(.number)[]
  | select(.author.login == $bot and .autoMergeRequest == null)
  # The latest `ci` result: a check run reports a conclusion once it finishes, a commit status a
  # state. No `ci` yet, or one still running, is PENDING.
  | ([.statusCheckRollup[]? | select((.name // .context) == "ci")] | last) as $ci
  | ($ci | if . == null then "PENDING" else ((.conclusion // "") as $c | if $c != "" then $c else (.state // "PENDING") end) end) as $ci
  | [.number, .mergeStateStatus, $ci] | @tsv
' <<<"$open_prs")

# --- 3. Promotion PR -----------------------------------------------------------

promotion=$(gh pr list --base "$BASE" --head "$BRANCH" --state open --limit 1 \
  --json number,body)
promotion_number=$(jq -r '.[0].number // empty' <<<"$promotion")

if git diff --quiet "origin/$BASE" HEAD; then
  log "$BRANCH has the same content as $BASE: no promotion PR needed."
  action "promotion-pr none"
else
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
  log "Promotion PR body:"
  log "$body"

  if [[ -z $promotion_number ]]; then
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
