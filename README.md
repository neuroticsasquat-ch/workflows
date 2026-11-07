# workflows

Shared GitHub Actions for the `neuroticsasquat-ch/*` and `tomboone/*` repos:
reusable workflows for CI, image checks, image publishing and dependency-branch
automation, plus the rulesets every repo is held to.

The repo is public because a private repo's reusable workflows can only be
called by repos with the same owner, and the callers span two owners. Nothing
in it is secret.

## Pin `@v1`

Callers reference these workflows at the floating `v1` tag:

```yaml
jobs:
  ci:
    uses: neuroticsasquat-ch/workflows/.github/workflows/python.yml@v1
```

- Releases are tagged `v1.x.y`. `v1` is moved to a release by hand, and only
  after this repo's own CI (`self-test.yml`) is green.
- A breaking change to an input or to the repo contract is `v2`, adopted repo
  by repo.
- Don't pin a caller to `@main` or to an exact `v1.x.y` tag. Callers'
  Dependabot ignores `neuroticsasquat-ch/workflows`.

The decision record is ADR-0005 in the ops repo
(`docs/adr/0005-shared-workflows-public-floating-v1.md`).

## Layout

| Path | Holds |
|---|---|
| `.github/workflows/` | the reusable workflows (`on: workflow_call`) and `self-test.yml`, this repo's own CI |
| `actions/` | composite actions used by the workflows |
| `rulesets/` | the ruleset bodies (JSON), the single definition |
| `scripts/` | tooling, such as applying the rulesets |
| `fixtures/` | small projects that `self-test.yml` runs each workflow against |

## Rulesets

`rulesets/` holds the three rulesets every repo is held to, and
`scripts/apply-rulesets.sh` applies them:

| File | Ruleset | Targets | Bypass |
|---|---|---|---|
| `main.json` | `main` | the default branch: no deletion or force-push, PR merged as a merge commit, `ci` green | none |
| `integration.json` | `Integration branches — shared rules` | `updates/*`, `release/*`: no force-push, PR (squash or merge), `ci` green | the `ns-automation` app, always |
| `protect-updates.json` | `Protect updates branches from deletion` | `updates/*`: no deletion | none |

```sh
# neuroticsasquat-ch: org rulesets for every repo whose `shared-ci` property is `true`
scripts/apply-rulesets.sh --org neuroticsasquat-ch [--dry-run]

# a tomboone/* repo: repo rulesets, auto-merge, security updates and the app secret
scripts/apply-rulesets.sh --repo tomboone/<name> \
  --key-file <(op document get "ns-automation app key" --vault neuroticsasquat.ch) [--dry-run]
```

The script is idempotent. It matches rulesets by name, prints a diff before
each update, and never deletes. Change a ruleset by editing its file and
re-running the script, not in the GitHub UI. *Grouped security updates* has no
API, so `--repo` prints the settings link to turn it on by hand.

## This repo's own CI

`self-test.yml` runs on every PR and on push to `main`. It runs actionlint over
`.github/workflows/` and ends in a job named `ci`, the only required check.

The actions used inside the workflows are pinned to exact versions. Dependabot
bumps them weekly into `updates/dependencies`.
