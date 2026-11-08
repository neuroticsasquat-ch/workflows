#!/usr/bin/env bash
# Self-test for scripts/digest.sh, run by self-test.yml's `digest` job.
#
#   fixtures/digest/test.sh
#
# due: both crons on every Saturday of 2026, across both DST changes, must post exactly once, at
# 18:30 New York time, including when a run starts late; malformed arguments exit 2.
# collect: two installations' canned GitHub answers (bin/gh stands in for gh), covering a held
# promotion PR, red and green Dependabot PRs, a security PR, promotions merged today and last week,
# a repo that doesn't call dependency-branch.yml, an archived one and one whose query fails.
# render: the exact digest for those, then a digest too long for one message, split under
# Discord's limits with every repo listed exactly once. post: the payloads reach the webhook in
# order, a rate limit is waited out, and a refusal fails the run (bin/curl stands in for curl).
# shellcheck disable=SC2016 # The backticks in single quotes are Markdown, not command substitution.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$HERE/../../scripts/digest.sh
export PATH="$HERE/bin:$PATH"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
fail() {
  echo "::error title=digest test::$*"
  failures=$((failures + 1))
}
ok() { echo "ok: $*"; }

# expect_equal <what> <expected> <actual>
expect_equal() {
  if [[ $2 == "$3" ]]; then
    ok "$1"
  else
    fail "$1: expected"$'\n'"$2"$'\n'"got"$'\n'"$3"
  fi
}

# expect_exit <status> <what> <command>...: the command, its output dropped, exits <status>.
expect_exit() {
  local want=$1 what=$2 status=0
  shift 2
  "$@" >/dev/null 2>&1 || status=$?
  expect_equal "$what exits $want" "$want" "$status"
}

# --- due -------------------------------------------------------------------------

due() { "$SCRIPT" due --schedule "$1" --now "$2" 2>/dev/null; }

# Every Saturday of 2026, each cron at the minute it fires. Daylight time runs from 8 March to
# 1 November, so both changes fall between two of these Saturdays.
saturdays=$(jq -nr '[range(0; 52) | 1767398400 + . * 604800 | todate[0:10]] | .[]')
wrong=
for day in $saturdays; do
  posts=0
  for cron in "30 22 * * 6|T22:30:00Z" "30 23 * * 6|T23:30:00Z"; do
    [[ $(due "${cron%%|*}" "$day${cron#*|}") == true ]] && posts=$((posts + 1))
  done
  [[ $posts -eq 1 ]] || wrong="$wrong $day($posts)"
done
expect_equal "every Saturday of 2026 posts exactly once (wrong:${wrong:- none})" "" "$wrong"

expect_equal "EDT: the 22:30 UTC cron posts" true "$(due "30 22 * * 6" 2026-10-31T22:30:04Z)"
expect_equal "EDT: the 23:30 UTC cron doesn't" false "$(due "30 23 * * 6" 2026-10-31T23:30:04Z)"
expect_equal "EST: the 22:30 UTC cron doesn't" false "$(due "30 22 * * 6" 2026-11-07T22:30:04Z)"
expect_equal "EST: the 23:30 UTC cron posts" true "$(due "30 23 * * 6" 2026-11-07T23:30:04Z)"
# GitHub can start a scheduled run late. The time the cron was due decides, not the start.
expect_equal "EDT: the 22:30 UTC cron starting 70 minutes late still posts" true \
  "$(due "30 22 * * 6" 2026-10-31T23:40:00Z)"
expect_equal "EST: the 23:30 UTC cron starting on Sunday UTC still posts" true \
  "$(due "30 23 * * 6" 2026-11-08T00:45:00Z)"
expect_equal "EST: the 22:30 UTC cron starting late still doesn't" false \
  "$(due "30 22 * * 6" 2026-11-07T23:35:00Z)"
expect_equal "--at moves the posting time" true \
  "$("$SCRIPT" due --schedule "0 14 * * 0" --at "Sun 09:00 America/New_York" --now 2026-11-08T14:01:00Z 2>/dev/null)"

