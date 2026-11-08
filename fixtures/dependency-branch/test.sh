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
#
# Then step 4 and 5: one case per promotion hold reason, a promote, several reasons in one record,
# the window across DST and at its end, security updates merged and held, and malformed windows.
# Every one of these sets --now. Real runs check the merges and the hold marker in the PR body.
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

# dependabot_message <dependency> <update-type> [<from> <to>]: a Dependabot commit message, with the
# update metadata block dependabot/fetch-metadata parses. An update type of `none` leaves the block
# out; `missing` leaves out its update-type line, as on security updates; `garbled` also drops the
# versions from the prose.
dependabot_message() {
  local from=${3:-1.0.0} to=${4:-2.0.0}
  echo "build(deps): bump $1 from $from to $to"
  echo
  if [[ $2 == garbled ]]; then
    echo "Bumps $1."
  else
    echo "Bumps [$1](https://example.com/$1) from $from to $to."
  fi
  case $2 in
    none) ;;
    missing | garbled)
      printf '\n---\nupdated-dependencies:\n- dependency-name: %s\n  dependency-version: %s\n  dependency-type: direct:production\n...\n' "$1" "$to" ;;
    *)
      printf '\n---\nupdated-dependencies:\n- dependency-name: %s\n  dependency-version: %s\n  dependency-type: direct:production\n  update-type: %s\n...\n' "$1" "$to" "$2" ;;
  esac
  echo
  echo "Signed-off-by: dependabot[bot] <support@github.com>"
}

# requirement_message <dependency> <from> <to>: the message Dependabot writes when it widens a
# requirement range (uv, pip) rather than bumping a pinned version. Copied from a real one: the
# versions are only in the subject, after the word "requirement" and with their operators, and the
# metadata carries no update-type.
requirement_message() {
  echo "build: update $1 requirement from $2 to $3"
  echo
  echo "Updates the requirements on [$1](https://example.com/$1) to permit the latest version."
  echo "- [Commits](https://example.com/$1/compare/${2#>=}...${3#>=})"
  printf '\n---\nupdated-dependencies:\n- dependency-name: %s\n  dependency-version: %s\n  dependency-type: direct:production\n...\n' "$1" "${3#>=}"
  echo
  echo "Signed-off-by: dependabot[bot] <support@github.com>"
}

# requirement_merge <name> <from> <to>: a requirement-update PR merged into $BRANCH, as
# dependabot_merge does. <name> may carry extras (`sentry-sdk[fastapi]`), as the real ones do.
requirement_merge() {
  git switch --quiet -c dependabot/req "origin/$BRANCH"
  echo "$3" >requirements.txt
  git add requirements.txt
  git commit --quiet --author 'dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' \
    -m "$(requirement_message "$1" "$2" "$3")"
  git switch --quiet -C deps "origin/$BRANCH"
  git merge --quiet --no-ff -m "Merge pull request from dependabot/req" dependabot/req
  git push --quiet origin "HEAD:refs/heads/$BRANCH"
  git fetch --quiet origin
  git rev-parse HEAD
}

