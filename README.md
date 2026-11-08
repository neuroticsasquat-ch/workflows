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

## `python.yml`

CI for a uv-managed Python project. Repo specifics (lint and typecheck paths,
pytest options, markers) live in the project's tool config; the workflow runs
bare commands.

| Input | Default | Meaning |
|---|---|---|
| `working-directory` | `.` | Where `pyproject.toml`, `uv.lock` and `.python-version` live. |
| `postgres` | `""` | Postgres major to run as a service (`"16"`, `"17"`, `"18"`); empty means no service. Credentials `root`/`root`, database `postgres`, `localhost:5432`. |
| `typechecker` | `pyright` | `pyright` or `ty`. |

Setup, in order: checkout; `setup-uv` (cache keyed on that `uv.lock`); load
`.github/ci/env`; `uv sync --locked` (the `dev` group installs by default);
run `.github/ci/setup.sh`. Then the checks, each of which runs once setup has
succeeded, even after an earlier check failed:

- `uv run ruff check`
- `uv run ruff format --check`
- `uv run pyright`, or `uv run ty check`
- if `alembic.ini` is in the working directory or `pyproject.toml` has
  `[tool.alembic]`: a single-head check, then
  `uv run alembic upgrade head` and `uv run alembic check`
- `uv run pytest`

The repo contract:

- `pyproject.toml` with the dev tools in the `dev` dependency group, `uv.lock`,
  and `.python-version`, matching the Dockerfile's `FROM`. uv installs Python
  from `.python-version`, so no workflow names a version. Non-package apps set
  `tool.uv.package = false`.
- Optional CI convention files. Each is looked up in `.github/ci/` under the
  working directory first, then in `.github/ci/` at the repo root:
  - `env`: dotenv lines (`NAME=value`, optionally quoted, `#` comments)
    loaded into the job's environment. Test-only values, never secrets.
  - `setup.sh`: run with bash from the working directory after install and
    before the checks. It creates databases, schemas and extensions, loads
    fixtures, and starts extra services with `docker run`.

## `js.yml`

CI for a pnpm-managed JS or TypeScript project. What each check runs is set by
the project's package scripts; the workflow only runs them.

| Input | Default | Meaning |
|---|---|---|
| `working-directory` | `.` | Where `package.json`, `pnpm-lock.yaml` and `.node-version` live. |

Setup, in order: checkout; `pnpm/action-setup` (pnpm from `packageManager`);
`setup-node` (Node from `.node-version`, pnpm cache keyed on that
`pnpm-lock.yaml`); a check that `package.json` defines all four required
scripts, failing with an error that names any missing one;
`pnpm install --frozen-lockfile`. Then the checks, each of which runs once
install has succeeded, even after an earlier check failed:

- `pnpm run lint`
- `pnpm run typecheck`
- `pnpm run test`
- `pnpm run build`

The repo contract:

- `package.json` with `packageManager: pnpm@<version>` and the scripts `lint`
  (oxlint, failing on warnings: `oxlint --max-warnings 0`), `typecheck`, `test`
  and `build`. A plain-JS repo still defines all four, with real commands.
- `pnpm-lock.yaml`, and `.node-version` matching the Dockerfile's `FROM` where
  an image ships. The versions come from these files, so no workflow names one.
- pnpm only: there is no npm or Yarn path.

## This repo's own CI

`self-test.yml` runs on every PR and on push to `main`. It runs actionlint over
`.github/workflows/`, shellcheck over the scripts, and the fixture harness. Each
reusable workflow has a job there that calls it by local path
(`./.github/workflows/<name>.yml`) against a project in `fixtures/`:

| Job | Fixture | Covers |
|---|---|---|
| `python-plain` | `fixtures/python-plain` | no database, pyright |
| `python-plain-ty` | `fixtures/python-plain` | `typechecker: ty` |
| `python-postgres-alembic` | `fixtures/python-postgres-alembic` | `postgres: "17"`, `.github/ci/env` and `setup.sh`, the Alembic checks |
| `js-pnpm` | `fixtures/js-pnpm` | pnpm and Node from `packageManager` and `.node-version`; oxlint, `tsc -b`, vitest, `vite build` |

The harness also holds the gate self-test, which checks `actions/gate` on
success, skipped, failed and cancelled jobs. Everything ends in a job named
`ci`, decided by `./actions/gate`, the only required check.

The actions used inside the workflows are pinned to exact versions. Dependabot
bumps them weekly into `updates/dependencies`.
