#!/usr/bin/env bash
# Applies the three standard rulesets in rulesets/ to the neuroticsasquat-ch org, or to one
# tomboone/* repo, and brings them back in line with those files on every later run.
#
#   scripts/apply-rulesets.sh --org neuroticsasquat-ch [--dry-run]
#   scripts/apply-rulesets.sh --repo tomboone/<name> [--key-file <path>] [--dry-run]
#
# --org   writes them as org rulesets that apply to every repo whose custom property
#         `shared-ci` is `true`. The property must already exist on the org.
# --repo  writes them as repo rulesets, for repos in the personal tomboone account, which can't
#         use org rulesets. It also turns on *Allow auto-merge* and Dependabot security updates,
#         and sets the repo secret AUTOMATION_APP_PRIVATE_KEY when --key-file is given. Export the
#         key from 1Password for the run only, never into a kept file
#         (ops docs/runbooks/automation-app.md), for example:
#           --key-file <(op document get "ns-automation app key" --vault neuroticsasquat.ch)
# --dry-run  prints each body and what would change, and writes nothing.
#
# Idempotent: each ruleset is matched by name and created, or updated only when it differs from
# its file. The diff is printed before every update. Nothing is ever deleted, so a ruleset
# renamed in rulesets/ leaves the old one behind for a person to remove. Edit rulesets/, not
# the GitHub UI; the next run overwrites UI edits. The secret is the exception to "only when it
# differs": GitHub can't return a secret's value, so --key-file always rewrites it. That is how
# a key rotation reaches the repos. Leave --key-file off to keep the current secret.
#
# *Grouped security updates* has no REST or gh API (checked 2026-11-07), so --repo prints the
# one manual step for it instead.
#
# Runs on the host and needs your `gh` login and jq. --org needs the admin:org scope; --repo
# needs admin on the repo.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RULESETS=(main integration protect-updates)
PROPERTY=shared-ci
SECRET=AUTOMATION_APP_PRIVATE_KEY

# The fields a ruleset GET returns that this script manages, so a GET can be compared with a body.
FIELDS='{name, target, enforcement, conditions, bypass_actors, rules}'

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

ORG="" REPO="" KEY_FILE="" DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) ORG="${2:?--org needs an org name}"; shift 2 ;;
    --repo) REPO="${2:?--repo needs owner/name}"; shift 2 ;;
    --key-file) KEY_FILE="${2:?--key-file needs a path}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -n "$ORG" && -n "$REPO" ]] || [[ -z "$ORG" && -z "$REPO" ]]; then
  echo "give exactly one of --org or --repo" >&2
  usage
fi
if [[ -n "$ORG" && -n "$KEY_FILE" ]]; then
  echo "--key-file is for --repo only; neuroticsasquat-ch uses the org secret" >&2
  exit 2
