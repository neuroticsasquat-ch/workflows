#!/usr/bin/env bash
# The steps behind digest.yml: the Saturday dependency digest in Discord #dependencies. It only
# reads; it never acts on a repo.
#
#   scripts/digest.sh due --schedule "<cron>" [--at "Sat 18:30 America/New_York"] [--now 2026-11-07T23:30:00Z] | collect | render [--zone America/New_York] [--now ...] <collected.json>... | post
#
# due      Prints `true` when the cron that fired (github.event.schedule) was scheduled for the
#          --at day and time in its zone, else `false`. GitHub's cron runs in UTC, so digest.yml has
#          one cron for 18:30 EDT (22:30 UTC) and one for 18:30 EST (23:30 UTC), and this check
#          lets exactly one of them post each Saturday. It judges the time the cron was due, not
#          the time the run started, because a scheduled run can start late.
# collect  With `gh` logged in as one installation of the automation app (GH_TOKEN), prints a JSON
#          array with one report per unarchived repo that has .github/workflows/dependencies.yml:
#            {repo, url, error, promoted: [{number, url, mergedAt}], held: {number, url, reasons}|null,
#             red: [{number, url}], security: [{number, url}]}
#          promoted: promotion PRs (updates/dependencies into the default branch) merged lately;
#          held: the open promotion PR, with the reasons from its dependency-branch:hold marker;
#          red: open Dependabot PRs into updates/dependencies whose `ci` is red; security: open
#          Dependabot PRs into the default branch. A repo whose query fails is reported with
#          `error` set, so it still shows up.
# render   Reads one or more collect outputs and prints the Discord webhook payloads, one JSON
#          object per line. A repo with something promoted today (in --zone), held, red or
#          failing gets a line; the rest collapse into a count. Lines are packed into embeds and
#          embeds into messages under Discord's limits (4096 characters a description, 6000 and 10
#          embeds a message), so a long digest is split over several messages.
# post     Posts each payload on stdin to the webhook in DISCORD_WEBHOOK, in order.
#
# A malformed argument exits 2.
set -euo pipefail

BRANCH=updates/dependencies
CALLER=.github/workflows/dependencies.yml
HOLD_MARKER=dependency-branch:hold
# Discord's limits are 4096 and 6000 characters. jq counts code points and Discord may count
# UTF-16 units, so leave room for the emoji.
DESCRIPTION_MAX=4000
MESSAGE_MAX=5900
EMBEDS_MAX=10

usage() {
  sed -n '5p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
  exit 2
}
fatal() {
  echo "::error title=digest::$*" >&2
  exit 2
}
log() { echo "$*" >&2; }

# epoch <ISO-8601 UTC instant or empty>: seconds since the epoch, now when empty.
epoch() {
  if [[ -z $1 ]]; then
    jq -n 'now | floor'
  else
    jq -n --arg now "$1" '$now | fromdateiso8601' 2>/dev/null ||
      fatal "malformed --now '$1': expected an ISO-8601 UTC instant, e.g. 2026-11-07T23:30:00Z"
  fi
}

# check_zone <zone>: TZ falls back to UTC for a zone it doesn't know, so check the zone database.
check_zone() {
  [[ -f /usr/share/zoneinfo/$1 ]] || fatal "unknown time zone '$1'"
}

# --- due -------------------------------------------------------------------------