# dependabot_merge <file> <content> [<update-type>|none]: a PR branch merged into $BRANCH with a
# merge commit, the way auto-merge lands one. With an update type, the PR's commit is Dependabot's,
# with its metadata; without, it's a person's. Prints the merge commit.
dependabot_merge() {
  git switch --quiet -c "dependabot/$1" "origin/$BRANCH" 2>/dev/null || git switch --quiet "dependabot/$1"
  echo "$2" >"$1"
  git add "$1"
  if [[ -n ${3:-} ]]; then
    git commit --quiet --author 'dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' \
      -m "$(dependabot_message "$1" "$3")"
  else
    git commit --quiet -m "build(deps): bump $1"
  fi
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

# expect_no_write <line>: a gh write the real run must not have made.
expect_no_write() {
  if grep -qxF -- "$1" "$CASE/gh/writes.log" 2>/dev/null; then
    fail "$(basename "$CASE"): unexpected gh write '$1'"
  fi
}

# expect_body <write> <yes|no> <text>: whether the --body of the gh write <write> contains <text>.
expect_body() {
  local body
  body=$(awk -v header="== $1" '$0 == header { on = 1; next } /^== / { on = 0 } on' "$CASE/gh/bodies.log" 2>/dev/null)
  if [[ $2 == yes && $body != *"$3"* ]]; then
    fail "$(basename "$CASE"): the body of '$1' lacks '$3':"$'\n'"$body"
  elif [[ $2 == no && $body == *"$3"* ]]; then
    fail "$(basename "$CASE"): the body of '$1' has '$3':"$'\n'"$body"
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
promotion-pr create
hold new opted-out unsettled ci-pending" "(dry run)"
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
promotion-pr create
hold 31 opted-out unsettled ci-pending" "(real run)"
if ! git -C "$CASE/remote.git" merge-base --is-ancestor main "refs/heads/$BRANCH" ||
  ! git -C "$CASE/remote.git" merge-base --is-ancestor "$before" "refs/heads/$BRANCH"; then
  fail "ahead-behind-clean: the real run didn't push a merge of main and $BRANCH"
fi
expect_write "pr merge --auto --merge 21"
expect_write "pr merge --merge 24"
expect_write "pr create --base main --head $BRANCH --title chore(deps): promote dependency updates"
expect_body "pr create --base main --head $BRANCH --title chore(deps): promote dependency updates" yes \
  "<!-- dependency-branch:hold opted-out unsettled ci-pending -->"
expect_no_write "pr merge --merge 31"

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
conflict-comment 30
hold 30 opted-out conflict unsettled ci-pending" "(dry run)"
expect_dry_run_wrote_nothing "$before"

run_script
expect_actions "sync conflict
auto-merge 21
merge 24
red 25
red 26
auto-merge 27
promotion-pr update 30
conflict-comment 30
hold 30 opted-out conflict unsettled ci-pending" "(real run)"
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
conflict-comment 30 exists
hold 30 opted-out conflict unsettled ci-pending" "(dry run, comment already posted)"

# --- 4. Promote: the guards ------------------------------------------------------

# Saturday 2026-11-07 is in EST (UTC-5), Saturday 2026-10-31 in EDT (UTC-4).
INSIDE=2026-11-07T17:00:00Z    # Sat 12:00 EST
FRIDAY=2026-11-06T17:00:00Z    # Fri 12:00 EST
WINDOW_END=2026-11-07T23:00:00Z # Sat 18:00 EST, the end of the window, so outside

# promotion_pr <head oid> <ci conclusion, empty while running> <mergeStateStatus>: the open
# promotion PR, #30, with a stale body.
promotion_pr() {
  jq -n --arg oid "$1" --arg ci "$2" --arg state "$3" '[{
    "number": 30, "body": "stale", "headRefOid": $oid, "mergeStateStatus": $state,
    "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": $ci}]
  }]' >"$CASE/gh/promotion.json"
}

# promotion_case <name> [<update-type>|none]: $BRANCH one Dependabot merge (minor by default) ahead
# of main, so the sync has nothing to do; no open PR into it but a red one; and the promotion PR
# green at that merge. Sets TIP to the merge.
promotion_case() {
  new_case "$1"
  TIP=$(dependabot_merge deps.txt v2 "${2:-version-update:semver-minor}")
  echo '[{"number": 25, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "BLOCKED",
    "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": "FAILURE"}]}]' >"$CASE/gh/open.json"
  promotion_pr "$TIP" SUCCESS CLEAN
}

# expect_promotion <decision> <label>: the action list of a promotion case. A held PR's stale body
# is rewritten; a promoted one's is left alone.
expect_promotion() {
  local step3="promotion-pr update 30"
  [[ $1 != promote* ]] || step3="promotion-pr keep 30"
  expect_actions "sync none
red 25
$step3
$1" "$2"
}