expect_exit 2 "due without --schedule" "$SCRIPT" due --now 2026-11-07T23:30:00Z
for schedule in "30 22 * * *" "*/30 22 * * 6" "30 22 * * 7" "30 24 * * 6" "30 22 * * 6 extra"; do
  expect_exit 2 "due --schedule '$schedule'" "$SCRIPT" due --schedule "$schedule" --now 2026-11-07T23:30:00Z
done
for at in "Sat 18:30" "Saturday 18:30 America/New_York" "Sat 18:30 Mars/Olympus_Mons"; do
  expect_exit 2 "due --at '$at'" "$SCRIPT" due --schedule "30 23 * * 6" --at "$at" --now 2026-11-07T23:30:00Z
done
expect_exit 2 "due --now 'yesterday'" "$SCRIPT" due --schedule "30 23 * * 6" --now yesterday
expect_exit 2 "an unknown command" "$SCRIPT" summarise

# --- collect ---------------------------------------------------------------------

# pr <number> <base> <head> <author> <ci conclusion, or "" for none> [<body>]: an open PR as the
# GraphQL query returns it. An author starting app/ is a bot. A conclusion starting status: is a
# commit status instead of a check run.
pr() {
  jq -n --argjson number "$1" --arg base "$2" --arg head "$3" --arg author "$4" --arg ci "$5" \
    --arg body "${6:-}" '{
    number: $number, url: "https://github.com/example/pull/\($number)", body: $body,
    baseRefName: $base, headRefName: $head,
    author: (if ($author | startswith("app/")) then {__typename: "Bot", login: ($author | ltrimstr("app/"))}
             else {__typename: "User", login: $author} end),
    head: {nodes: [{commit: {statusCheckRollup: (
      if $ci == "" then null
      elif ($ci | startswith("status:")) then
        {contexts: {nodes: [{__typename: "StatusContext", context: "ci", state: ($ci | ltrimstr("status:"))}]}}
      else {contexts: {nodes: [
        {__typename: "CheckRun", name: "lint", status: "COMPLETED", conclusion: "FAILURE"},
        {__typename: "CheckRun", name: "ci", status: "COMPLETED", conclusion: $ci}]}} end)}}]}
  }'
}

# merged <number> <base> <mergedAt>: a merged promotion PR.
merged() {
  jq -n --argjson number "$1" --arg base "$2" --arg at "$3" \
    '{number: $number, url: "https://github.com/example/pull/\($number)", baseRefName: $base, mergedAt: $at}'
}

# repo <dir> <owner/name> <default branch> <adopted: yes|no> <open PRs JSON> <merged PRs JSON>
repo() {
  mkdir -p "$1/repos"
  jq -n --arg repo "$2" --arg base "$3" --arg adopted "$4" --argjson open "$5" --argjson merged "$6" '
    {data: {repository: {
      nameWithOwner: $repo, url: "https://github.com/\($repo)", defaultBranchRef: {name: $base},
      caller: (if $adopted == "yes" then {__typename: "Blob"} else null end),
      open: {nodes: $open}, promoted: {nodes: $merged}}}}' >"$1/repos/${2%%/*}_${2#*/}.json"
}

NS=$WORK/ns
TB=$WORK/tb
mkdir -p "$NS/repos" "$TB/repos"

# Two pages, the way `gh api --paginate` prints them, out of order.
cat >"$NS/repositories.json" <<'EOF'
{"total_count": 6, "repositories": [
  {"full_name": "ns/quiet", "archived": false}, {"full_name": "ns/alpha", "archived": false},
  {"full_name": "ns/old", "archived": true}, {"full_name": "ns/gamma", "archived": false}]}
{"total_count": 6, "repositories": [
  {"full_name": "ns/beta", "archived": false}, {"full_name": "ns/broken", "archived": false},
  {"full_name": "ns/delta", "archived": false}]}