due() {
  local schedule='' at='Sat 18:30 America/New_York' now=
  while [[ $# -gt 0 ]]; do
    case $1 in
      --schedule) schedule=${2:?--schedule needs a value}; shift 2 ;;
      --at) at=${2:?--at needs a value}; shift 2 ;;
      --now) now=${2:?--now needs a value}; shift 2 ;;
      *) usage ;;
    esac
  done
  # Only the shape digest.yml uses: a minute, an hour and a weekday (Sun = 0), every week.
  if ! [[ $schedule =~ ^([0-5]?[0-9])\ ([01]?[0-9]|2[0-3])\ \*\ \*\ ([0-6])$ ]]; then
    fatal "unsupported schedule '$schedule': expected '<minute> <hour> * * <weekday>', e.g. '30 22 * * 6'"
  fi
  local cron_minute=$((10#${BASH_REMATCH[1]})) cron_hour=$((10#${BASH_REMATCH[2]})) cron_wday=${BASH_REMATCH[3]}
  if ! [[ $at =~ ^(Sun|Mon|Tue|Wed|Thu|Fri|Sat)\ ([01][0-9]|2[0-3]):([0-5][0-9])\ ([A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*)$ ]]; then
    fatal "malformed --at '$at': expected '<Day> <HH:MM> <IANA zone>', e.g. 'Sat 18:30 America/New_York'"
  fi
  local at_day=${BASH_REMATCH[1]} at_minute=$((10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
  local zone=${BASH_REMATCH[4]}
  check_zone "$zone"
  local now_epoch scheduled
  now_epoch=$(epoch "$now")
  # The latest instant at or before now that the cron matches (in UTC).
  scheduled=$(jq -n --argjson now "$now_epoch" --argjson m "$cron_minute" --argjson h "$cron_hour" \
    --argjson d "$cron_wday" '
    ($now | gmtime) as $t
    | ($now - ($t[3] * 3600 + $t[4] * 60 + ($t[5] | floor))) as $midnight
    | ($midnight - ((($t[6] - $d + 7) % 7) * 86400) + $h * 3600 + $m * 60) as $at
    | if $at > $now then $at - 604800 else $at end')
  local days=(Sun Mon Tue Wed Thu Fri Sat) wday minute
  read -r wday minute < <(TZ=$zone jq -nr --argjson t "$scheduled" '$t | localtime | "\(.[6]) \(.[3] * 60 + .[4])"')
  log "The cron '$schedule' was due at $(TZ=$zone jq -nr --argjson t "$scheduled" \
    '$t | localtime | strftime("%a %H:%M")') in $zone; the digest posts at $at."
  if [[ ${days[$wday]} == "$at_day" && $minute -eq $at_minute ]]; then echo true; else echo false; fi
}

# --- collect ---------------------------------------------------------------------

# One query per repo: whether it calls dependency-branch.yml, its open PRs with their `ci`, and its
# recently merged promotion PRs. Check runs are asked only for name, status and conclusion: the app
# has no Actions: read, which `gh pr list --json statusCheckRollup` needs.
# shellcheck disable=SC2016 # GraphQL variables, not shell ones.
REPO_QUERY='
query($owner: String!, $name: String!, $branch: String!, $caller: String!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner url
    defaultBranchRef { name }
    caller: object(expression: $caller) { __typename }
    open: pullRequests(states: OPEN, first: 100) {
      nodes {
        number url body baseRefName headRefName
        author { __typename login }
        head: commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
          __typename
          ... on CheckRun { name status conclusion }
          ... on StatusContext { context state }
        } } } } } }
      }
    }
    promoted: pullRequests(states: MERGED, headRefName: $branch, first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { number url baseRefName mergedAt }
    }
  }
}'