promotion_case promote
# The body still says why the last run held, and is left alone: the PR is merged.
run_script --dry-run --auto-promote --now "$INSIDE"
expect_actions "sync none
red 25
promotion-pr keep 30
promote 30" "(dry run)"
expect_dry_run_wrote_nothing "$TIP"
run_script --auto-promote --now "$INSIDE"
expect_actions "sync none
red 25
promotion-pr keep 30
promote 30" "(real run)"
expect_write "pr merge --merge 30"
expect_no_write "pr edit 30"

# A commit a person adds to a Dependabot PR has no metadata, and doesn't make the batch major.
promotion_case promote-person-commit
TIP=$(dependabot_merge by-hand.txt v1)
promotion_pr "$TIP" SUCCESS CLEAN
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "promote 30" "(dry run)"

# An entry without update-type is judged by the message's versions: 1.0.0 to 1.1.0 is not a major.
new_case promote-missing-update-type
TIP=$(git switch --quiet -c dependabot/x "origin/$BRANCH" && echo v2 >x.txt && git add x.txt &&
  git commit --quiet --author 'dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>' \
    -m "$(dependabot_message x.txt missing 1.0.0 1.1.0)" &&
  git switch --quiet -C deps "origin/$BRANCH" && git merge --quiet --no-ff -m "Merge x" dependabot/x &&
  git push --quiet origin "HEAD:refs/heads/$BRANCH" && git rev-parse HEAD)
echo '[{"number": 25, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "BLOCKED",
  "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": "FAILURE"}]}]' >"$CASE/gh/open.json"
promotion_pr "$TIP" SUCCESS CLEAN
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "promote 30" "(dry run)"

# A requirement update ("update <name> requirement from >=A to >=B") carries no update-type and
# keeps its versions in the subject, after "requirement" and behind their operators. A minor one
# promotes: it used to read as "no from/to versions", and so as a major.
new_case promote-requirement-minor
TIP=$(requirement_merge 'sentry-sdk[fastapi]' '>=2.73.0' '>=2.74.0')
echo '[{"number": 25, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "BLOCKED",
  "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": "FAILURE"}]}]' >"$CASE/gh/open.json"
promotion_pr "$TIP" SUCCESS CLEAN
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "promote 30" "(dry run)"

# ...and one that crosses a major still holds, naming the versions it read.
new_case requirement-major
TIP=$(requirement_merge 'sentry-sdk[fastapi]' '>=2.73.0' '>=3.0.0')
echo '[{"number": 25, "author": {"login": "app/dependabot"}, "autoMergeRequest": null, "mergeStateStatus": "BLOCKED",
  "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": "FAILURE"}]}]' >"$CASE/gh/open.json"
promotion_pr "$TIP" SUCCESS CLEAN
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 major" "(dry run)"
if [[ $LOG != *"sentry-sdk[fastapi]: no update-type, and >=2.73.0 to >=3.0.0 is a major"* ]]; then
  fail "requirement-major: the log doesn't name the versions it read:"$'\n'"$LOG"
fi

# Without --auto-promote nothing is merged, and the window isn't recorded.
promotion_case opted-out
run_script --dry-run --now "$FRIDAY"
expect_promotion "hold 30 opted-out" "(dry run, outside the window)"
run_script --now "$INSIDE"
expect_promotion "hold 30 opted-out" "(real run, inside the window)"
expect_no_write "pr merge --merge 30"
expect_body "pr edit 30" yes "**Held:** opted-out
<!-- dependency-branch:hold opted-out -->"

promotion_case conflict
promotion_pr "$TIP" SUCCESS DIRTY
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 conflict" "(dry run)"

promotion_case major version-update:semver-major
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 major" "(dry run)"
run_script --auto-promote --now "$INSIDE"
expect_promotion "hold 30 major" "(real run)"
expect_no_write "pr merge --merge 30"
expect_body "pr edit 30" yes "<!-- dependency-branch:hold major -->"

