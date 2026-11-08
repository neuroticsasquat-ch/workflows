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
| `integration.json` | `Integration branches — shared rules` | `updates/*`, `release/*`: no force-push, PR (squash or merge), `ci` green | the `ns-automation` app (`actor_id` 5661286, its App ID), always |
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
re-running the script, not in the GitHub UI. In the bodies, `integration_id`
15368 is the GitHub Actions app, so only an Actions run can satisfy `ci`.
*Grouped security updates* has no API, so `--repo` prints the settings link to
turn it on by hand.

## The `ci` gate

Every repo exposes one required check, `ci`, and `actions/gate` decides it. The
gate fails if any job in `needs` failed or was cancelled; `success` and
`skipped` pass, so path-filtered jobs that didn't run don't block a PR. It
prints a job → result table to the log and the step summary.

```yaml
jobs:
  python:
    uses: neuroticsasquat-ch/workflows/.github/workflows/python.yml@v1
  ci:                       # the one required check; the name is the contract
    if: always()
    needs: [python]         # every other job
    runs-on: ubuntu-latest
    steps:
      - uses: neuroticsasquat-ch/workflows/actions/gate@v1
        with:
          needs: ${{ toJSON(needs) }}
```

`ci` has to be a plain job like this one. A job that calls a reusable workflow
reports as `<caller> / <called>` (`ci / gate`), and the rulesets require exactly
`ci`. That's why the gate is a composite action and not a reusable workflow.

## This repo's own CI

`self-test.yml` runs on every PR and on push to `main`. It runs actionlint over
`.github/workflows/`, shellcheck over the scripts, and the fixture harness. As
the reusable workflows land, each one gets a job there that calls it by local
path (`./.github/workflows/<name>.yml`) against a project in `fixtures/`. For
now the harness holds the gate self-test, which checks `actions/gate` on
success, skipped, failed and cancelled jobs. Everything ends in a job named
`ci`, decided by `./actions/gate`, the only required check.

The actions used inside the workflows are pinned to exact versions. Dependabot
bumps them weekly into `updates/dependencies`.