EOF
echo '{"total_count": 1, "repositories": [{"full_name": "tb/site", "archived": false}]}' >"$TB/repositories.json"

HELD_BODY='Promotes `updates/dependencies` into `main`.

**Held:** major, outside-window
<!-- dependency-branch:hold major outside-window -->'
repo "$NS" ns/alpha main yes "$(
  {
    pr 30 main updates/dependencies app/ns-automation SUCCESS "$HELD_BODY"
    pr 21 updates/dependencies dependabot/uv/a app/dependabot FAILURE
    pr 22 updates/dependencies dependabot/uv/b app/dependabot SUCCESS
    pr 23 updates/dependencies dependabot/uv/c app/dependabot ""
    pr 24 updates/dependencies tom/fix tomboone FAILURE
    pr 25 main dependabot/uv/security app/dependabot SUCCESS
    pr 26 updates/dependencies dependabot/npm/d app/dependabot status:ERROR
    pr 28 updates/dependencies dependabot/npm/e app/dependabot status:EXPECTED
    pr 27 main tom/feature tomboone FAILURE
  } | jq -s .
)" '[]'
repo "$NS" ns/beta main yes '[]' "$(
  {
    merged 40 main 2026-11-07T15:05:00Z
    merged 39 release/1 2026-11-07T16:00:00Z
    merged 35 main 2026-10-31T15:00:00Z
  } | jq -s .
)"
repo "$NS" ns/gamma main no "$(pr 50 updates/dependencies dependabot/uv/x app/dependabot FAILURE | jq -s .)" '[]'
repo "$NS" ns/quiet main yes "$(pr 60 main tom/feature tomboone FAILURE | jq -s .)" "$(merged 61 main 2026-11-06T23:00:00Z | jq -s .)"
# The default branch is master here, and the promotion PR has no hold marker.
repo "$NS" ns/delta master yes "$(pr 70 master updates/dependencies app/ns-automation "" "Promotes it." | jq -s .)" '[]'
echo 'GraphQL: Could not resolve to a Repository with the name `ns/broken`. (repository)' >"$NS/repos/ns_broken.error"
repo "$TB" tb/site main yes "$(pr 80 updates/dependencies dependabot/github_actions/x app/dependabot CANCELLED | jq -s .)" '[]'

FAKE_GH_DIR=$NS "$SCRIPT" collect >"$WORK/ns.json" 2>"$WORK/collect.log"
FAKE_GH_DIR=$TB "$SCRIPT" collect >"$WORK/tb.json" 2>>"$WORK/collect.log"
COLLECTED=$(jq -s add "$WORK/ns.json" "$WORK/tb.json")

expect_equal "collect: archived repos aren't queried" "ns/alpha ns/beta ns/broken ns/delta ns/gamma ns/quiet" \
  "$(sort "$NS/queried.log" | tr '\n' ' ' | sed 's/ $//')"
expect_equal "collect: one report per adopted or unreadable repo, nothing for gamma" \
  "ns/alpha ns/beta ns/broken ns/delta ns/quiet tb/site" "$(jq -r '[.[].repo] | join(" ")' <<<"$COLLECTED")"
expect_equal "collect: alpha's promotion PR is held for the recorded reasons" '{"number":30,"reasons":["major","outside-window"]}' \
  "$(jq -c '.[] | select(.repo == "ns/alpha") | .held | {number, reasons}' <<<"$COLLECTED")"
expect_equal "collect: red is Dependabot PRs into the branch with ci red, check run or status, not expected" "21 26" \
  "$(jq -r '.[] | select(.repo == "ns/alpha") | [.red[].number] | join(" ")' <<<"$COLLECTED")"
expect_equal "collect: security is Dependabot PRs into the default branch" "25" \
  "$(jq -r '.[] | select(.repo == "ns/alpha") | [.security[].number] | join(" ")' <<<"$COLLECTED")"