promotion_case major-no-metadata none
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 major" "(dry run)"
if [[ $LOG != *"no updated-dependencies metadata"* ]]; then
  fail "major-no-metadata: the log doesn't say why the batch is major:"$'\n'"$LOG"
fi

promotion_case ci-red
promotion_pr "$TIP" FAILURE CLEAN
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 ci-red" "(dry run)"

promotion_case ci-pending
promotion_pr "$TIP" "" CLEAN
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 ci-pending" "(dry run, ci running)"
promotion_pr "$(git rev-parse "$TIP^")" SUCCESS CLEAN
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 ci-pending" "(dry run, stale head)"

# Green or running Dependabot PRs into the branch are part of the batch; the red one isn't.
promotion_case unsettled
jq '. + [{"number": 21, "author": {"login": "app/dependabot"}, "autoMergeRequest": {"enabledAt": "2026-11-07T00:00:00Z"},
  "mergeStateStatus": "BLOCKED", "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": ""}]}]' \
  "$CASE/gh/open.json" >"$CASE/gh/open.json.new" && mv "$CASE/gh/open.json.new" "$CASE/gh/open.json"
run_script --dry-run --auto-promote --now "$INSIDE"
expect_promotion "hold 30 unsettled" "(dry run)"
# One step 2 merges this run is still part of the batch: the next run sees it land.
jq '[.[] | select(.number != 21)] + [{"number": 24, "author": {"login": "app/dependabot"}, "autoMergeRequest": null,
  "mergeStateStatus": "CLEAN", "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": "SUCCESS"}]}]' \
  "$CASE/gh/open.json" >"$CASE/gh/open.json.new" && mv "$CASE/gh/open.json.new" "$CASE/gh/open.json"
run_script --dry-run --auto-promote --now "$INSIDE"
expect_actions "sync none
merge 24
red 25
promotion-pr update 30
hold 30 unsettled" "(dry run, merged this run)"

promotion_case outside-window
run_script --dry-run --auto-promote --now "$FRIDAY"
expect_promotion "hold 30 outside-window" "(dry run, Friday)"
run_script --dry-run --auto-promote --now "$WINDOW_END"
expect_promotion "hold 30 outside-window" "(dry run, Saturday 18:00)"
run_script --dry-run --auto-promote --now 2026-11-07T22:59:59Z
expect_promotion "promote 30" "(dry run, Saturday 17:59:59)"

promotion_case several-reasons version-update:semver-major
promotion_pr "$TIP" "" CLEAN
run_script --dry-run --auto-promote --now "$FRIDAY"
expect_promotion "hold 30 major ci-pending outside-window" "(dry run)"

# The same local time, 10:30, inside the window in EDT and in EST; and 14:30 UTC, which is 10:30
# in EDT, is 09:30 in EST, before the window opens.
promotion_case dst
run_script --dry-run --auto-promote --now 2026-10-31T14:30:00Z
expect_promotion "promote 30" "(dry run, 10:30 EDT)"
run_script --dry-run --auto-promote --now 2026-11-07T15:30:00Z
expect_promotion "promote 30" "(dry run, 10:30 EST)"
run_script --dry-run --auto-promote --now 2026-11-07T14:30:00Z
expect_promotion "hold 30 outside-window" "(dry run, 09:30 EST)"

# --- 5. Security updates ---------------------------------------------------------

# security_pr <number> <ci conclusion> <update-type> [<author> [<from> <to>]]: an open PR into main.
security_pr() {
  jq -n --argjson number "$1" --arg ci "$2" --arg author "${4:-app/dependabot}" \
    --arg body "$(dependabot_message "dep$1" "$3" "${5:-}" "${6:-}" | sed 1,2d)" '{
    "number": $number, "author": {"login": $author},
    "statusCheckRollup": [{"__typename": "CheckRun", "name": "ci", "conclusion": $ci}],
    "commits": [{"oid": "abcdef1234567890", "authors": [{"name": "dependabot[bot]", "login": "dependabot[bot]"}],
      "messageHeadline": "build(deps): bump dep\($number)", "messageBody": $body}]
  }'
}

