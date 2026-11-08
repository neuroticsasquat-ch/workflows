#!/usr/bin/env bash
# Decide the aggregate `ci` check from the JSON of `toJSON(needs)`.
#
# Usage: gate.sh '<json>'
#
# Passes when every needed job's result is `success` or `skipped`. Anything
# else fails, `failure` and `cancelled` included. That also covers input that
# isn't the `needs` object: an entry with no `result` reports as `missing`, and
# JSON that isn't an object stops the gate before it decides anything.
#
# Prints a job -> result table to the log and, on a runner, to the step summary.
set -euo pipefail

needs=${1:?usage: gate.sh '<toJSON(needs)>'}

if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$needs"; then
  echo "::error title=gate::input is not a JSON object; pass needs: \${{ toJSON(needs) }}"
  exit 1
fi

# One "job<TAB>result" line per needed job, sorted by job name.
rows=$(jq -r '
  to_entries
  | sort_by(.key)[]
  | [.key, ((.value | objects | .result | strings) // "missing")]
  | @tsv
' <<<"$needs")

{
  echo "| Job | Result |"
  echo "|---|---|"
  if [[ -n $rows ]]; then
    while IFS=$'\t' read -r job result; do
      echo "| \`$job\` | $result |"
    done <<<"$rows"
  else
    echo "| _(no needed jobs)_ | |"
  fi
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

failed=0
if [[ -n $rows ]]; then
  while IFS=$'\t' read -r job result; do
    case $result in
      success | skipped) ;;
      *)
        echo "::error title=gate::job '$job' finished as $result"
        failed=1
        ;;
    esac
  done <<<"$rows"
fi

exit "$failed"