expect_equal "collect: promotions are merges into the default branch only" "40 35" \
  "$(jq -r '.[] | select(.repo == "ns/beta") | [.promoted[].number] | join(" ")' <<<"$COLLECTED")"
expect_equal "collect: a promotion PR into master, with no marker, is held for no recorded reason" '{"number":70,"reasons":[]}' \
  "$(jq -c '.[] | select(.repo == "ns/delta") | .held | {number, reasons}' <<<"$COLLECTED")"
expect_equal "collect: a failing query is reported, not dropped" \
  'GraphQL: Could not resolve to a Repository with the name `ns/broken`. (repository)' \
  "$(jq -r '.[] | select(.repo == "ns/broken") | .error' <<<"$COLLECTED")"
if ! grep -q 'ns/gamma: no .github/workflows/dependencies.yml' "$WORK/collect.log"; then
  fail "collect: the log doesn't say why gamma is left out:"$'\n'"$(cat "$WORK/collect.log")"
fi

# --- render ----------------------------------------------------------------------

# 18:30 EST on Saturday 7 November 2026: #40 was merged today, #35 and #61 earlier.
PAYLOADS=$("$SCRIPT" render --now 2026-11-07T23:30:00Z "$WORK/ns.json" "$WORK/tb.json")
expect_equal "render: one message" 1 "$(grep -c . <<<"$PAYLOADS")"
expect_equal "render: the title is today in New York" "Dependency digest · Sat 07 Nov 2026" \
  "$(jq -r '.embeds[0].title' <<<"$PAYLOADS")"
expect_equal "render: red, because a repo is red" 15548997 "$(jq -r '.embeds[0].color' <<<"$PAYLOADS")"
expect_equal "render: no mentions" '{"parse":[]}' "$(jq -c '.allowed_mentions' <<<"$PAYLOADS")"
expect_equal "render: the digest" \
  '⚠️ **[ns/broken](https://github.com/ns/broken)** · could not read it: `GraphQL: Could not resolve to a Repository with the name ns/broken. (repository)`