# shellcheck disable=SC2016 # jq variables, not shell ones.
REPORT_JQ='
  # The latest `ci` result, as in dependency-branch.sh: a check run reports a conclusion once it
  # finishes, a commit status a state. No `ci` yet, or one still running or expected, is PENDING.
  def ci_state:
    ([.[] | select((.name // .context) == "ci")] | last)
    | if . == null then "PENDING"
      else ((.conclusion // "") as $c | if $c != "" then $c else (.state // "PENDING") end) end
    | if . == "EXPECTED" then "PENDING" else . end;
  def ref: {number, url};
  .data.repository as $r
  | if $r.caller == null then empty else
    $r.defaultBranchRef.name as $base
    | [$r.open.nodes[] | {
        number, url, body, base: .baseRefName, head: .headRefName,
        dependabot: (.author.__typename == "Bot" and .author.login == "dependabot"),
        ci: (.head.nodes[0].commit.statusCheckRollup.contexts.nodes // [] | ci_state)}] as $open
    | {
        repo: $r.nameWithOwner, url: $r.url, error: null,
        promoted: [$r.promoted.nodes[] | select(.baseRefName == $base) | {number, url, mergedAt}],
        held: ([$open[] | select(.head == $branch and .base == $base)] | first
          | if . == null then null else ref + {reasons: (
              [(.body // "") | match("<!-- " + $marker + " ([^>]*?) -->")] | last
              | if . == null then [] else .captures[0].string | split(" ") | map(select(. != "")) end)} end),
        red: [$open[] | select(.dependabot and .base == $branch and (.ci | IN("SUCCESS", "PENDING") | not)) | ref],
        security: [$open[] | select(.dependabot and .base == $base) | ref]
      }
    end'

collect() {
  [[ $# -eq 0 ]] || usage
  local repos repo out err
  err=$(mktemp)
  # Every page is one object; the stream goes to jq as it is.
  repos=$(gh api installation/repositories --paginate |
    jq -r '.repositories[] | select(.archived | not) | .full_name' | sort)
  log "The installation can see $(grep -c . <<<"$repos" || true) unarchived repos."
  for repo in $repos; do
    if out=$(gh api graphql -f query="$REPO_QUERY" -f owner="${repo%%/*}" -f name="${repo#*/}" \
      -f branch="$BRANCH" -f caller="HEAD:$CALLER" 2>"$err") &&
      out=$(jq -c --arg branch "$BRANCH" --arg marker "$HOLD_MARKER" "$REPORT_JQ" <<<"$out" 2>"$err"); then
      if [[ -n $out ]]; then echo "$out"; else log "$repo: no $CALLER, so not in the digest."; fi
    else
      echo "::warning title=digest::couldn't read $repo: $(head -c 500 "$err")" >&2
      jq -nc --arg repo "$repo" --arg error "$(head -n 1 "$err" | head -c 200)" '{
        repo: $repo, url: "https://github.com/\($repo)", error: (if $error == "" then "unknown error" else $error end),
        promoted: [], held: null, red: [], security: []}'
    fi
  done | jq -s .
  rm -f "$err"
}

# --- render ----------------------------------------------------------------------

# shellcheck disable=SC2016 # jq variables, not shell ones.
RENDER_JQ='
  def link: "[#\(.number)](\(.url))";
  def links: map(link) | join(", ");
  # 0 failing, 1 red, 2 held or security, 3 promoted only, 4 nothing to report.
  def rank:
    if .error != null then 0 elif (.red | length) > 0 then 1
    elif .held != null or (.security | length) > 0 then 2
    elif (.promoted | length) > 0 then 3 else 4 end;
  def line:
    (["⚠️", "🔴", "🟡", "🟢"][rank]) + " **[\(.repo)](\(.url))**"
    + ([
        (if .error != null then "could not read it: `\(.error | gsub("`"; ""))`" else empty end),
        (if (.promoted | length) > 0 then "promoted \(.promoted | links)" else empty end),
        (if .held != null then "held \(.held | link): \(.held.reasons | if length > 0 then join(", ") else "no hold recorded" end)" else empty end),
        (if (.red | length) > 0 then "red \(.red | links)" else empty end),
        (if (.security | length) > 0 then "security \(.security | links)" else empty end)
      ] | map(" · " + .) | join(""))
    | if length > $description_max then .[0:$description_max - 1] + "…" else . end;

  [add[] | .promoted |= map(select((.mergedAt | fromdateiso8601) >= $day_start))]
  | sort_by(rank, .repo) as $repos
  | ([$repos[] | select(rank == 4)] | length) as $quiet
  | ([$repos[] | select(rank < 4) | line]
     + if ($repos | length) == 0 then ["No repo calls dependency-branch.yml yet."]
       elif $quiet > 0 then ["Nothing to report in \($quiet) repo\(if $quiet == 1 then "" else "s" end)."]
       else [] end) as $lines
  # Discord red, yellow and green.
  | ([15548997, 15548997, 16705372, 5763719, 5763719][[$repos[] | rank] | min // 4]) as $color
  # Lines into messages of embeds, in one pass: onto the last embed while its description and the
  # message have room, else onto a new embed while the message has room, else a new message. The
  # title is counted against every message, though only the first carries it.
  | ($title | length) as $title_size
  | reduce $lines[] as $l ([];
      (if length > 0 then .[length - 1] else [] end) as $m
      | (($m | map(.description | length) | add // 0) + $title_size) as $used
      | if ($m | length) > 0 and ($m[-1].description | length) + 1 + ($l | length) <= $description_max
          and $used + 1 + ($l | length) <= $message_max
        then .[length - 1][($m | length) - 1].description += "\n" + $l
        elif ($m | length) > 0 and ($m | length) < $embeds_max and $used + ($l | length) <= $message_max
        then .[length - 1] += [{description: $l}]
        else . + [[{description: $l}]] end)
  | map(map(. + {color: $color}))
  | .[0][0] = {title: $title} + .[0][0]
  | .[] | {embeds: ., allowed_mentions: {parse: []}}'

render() {
  local zone=America/New_York now='' files=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --zone) zone=${2:?--zone needs a value}; shift 2 ;;
      --now) now=${2:?--now needs a value}; shift 2 ;;
      -*) usage ;;
      *) files+=("$1"); shift ;;
    esac
  done
  [[ ${#files[@]} -gt 0 ]] || usage
  check_zone "$zone"
  local now_epoch day_start title
  now_epoch=$(epoch "$now")
  # Midnight today in the zone. The offset is today's, so a DST change before now (2:00 on a
  # Sunday in New York) moves it by an hour; a Saturday digest never meets one.
  read -r day_start title < <(TZ=$zone jq -nr --argjson t "$now_epoch" '($t | localtime) as $l
    | "\($t - ($l[3] * 3600 + $l[4] * 60 + ($l[5] | floor))) Dependency digest · \($l | strftime("%a %d %b %Y"))"')
  jq -s -c --argjson day_start "$day_start" --arg title "$title" \
    --argjson description_max "$DESCRIPTION_MAX" --argjson message_max "$MESSAGE_MAX" \
    --argjson embeds_max "$EMBEDS_MAX" "$RENDER_JQ" "${files[@]}"
}

# --- post ------------------------------------------------------------------------

post() {
  [[ $# -eq 0 ]] || usage
  local webhook=${DISCORD_WEBHOOK:-} payload response code attempt sent count=0
  [[ -n $webhook ]] || fatal "DISCORD_WEBHOOK is not set"
  response=$(mktemp)
  while IFS= read -r payload; do
    [[ -n $payload ]] || continue
    count=$((count + 1))
    sent=false
    for attempt in 1 2 3; do
      code=$(curl -sS -o "$response" -w '%{http_code}' -H 'Content-Type: application/json' \
        --data-binary "$payload" "$webhook?wait=true") || code=000
      case $code in
        2??) sent=true; break ;;
        429)
          # Rate limited: Discord says how long to wait, in seconds.
          log "message $count: rate limited (attempt $attempt), waiting."
          sleep "$(jq -r '.retry_after // 1 | ceil' "$response" 2>/dev/null || echo 1)"
          ;;
        5?? | 000)
          log "message $count: HTTP $code (attempt $attempt), trying again."
          sleep 5
          ;;
        *) break ;;
      esac
    done
    if [[ $sent != true ]]; then
      echo "::error title=digest::Discord refused message $count (HTTP $code): $(head -c 500 "$response")" >&2
      rm -f "$response"
      exit 1
    fi
    log "message $count posted."
  done
  rm -f "$response"
  [[ $count -gt 0 ]] || fatal "no payloads on stdin"
}

[[ $# -gt 0 ]] || usage
command=$1
shift
case $command in
  due | collect | render | post) "$command" "$@" ;;
  *) usage ;;
esac
