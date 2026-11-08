#!/usr/bin/env bash
# Self-test for scripts/dependency-branch.sh. Each case builds a scratch repo state with git init
# and a local bare remote, runs the script against a clone of it with bin/gh standing in for gh,
# and checks the action list it prints.
#
#   fixtures/dependency-branch/test.sh
#
# The dry-run cases are the three the sync can meet: behind only, ahead and behind with a clean
# merge, and ahead and behind with a conflict. Each also checks that the dry run pushed nothing and
# made no gh write. Two real runs then check that the clean merge lands on the remote and the
# conflict leaves it alone, and that the conflict comment is posted once per base commit.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/../../scripts/dependency-branch.sh
BRANCH=updates/dependencies
export PATH="$HERE/bin:$PATH"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Keep the user's git config (signing, hooks, default branch) out of the scratch repos.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$WORK/gitconfig
git config --global user.name "dependency-branch test"
git config --global user.email "test@example.com"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global advice.detachedHead false

failures=0
fail() {
  echo "::error title=dependency-branch test::$*"
  failures=$((failures + 1))
}

# Open PRs into the branch, the same in every case: a Dependabot PR whose ci is running, one that
# already has auto-merge, one by a person, a Dependabot PR with green ci that is mergeable, one with
# red ci, and one that GitHub calls mergeable but whose ci is red (the app bypasses the ruleset, so
# GitHub's status can't be trusted to hold it back).
OPEN_PRS='[
  {"number": 24, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "CLEAN",
   "statusCheckRollup": [{"__typename": "CheckRun", "name": "lint", "conclusion": "FAILURE"}, {"__typename": "CheckRun", "name": "ci", "conclusion": "SUCCESS"}]},
  {"number": 21, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "BLOCKED",
   "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "status": "IN_PROGRESS", "conclusion": ""}]},
  {"number": 22, "author": {"login": "app/dependabot"}, "autoMergeRequest": {"enabledAt": "2026-11-07T00:00:00Z"}, "mergeStateStatus": "BLOCKED", "statusCheckRollup": []},
  {"number": 23, "author": {"login": "tomboone"}, "autoMergeRequest": null, "mergeStateStatus": "CLEAN", "statusCheckRollup": []},
  {"number": 25, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "BLOCKED",
   "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": "FAILURE"}]},
  {"number": 26, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "CLEAN",
   "statusCheckRollup": [{"__typename": "StatusContext", "context": "ci", "state": "ERROR"}]},
  {"number": 27, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "UNKNOWN", "statusCheckRollup": []}
]'

# new_case <name>: a bare remote whose main and $BRANCH are the same commit, a seed clone to make
# history in, a clone for the script to run in, and the canned gh answers. Leaves cwd in the seed.
new_case() {
  CASE=$WORK/$1
  mkdir -p "$CASE/gh"
  git init --quiet --bare "$CASE/remote.git"
  git clone --quiet "$CASE/remote.git" "$CASE/seed" 2>/dev/null
  cd "$CASE/seed"
  echo one >shared.txt
  git add shared.txt
  git commit --quiet -m "initial"
  git push --quiet origin main
  git push --quiet origin "main:refs/heads/$BRANCH"
  git clone --quiet "$CASE/remote.git" "$CASE/clone"
  echo "$OPEN_PRS" >"$CASE/gh/open.json"
  echo '[]' >"$CASE/gh/promotion.json"
  echo '[]' >"$CASE/gh/merged.json"
  echo '{"comments": []}' >"$CASE/gh/comments.json"
}

# commit_on_main <file> <content>
commit_on_main() {
  git switch --quiet main
  echo "$2" >"$1"
  git add "$1"
  git commit --quiet -m "main: $1"
  git push --quiet origin main
}

# dependabot_merge <file> <content>: a PR branch merged into $BRANCH with a merge commit, the way
# auto-merge lands one. Prints the merge commit.
dependabot_merge() {
  git switch --quiet -c "dependabot/$1" "origin/$BRANCH" 2>/dev/null || git switch --quiet "dependabot/$1"
  echo "$2" >"$1"
  git add "$1"
  git commit --quiet -m "build(deps): bump $1"
  git switch --quiet -C deps "origin/$BRANCH"
  git merge --quiet --no-ff -m "Merge pull request from dependabot/$1" "dependabot/$1"
  git push --quiet origin "HEAD:refs/heads/$BRANCH"
  git fetch --quiet origin
  git rev-parse HEAD
}

remote_branch() { git -C "$CASE/remote.git" rev-parse "refs/heads/$BRANCH"; }

# run_script [--dry-run]: runs the script in the case's clone. Sets ACTIONS (stdout) and LOG (stderr).
run_script() {
  local status=0
  ACTIONS=$(cd "$CASE/clone" && FAKE_GH_DIR=$CASE/gh "$SCRIPT" "$@" 2>"$CASE/stderr") || status=$?
  LOG=$(cat "$CASE/stderr")
  if [[ $status -ne 0 ]]; then
    fail "$(basename "$CASE"): the script exited $status:"$'\n'"$LOG"
  fi
}