new_case security
echo '[]' >"$CASE/gh/open.json"
{
  security_pr 44 FAILURE version-update:semver-patch
  security_pr 40 SUCCESS version-update:semver-minor
  security_pr 41 SUCCESS version-update:semver-major
  security_pr 42 SUCCESS version-update:semver-minor tomboone
  security_pr 43 "" version-update:semver-minor
  # Security updates carry no update-type: the versions in the message decide.
  security_pr 45 SUCCESS missing app/dependabot 4.17.20 4.18.1
  security_pr 46 SUCCESS missing app/dependabot 4.17.20 5.0.0
  security_pr 47 SUCCESS garbled
} | jq -s . >"$CASE/gh/security.json"
before=$(remote_branch)
run_script --dry-run --auto-promote --now "$INSIDE"
expect_actions "sync none
promotion-pr none
security-merge 40
security-hold 41 major
security-hold 43 ci-pending
security-hold 44 ci-red
security-merge 45
security-hold 46 major
security-hold 47 major" "(dry run)"
expect_dry_run_wrote_nothing "$before"
run_script --dry-run --auto-promote --now "$FRIDAY"
expect_actions "sync none
promotion-pr none
security-hold 40 outside-window
security-hold 41 major outside-window
security-hold 43 ci-pending outside-window
security-hold 44 ci-red outside-window
security-hold 45 outside-window
security-hold 46 major outside-window
security-hold 47 major outside-window" "(dry run, outside the window)"
run_script --now "$INSIDE"
expect_actions "sync none
promotion-pr none
security-hold 40 opted-out
security-hold 41 opted-out major
security-hold 43 opted-out ci-pending
security-hold 44 opted-out ci-red
security-hold 45 opted-out
security-hold 46 opted-out major
security-hold 47 opted-out major" "(real run, opted out)"
if [[ -s $CASE/gh/writes.log ]]; then
  fail "security: the opted-out run made gh writes:"$'\n'"$(cat "$CASE/gh/writes.log")"
fi
run_script --auto-promote --now "$INSIDE"
expect_actions "sync none
promotion-pr none
security-merge 40
security-hold 41 major
security-hold 43 ci-pending
security-hold 44 ci-red
security-merge 45
security-hold 46 major
security-hold 47 major" "(real run)"
expect_write "pr merge --merge 40"
expect_no_write "pr merge --merge 41"
expect_write "pr merge --merge 45"
expect_no_write "pr merge --merge 46"
if [[ $LOG != *"dep46: no update-type, and 4.17.20 to 5.0.0 is a major"* ||
  $LOG != *"dep47: no update-type, and no from/to versions in the message"* ]]; then
  fail "security: the log doesn't say why #46 and #47 are major:"$'\n'"$LOG"
fi

# --- A malformed window or --now fails the run -----------------------------------

new_case malformed
for args in "--window|Sat 10:00-18:00" "--window|Saturday 10:00-18:00 America/New_York" \
  "--window|Sat 18:00-10:00 America/New_York" "--window|Sat 10:00-24:00 America/New_York" \
  "--window|Sat 10:00-18:00 Mars/Olympus_Mons" "--now|2026-11-07 15:00"; do
  status=0
  (cd "$CASE/clone" && FAKE_GH_DIR=$CASE/gh "$SCRIPT" --dry-run "${args%%|*}" "${args#*|}" >/dev/null 2>&1) || status=$?
  if [[ $status -eq 2 ]]; then
    echo "ok: malformed ${args%%|*} '${args#*|}' exits 2"
  else
    fail "malformed: ${args%%|*} '${args#*|}' exited $status, not 2"
  fi
done

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all dependency-branch checks passed"