🔴 **[ns/alpha](https://github.com/ns/alpha)** · held [#30](https://github.com/example/pull/30): major, outside-window · red [#21](https://github.com/example/pull/21), [#26](https://github.com/example/pull/26) · security [#25](https://github.com/example/pull/25)
🔴 **[tb/site](https://github.com/tb/site)** · red [#80](https://github.com/example/pull/80)
🟡 **[ns/delta](https://github.com/ns/delta)** · held [#70](https://github.com/example/pull/70): no hold recorded
🟢 **[ns/beta](https://github.com/ns/beta)** · promoted [#40](https://github.com/example/pull/40)
Nothing to report in 1 repo.' "$(jq -r '.embeds[0].description' <<<"$PAYLOADS")"

# A week later nothing was merged that day, so beta has nothing to report either.
expect_equal "render: a promotion merged on an earlier day isn't listed" "Nothing to report in 2 repos." \
  "$("$SCRIPT" render --now 2026-11-14T23:30:00Z "$WORK/ns.json" "$WORK/tb.json" | jq -r '.embeds[-1].description | split("\n") | last')"
expect_equal "render: nothing adopted" "No repo calls dependency-branch.yml yet." \
  "$(echo '[]' | "$SCRIPT" render --now 2026-11-07T23:30:00Z /dev/stdin | jq -r '.embeds[0].description')"
expect_equal "render: green when only promotions" 5763719 \
  "$(jq '[.[] | select(.repo == "ns/beta" or .repo == "ns/quiet")]' <<<"$COLLECTED" |
    "$SCRIPT" render --now 2026-11-07T23:30:00Z /dev/stdin | jq -r '.embeds[0].color')"
expect_exit 2 "render with no files" "$SCRIPT" render --now 2026-11-07T23:30:00Z
expect_exit 2 "render --zone Mars/Olympus_Mons" "$SCRIPT" render --zone Mars/Olympus_Mons "$WORK/ns.json"

# Too long for one message: 150 red repos with five PRs each, 60 quiet ones, and one repo whose
# line alone is longer than an embed's description may be.
jq -n '[range(0; 210) | {
    repo: "big/repo-\(. + 1000)", url: "https://github.com/big/repo-\(. + 1000)", error: null,
    promoted: [], held: null, security: [],
    red: (if . < 150 then [range(1; 6) as $n | {number: $n, url: "https://github.com/big/repo/pull/\($n)"}] else [] end)}]
  + [{repo: "big/huge", url: "https://github.com/big/huge", error: null, promoted: [], held: null, security: [],
      red: [range(1; 200) as $n | {number: $n, url: "https://github.com/big/huge/pull/\($n)"}]}]' >"$WORK/big.json"
BIG=$("$SCRIPT" render --now 2026-11-07T23:30:00Z "$WORK/big.json")
messages=$(grep -c . <<<"$BIG")
if [[ $messages -gt 1 ]]; then ok "render: a long digest is split ($messages messages)"; else fail "render: the long digest wasn't split"; fi
expect_equal "render: every embed description is at most 4000 characters" "" \
  "$(jq -r '.embeds[] | select((.description | length) > 4000) | .description[0:40]' <<<"$BIG")"
expect_equal "render: every message is at most 5900 characters and 10 embeds" "" \
  "$(jq -r 'select(([.embeds[] | (.title // "" | length) + (.description | length)] | add) > 5900 or (.embeds | length) > 10) | "too big"' <<<"$BIG")"
expect_equal "render: the title is on the first embed only" 1 "$(jq -s '[.[].embeds[] | select(.title)] | length' <<<"$BIG")"
expect_equal "render: every red repo is listed exactly once" "" \
  "$(jq -r '.embeds[].description' <<<"$BIG" | grep -o '\*\*\[big/repo-[0-9]*\]' | sort | uniq -c |
    awk '$1 != 1' | head -n 3)"
expect_equal "render: 150 red repos listed" 150 \
  "$(jq -r '.embeds[].description' <<<"$BIG" | grep -o '\*\*\[big/repo-[0-9]*\]' | sort -u | grep -c .)"
expect_equal "render: the quiet ones are counted, last" "Nothing to report in 60 repos." \
  "$(jq -s -r '.[-1].embeds[-1].description | split("\n") | last' <<<"$BIG")"
expect_equal "render: an over-long line is cut short" "…" \
  "$(jq -r '.embeds[].description | split("\n")[] | select(contains("big/huge")) | .[-1:]' <<<"$BIG")"

# --- post ------------------------------------------------------------------------

CURL=$WORK/curl
mkdir -p "$CURL"
touch "$CURL/429"
FAKE_CURL_DIR=$CURL DISCORD_WEBHOOK=https://discord.example/api/webhooks/1/token "$SCRIPT" post <<<"$BIG" 2>/dev/null
expect_equal "post: every payload, in order, after waiting out a rate limit" "$BIG" "$(cat "$CURL/posts.log")"
expect_equal "post: waits for Discord's answer" "https://discord.example/api/webhooks/1/token?wait=true" \
  "$(sort -u "$CURL/urls.log")"
echo 400 >"$CURL/status"
FAKE_CURL_DIR=$CURL DISCORD_WEBHOOK=https://discord.example/api/webhooks/1/token \
  expect_exit 1 "post refused by Discord" "$SCRIPT" post <<<"$PAYLOADS"
FAKE_CURL_DIR=$CURL DISCORD_WEBHOOK='' expect_exit 2 "post without DISCORD_WEBHOOK" "$SCRIPT" post <<<"$PAYLOADS"
rm "$CURL/status"
FAKE_CURL_DIR=$CURL DISCORD_WEBHOOK=https://discord.example/api/webhooks/1/token \
  expect_exit 2 "post with nothing to post" "$SCRIPT" post </dev/null

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all digest checks passed"