# expect_actions <expected>: compares ACTIONS with the expected list.
expect_actions() {
  if [[ $ACTIONS == "$1" ]]; then
    echo "ok: $(basename "$CASE") $2"
  else
    fail "$(basename "$CASE") $2: wrong action list"$'\n'"--- expected"$'\n'"$1"$'\n'"--- got"$'\n'"$ACTIONS"$'\n'"--- log"$'\n'"$LOG"
  fi
}

# expect_dry_run_wrote_nothing <branch sha before>
expect_dry_run_wrote_nothing() {
  if [[ $(remote_branch) != "$1" ]]; then
    fail "$(basename "$CASE"): the dry run pushed to $BRANCH"
  fi
  if [[ -s $CASE/gh/writes.log ]]; then
    fail "$(basename "$CASE"): the dry run made gh writes:"$'\n'"$(cat "$CASE/gh/writes.log")"
  fi
}

# expect_write <line>: a gh write the real run must have made.
expect_write() {
  if ! grep -qxF -- "$1" "$CASE/gh/writes.log" 2>/dev/null; then
    fail "$(basename "$CASE"): no gh write '$1'. Writes:"$'\n'"$(cat "$CASE/gh/writes.log" 2>/dev/null)"
  fi
}

# --- Behind only: a fast-forward, after which the branch matches main -----------

new_case behind-only
commit_on_main main.txt two
before=$(remote_branch)
run_script --dry-run
expect_actions "sync fast-forward
push $BRANCH
auto-merge 21
merge 24
red 25
red 26
auto-merge 27
promotion-pr none" "(dry run)"
expect_dry_run_wrote_nothing "$before"

# --- Ahead and behind, clean: a merge commit, and a promotion PR to open --------

new_case ahead-behind-clean
initial=$(git rev-parse HEAD)
bump=$(dependabot_merge deps.txt v2)
commit_on_main main.txt two
# #20 is unpromoted; #10 is already in main; #19 is a person's PR.
jq -n --arg bump "$bump" --arg initial "$initial" '[
  {"number": 20, "title": "build(deps): bump deps.txt", "author": {"login": "app/dependabot"}, "mergeCommit": {"oid": $bump}},
  {"number": 10, "title": "build(deps): an old bump", "author": {"login": "app/dependabot"}, "mergeCommit": {"oid": $initial}},
  {"number": 19, "title": "chore: by hand", "author": {"login": "tomboone"}, "mergeCommit": {"oid": $bump}}
]' >"$CASE/gh/merged.json"
before=$(remote_branch)
run_script --dry-run
expect_actions "sync merge
push $BRANCH
auto-merge 21
merge 24
red 25
red 26
auto-merge 27
promotion-pr create" "(dry run)"
expect_dry_run_wrote_nothing "$before"
if [[ $LOG != *"- #20 build(deps): bump deps.txt"* || $LOG == *"#10"* || $LOG == *"#19"* ]]; then
  fail "ahead-behind-clean: the promotion PR body should list #20 only:"$'\n'"$LOG"
fi

run_script
expect_actions "sync merge
push $BRANCH
auto-merge 21
merge 24
red 25
red 26
auto-merge 27
promotion-pr create" "(real run)"
if ! git -C "$CASE/remote.git" merge-base --is-ancestor main "refs/heads/$BRANCH" ||
  ! git -C "$CASE/remote.git" merge-base --is-ancestor "$before" "refs/heads/$BRANCH"; then
  fail "ahead-behind-clean: the real run didn't push a merge of main and $BRANCH"
fi
expect_write "pr merge --auto --merge 21"
expect_write "pr merge --merge 24"
expect_write "pr create --base main --head $BRANCH --title chore(deps): promote dependency updates"

# --- Ahead and behind, conflicting: no push, and a comment on the promotion PR ---

new_case ahead-behind-conflict
dependabot_merge shared.txt from-dependabot >/dev/null
commit_on_main shared.txt from-main
echo '[{"number": 30, "body": "stale"}]' >"$CASE/gh/promotion.json"
before=$(remote_branch)
run_script --dry-run
expect_actions "sync conflict
auto-merge 21
merge 24
red 25
red 26
auto-merge 27
promotion-pr update 30
conflict-comment 30" "(dry run)"
expect_dry_run_wrote_nothing "$before"

run_script
expect_actions "sync conflict
auto-merge 21
merge 24
red 25
red 26
auto-merge 27
promotion-pr update 30
conflict-comment 30" "(real run)"
if [[ $(remote_branch) != "$before" ]]; then
  fail "ahead-behind-conflict: the real run pushed to $BRANCH"
fi
expect_write "pr edit 30"
expect_write "pr comment 30"

# The comment is already there for this main commit, so the next run doesn't repeat it.
main_sha=$(git -C "$CASE/remote.git" rev-parse main)
jq -n --arg body "<!-- dependency-branch:sync-conflict main=$main_sha -->
earlier comment" '{"comments": [{"body": $body}]}' >"$CASE/gh/comments.json"
run_script --dry-run
expect_actions "sync conflict
auto-merge 21
merge 24
red 25
red 26
auto-merge 27
promotion-pr update 30
conflict-comment 30 exists" "(dry run, comment already posted)"

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all dependency-branch checks passed"