fi
if [[ "$REPO" == neuroticsasquat-ch/* ]]; then
  echo "$REPO is covered by the org rulesets: run --org neuroticsasquat-ch and set the repo's" >&2
  echo "$PROPERTY property instead of writing per-repo copies" >&2
  exit 2
fi

if [[ -n "$ORG" ]]; then
  API="orgs/$ORG/rulesets"
  SOURCE_TYPE=Organization
else
  API="repos/$REPO/rulesets"
  SOURCE_TYPE=Repository
fi

CHANGES=0 SECRET_WRITTEN=false
note_change() {
  CHANGES=$((CHANGES + 1))
}

# The body for one rulesets/ file. Org rulesets also select their repos by the custom property.
body_for() {
  local file="$ROOT/rulesets/$1.json"
  if [[ -n "$ORG" ]]; then
    jq --arg property "$PROPERTY" '.conditions.repository_property = {
      include: [{name: $property, property_values: ["true"], source: "custom"}],
      exclude: []
    }' "$file"
  else
    jq . "$file"
  fi
}

apply_ruleset() {
  local body="$1" name id current
  name=$(jq -r .name <<<"$body")
  if $DRY_RUN; then
    echo "--- ruleset '$name' ($SOURCE_TYPE) body:"
    echo "$body"
  fi

  # includes_parents=false keeps org rulesets out of a repo's list; the source_type filter is
  # a second guard, since an org ruleset may share a name with a repo one during adoption.
  id=$(gh api "$API?per_page=100&includes_parents=false" \
    | jq -r --arg name "$name" --arg source "$SOURCE_TYPE" \
      '.[] | select(.source_type == $source and .name == $name) | .id')

  if [[ -z "$id" ]]; then
    if $DRY_RUN; then
      echo "ruleset '$name': would be created"
    else
      gh api -X POST "$API" --input - <<<"$body" >/dev/null
      echo "ruleset '$name': created"
    fi
    note_change
    return
  fi

  current=$(gh api "$API/$id" | jq -S "$FIELDS")
  if [[ "$current" == "$(jq -S . <<<"$body")" ]]; then
    echo "ruleset '$name': unchanged"
    return
  fi

  echo "ruleset '$name': differs from rulesets/:"
  diff -u --label "github ($id)" --label "rulesets/" \
    <(echo "$current") <(jq -S . <<<"$body") || true
  if $DRY_RUN; then
    echo "ruleset '$name': would be updated"
  else
    gh api -X PUT "$API/$id" --input - <<<"$body" >/dev/null
    echo "ruleset '$name': updated"
  fi
  note_change
}

# Org rulesets that target a property the org doesn't define fail to create, so check first.
check_property() {
  if gh api "orgs/$ORG/properties/schema/$PROPERTY" >/dev/null 2>&1; then
    echo "property '$PROPERTY': defined on $ORG"
    return
  fi
  if $DRY_RUN; then
    echo "property '$PROPERTY': NOT defined on $ORG; a real run would fail until it is"
  else
    echo "property '$PROPERTY' is not defined on $ORG; create it first" >&2
    exit 1
  fi
}

# Reads the key once: a process substitution (<(op …)) can be read only once.
read_key() {
  KEY=$(<"$KEY_FILE")
  if ! grep -q -- '-----BEGIN .*PRIVATE KEY-----' <<<"$KEY"; then
    echo "--key-file $KEY_FILE doesn't look like a PEM private key" >&2
    exit 1
  fi
}

apply_secret() {
  if [[ -z "$KEY_FILE" ]]; then
    if gh secret list -R "$REPO" --json name --jq '.[].name' | grep -qx "$SECRET"; then
      echo "secret $SECRET: present, not rewritten (no --key-file)"
    else
      echo "secret $SECRET: MISSING; re-run with --key-file to set it"
    fi
    return
  fi
  if $DRY_RUN; then
    echo "secret $SECRET: would be set from --key-file"
  else
    printf '%s\n' "$KEY" | gh secret set "$SECRET" -R "$REPO" >/dev/null
    echo "secret $SECRET: set from --key-file (GitHub can't compare secret values)"
  fi
  # Not counted as a change: it is rewritten on every --key-file run, so counting it would make
  # "no changes" unreachable. The summary line reports it separately.
  SECRET_WRITTEN=true
}

apply_auto_merge() {
  if [[ "$(gh api "repos/$REPO" --jq .allow_auto_merge)" == true ]]; then
    echo "auto-merge: already allowed"
    return
  fi
  if $DRY_RUN; then
    echo "auto-merge: would be allowed"
  else
    gh repo edit "$REPO" --enable-auto-merge >/dev/null
    echo "auto-merge: allowed"
  fi
  note_change
}

# Dependabot security updates need vulnerability alerts, and grouped security updates need both.
apply_security_updates() {
  if gh api "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1; then
    echo "Dependabot alerts: already on"
  elif $DRY_RUN; then
    echo "Dependabot alerts: would be turned on"
    note_change
  else
    gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null
    echo "Dependabot alerts: turned on"
    note_change
  fi

  if [[ "$(gh api "repos/$REPO/automated-security-fixes" --jq .enabled 2>/dev/null)" == true ]]; then
    echo "Dependabot security updates: already on"
  elif $DRY_RUN; then
    echo "Dependabot security updates: would be turned on"
    note_change
  else
    gh api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null
    echo "Dependabot security updates: turned on"
    note_change
  fi

  echo "MANUAL: turn on Grouped security updates (no API): https://github.com/$REPO/settings/security_analysis"
  echo "        → Dependabot → Grouped security updates → Enable"
}

if [[ -n "$ORG" ]]; then
  echo "== org $ORG (repos with $PROPERTY = true)$($DRY_RUN && echo ', dry run')"
  check_property
else
  echo "== repo $REPO$($DRY_RUN && echo ', dry run')"
  if [[ -n "$KEY_FILE" ]]; then read_key; fi
fi

for ruleset in "${RULESETS[@]}"; do
  apply_ruleset "$(body_for "$ruleset")"
done

if [[ -n "$REPO" ]]; then
  apply_auto_merge
  apply_security_updates
  apply_secret
fi

if [[ $CHANGES -eq 0 ]]; then
  summary="no changes"
elif $DRY_RUN; then
  summary="$CHANGES change(s) would be made"
else
  summary="$CHANGES change(s) made"
fi
if $SECRET_WRITTEN; then
  summary+="; secret $SECRET $($DRY_RUN && echo 'would be ')rewritten"
fi
echo "== $summary"
