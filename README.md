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
  [RELEASING.md](RELEASING.md) has the commands.
- A breaking change to an input or to the repo contract is `v2`, adopted repo
  by repo.
- Don't pin a caller to `@main` or to an exact `v1.x.y` tag. Callers'
  Dependabot ignores `neuroticsasquat-ch/workflows`.

The decision record is ADR-0005 in the ops repo
(`docs/adr/0005-shared-workflows-public-floating-v1.md`).

## Layout

| Path | Holds |
|---|---|
| `.github/workflows/` | the reusable workflows (`on: workflow_call`), `self-test.yml` (this repo's own CI) and `digest.yml` (the Saturday dependency digest) |
| `actions/` | composite actions used by the workflows |
| `rulesets/` | the ruleset bodies (JSON), the single definition |
| `scripts/` | tooling, such as applying the rulesets |
| `fixtures/` | small projects that `self-test.yml` runs each workflow against |
| `RELEASING.md` | how to cut a `v1.x.y` release and move `v1` |

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

### Mixed repos

A repo with Python in `backend/` and pnpm in `frontend/` adds a `changes` job
and gates each language's job on its filter. A skipped job passes the gate, so
a frontend-only change skips `python` and `ci` still goes green. Extra checks
are further jobs in `ci`'s needs. `self-test.yml` runs this shape against
`fixtures/mixed`.

```yaml
jobs:
  changes:
    runs-on: ubuntu-latest
    permissions: { contents: read, pull-requests: read }
    outputs:
      backend: ${{ steps.filter.outputs.backend }}
      frontend: ${{ steps.filter.outputs.frontend }}
    steps:
      # Credentials stay persisted: on a push, paths-filter fetches the
      # previous commit with git, which a private repo refuses anonymously.
      - uses: actions/checkout@v7.0.1
      - id: filter
        uses: dorny/paths-filter@v4.0.3
        with:
          filters: |
            backend: [backend/**, .github/workflows/ci.yml]
            frontend: [frontend/**, .github/workflows/ci.yml]
  python:
    needs: changes
    if: needs.changes.outputs.backend == 'true'
    uses: neuroticsasquat-ch/workflows/.github/workflows/python.yml@v1
    with:
      working-directory: backend
  js:
    needs: changes
    if: needs.changes.outputs.frontend == 'true'
    uses: neuroticsasquat-ch/workflows/.github/workflows/js.yml@v1
    with:
      working-directory: frontend
  ci:
    if: always()
    needs: [changes, python, js]   # extras included
    runs-on: ubuntu-latest
    steps:
      - uses: neuroticsasquat-ch/workflows/actions/gate@v1
        with:
          needs: ${{ toJSON(needs) }}
```

- Each filter also matches `ci.yml`, so a change to the caller itself runs
  both jobs.
- On a PR, paths-filter lists the PR's files through the API, which needs
  `pull-requests: read`.
- `changes` is in `ci`'s needs too: if it fails, the jobs it gates are skipped,
  and only its own failure turns `ci` red.
- A `publish` job after `ci` must test `needs.ci.result == 'success'` (see
  `image-publish.yml` below). Otherwise it is skipped on every push where a
  filter matched nothing.

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

## `image-check.yml`

The PR check for every repo whose image ships (GHCR-published or
Coolify-built). It builds the image without pushing, checks that it doesn't
run as root, and runs the repo's smoke test against it. Publishing is
`image-publish.yml`'s job. Dev-only Dockerfiles don't call it.

| Input | Default | Meaning |
|---|---|---|
| `name` | repo name | The local tag is `<name>:ci` and the GHA cache scope is `<name>`. Lowercased. |
| `context` | `.` | Build context. |
| `file` | `<context>/Dockerfile` | Dockerfile path, such as `Dockerfile.prod`. |
| `target` | `""` | Stage to build; empty means the last stage. |
| `platforms` | `linux/amd64` | The platform to build for. One only: the image is loaded into the runner's Docker. |
| `build-args` | `""` | Multiline `KEY=value`. |
| `allow-root` | `false` | Skip the non-root check. |

Setup, in order: checkout; `docker/setup-buildx-action`;
`docker/build-push-action` with `push: false`, `load: true`, the tag
`<name>:ci` and the cache `type=gha,scope=<name>` (`mode=max`). Then the
checks, each of which runs once the build has succeeded, even after an earlier
check failed:

- `docker run --rm --entrypoint id <name>:ci -u` must print something other
  than `0`. The image needs an `id` binary for this.
- `.github/ci/smoke.sh`, if it exists, run with bash from the build context
  with `<name>:ci` as `$1`. Like the other convention files, it is looked up in
  `.github/ci/` under the build context first, then at the repo root.

The repo contract:

- The image runs as a non-root user: a `USER` line in the Dockerfile. An image
  that genuinely has to run as root (a volume-permission case found during
  adoption) passes `allow-root: true`, with a comment at the call saying why.
  It is not a default.
- Optionally `.github/ci/smoke.sh`: it receives the image tag as `$1`, runs the
  image (a CLI `--help`, an import, a health endpoint) and exits non-zero on
  failure.
- A repo with several images calls the workflow from a `strategy.matrix`, one
  `name` per image.

## `image-publish.yml`

Pushes a repo's image to GHCR as `sha-<7>` (the commit's short SHA) and as
`latest`, with no other tags. It replaces each repo's separate `image.yml`, and
runs from the CI caller only after `ci` passed on that commit, so a red commit
never becomes `latest`. The checks are `image-check.yml`'s, already run in
`ci`; this workflow only builds and pushes.

| Input | Default | Meaning |
|---|---|---|
| `image` | required | The image without a tag, such as `ghcr.io/tomboone/mlb-today`. Must be on `ghcr.io`, under the calling repo's owner: `GITHUB_TOKEN` can't push anywhere else. |
| `name` | repo name | The GHA cache scope, shared with `image-check.yml`. Lowercased. Pass the same `name` as the image-check call. |
| `context` | `.` | Build context. |
| `file` | `<context>/Dockerfile` | Dockerfile path, such as `Dockerfile.prod`. |
| `target` | `""` | Stage to build; empty means the last stage. |
| `platforms` | `linux/amd64` | Comma-separated platforms. QEMU is set up when any of them is not `linux/amd64`. |
| `build-args` | `""` | Multiline `KEY=value`. |

Steps, in order: checkout; a check that `image` is a `ghcr.io` image without
a tag, and the cache scope resolved; a check that the commit is still the tip
of `github.ref`; `docker/setup-qemu-action`, only when `platforms` needs it;
`docker/setup-buildx-action`; `docker/login-action` to `ghcr.io` as
`github.actor` with `GITHUB_TOKEN`; `docker/metadata-action` with
`flavor: latest=false` and the tags `type=raw,value=latest` (enabled only when
the commit is the tip) and `type=sha,prefix=sha-,format=short`;
`docker/build-push-action` with `push: true` and the cache
`type=gha,scope=<name>` (`mode=max`).

The caller runs it as a `publish` job in the same workflow as `ci`:

```yaml
jobs:
  # ... python, image (image-check.yml), ci ...
  publish:
    # Push to main only, never on a PR, and only when ci itself succeeded.
    if: ${{ !cancelled() && github.event_name == 'push' && needs.ci.result == 'success' }}
    needs: ci
    concurrency: { group: "publish-${{ github.ref }}", cancel-in-progress: false }
    permissions: { contents: read, packages: write }
    uses: neuroticsasquat-ch/workflows/.github/workflows/image-publish.yml@v1
    with:
      image: ghcr.io/tomboone/mlb-today
```

- `needs.ci.result == 'success'` is what holds a publish back: a red or
  cancelled `ci` skips `publish`. Test it explicitly. A condition without a
  status function gets an implicit `success()`, and for a job that is false
  when *any* job upstream of `ci` was skipped, such as a path-filtered job or
  self-test's `gate-input-skipped`. So `if: github.event_name == 'push'`
  alone never publishes from a repo with a skipped job. `!cancelled()`
  replaces the implicit `success()`.
- The job-level `concurrency` runs publishes one at a time and never cancels a
  running one. It does not keep push order: publishes start as each commit's
  `ci` finishes. The tip check covers that. A commit that is no longer the
  branch tip when its publish runs gets its `sha-` tag but leaves `latest`
  alone, so `latest` never regresses to an older commit. The check depends on
  the concurrency group, so keep it.
- A concurrency group holds one running and one pending run. When a third
  publish queues, GitHub cancels the pending one, so that commit gets no
  `sha-` tag. That takes three merges within one publish's runtime, and
  `latest` still lands on the newest.
- `latest` can lag. If a newer commit's `ci` fails, the green commit before it
  was no longer the tip when it published, so `latest` stays where it was
  until the next green commit.
- The caller grants `packages: write`. Without it the run fails at startup.
- Deploy steps after the publish (Azure, Tofu) stay caller jobs that need
  `publish`.

## `dependency-branch.yml`

Keeps a repo's dependency branch, `updates/dependencies`, current with
`main`, auto-merges Dependabot PRs into it, and keeps the promotion PR from it
to `main` open. With `auto-promote`, it also merges that PR and Dependabot
security updates inside the window. It replaces
`merge-main-into-dependencies.yml`, the weekly PR that merged `main` back in,
and the hand-merging of Dependabot PRs.

It acts as the automation app (ADR-0007 in the ops repo), not `GITHUB_TOKEN`.
The app is the only bypass actor on the integration ruleset, so its sync push
to `updates/dependencies` is allowed. And the promotion PR it opens gets a `ci`
check, which a PR opened by `GITHUB_TOKEN` never does. `main` still takes a PR
and a green `ci` from the app like anyone else.

| Input / secret | Default | Meaning |
|---|---|---|
| `auto-promote` | `false` | Merge the promotion PR, and green security updates, when the guards hold (steps 4 and 5). Off, nothing is ever merged into `main`. Every adopter except fundlens passes `true`. |
| `window` | `Sat 10:00-18:00 America/New_York` | When `auto-promote` may merge: `<Day> <HH:MM>-<HH:MM> <IANA zone>`, evaluated in that zone (DST included), start inclusive, end exclusive, within one day (so the latest end is `23:59`). A malformed window or unknown zone fails the run. |
| `app-client-id` | the app's client ID | Public, so it's the default. |
| secret `app-private-key` | required | The app's private key, from `AUTOMATION_APP_PRIVATE_KEY`. Pass it explicitly: `secrets: inherit` doesn't cross owners. |

Each run mints an app token with `actions/create-github-app-token` and checks
out `updates/dependencies` with full history using it. It checks out
`scripts/` from this repo at the commit the caller's `@v1` resolved to
(`job.workflow_repository` and `job.workflow_sha`), and runs
`scripts/dependency-branch.sh`:

1. **Sync.** If `main` isn't an ancestor of `updates/dependencies`, merge it
   in and push as the app. When the branch isn't ahead, that's a fast-forward
   and can't conflict. A conflicting merge is abandoned and remembered.
2. **Auto-merge.** Every open Dependabot PR into `updates/dependencies`
   without auto-merge, whose `ci` hasn't finished, gets it (merge commit),
   majors included, and merges once `ci` is green. One whose `ci` is already
   green and that is mergeable is merged directly, because GitHub refuses
   auto-merge on it. One whose `ci` is red is left open for a person. The
   script reads `ci` itself instead of relying on GitHub to hold the merge
   back, because the app bypasses the integration ruleset.
3. **Promotion PR.** While `updates/dependencies` differs in content from
   `main`, a PR into `main` titled `chore(deps): promote dependency updates`
   stays open. Its body lists the Dependabot PRs merged into the branch since
   `main` last contained it, and is rewritten when that list changes. After a
   conflicting sync, the PR gets a comment with the steps to resolve the
   conflict through a PR of your own. The comment is posted once for each
   `main` commit, not on every run.
4. **Promote.** The promotion PR is merged (merge commit) as the app only when
   no guard holds. Otherwise it stays open, and every failing guard is
   recorded, in this order:

   | Reason | Holds when |
   |---|---|
   | `opted-out` | `auto-promote` is off. |
   | `conflict` | this run's sync conflicted, or GitHub calls the PR `DIRTY`. |
   | `major` | a Dependabot commit on the branch since `main` bumps a major version, or carries no update metadata (fail safe). |
   | `ci-red` | `ci` on the PR head finished with anything but success. |
   | `unsettled` | an open Dependabot PR into the branch has `ci` that isn't red. |
   | `ci-pending` | `ci` on the PR head hasn't finished, or the head isn't the synced branch yet. |
   | `outside-window` | now is outside `window`. Left out when `opted-out` is recorded. |

   Major bumps are read from the `updated-dependencies:` metadata block in
   Dependabot's commit messages, the one `dependabot/fetch-metadata` parses.
   Security updates leave `update-type` out of that block, so for an entry
   without one the message's `from A to B` decides: a change in the leading
   version number is a major, and versions it can't find or read count as one.
   A held PR's body ends in the reasons, plus a marker the digest reads. A
   promoting run merges the PR and leaves its body alone.

   ```
   **Held:** major, outside-window
   <!-- dependency-branch:hold major outside-window -->
   ```
5. **Security updates.** Dependabot opens security updates against `main`
   whatever `target-branch` says. Each open one is merged (merge commit) when
   none of `opted-out`, `major`, `ci-red`, `ci-pending` or `outside-window`
   holds, `major` including a PR with no Dependabot commit to read metadata
   from. A held one is left alone. The `main` ruleset still applies, since
   the app doesn't bypass it. After such a merge, the next scheduled run syncs
   `main` into the branch.

The action list goes to the step summary, including `promote <n>`,
`hold <n> <reason>...`, `security-merge <n>` and `security-hold <n> <reason>...`.
The script runs anywhere with `gh` logged in:
`scripts/dependency-branch.sh --dry-run [--auto-promote]` in a clone prints
what a run would do, without pushing or writing to GitHub.

The caller, `.github/workflows/dependencies.yml`:

```yaml
name: dependencies
on:
  push:
    branches: [updates/dependencies]
  schedule:
    - cron: "0 11 * * *"         # daily, before Dependabot's Saturday 09:00 ET run
    - cron: "*/30 13-23 * * 6"   # every 30 min on Saturdays, covering the window in EST and EDT
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: dependencies
  cancel-in-progress: false
jobs:
  dependency-branch:
    uses: neuroticsasquat-ch/workflows/.github/workflows/dependency-branch.yml@v1
    with:
      auto-promote: true
    secrets:
      app-private-key: ${{ secrets.AUTOMATION_APP_PRIVATE_KEY }}
```

- The `push` trigger reacts to a Dependabot PR merging, so the promotion PR's
  body is current within minutes. The schedules catch everything else, such
  as `main` moving.
- One run at a time, never cancelled. Two runs pushing the same sync would
  race.
- The repo needs *Allow auto-merge* on, the app installed, the
  `AUTOMATION_APP_PRIVATE_KEY` secret and the rulesets: the repo contract in
  the ops project spec.

## `digest.yml`

The Saturday dependency digest. It runs in this repo, not in callers, and
posts one message to Discord `#dependencies` at 18:30 America/New_York, after
the promotion window closes. Discord is the only alert channel (ADR-0002 in the
ops repo), and `#dependencies` can be muted on its own. The digest only reads.
It never acts on a repo.

It acts as the automation app, minting one token per installation
(`neuroticsasquat-ch` and `tomboone`). It lists every unarchived repo the app
is installed on that has `.github/workflows/dependencies.yml` (the
`dependency-branch.yml` caller) and makes one GraphQL query per repo. Each
repo gets a line when it has any of these:

| | Shows |
|---|---|
| 🟢 promoted | the promotion PR (`updates/dependencies` into the default branch) merged today, New York time |
| 🟡 held | the open promotion PR and its reasons, read from the `<!-- dependency-branch:hold … -->` marker (`no hold recorded` when it has none) |
| 🔴 red | open Dependabot PRs into `updates/dependencies` whose `ci` finished with anything but success |
| 🟡 security | open Dependabot PRs into the default branch |
| ⚠️ | a repo whose query failed, so it isn't silently missing |

The icon is the worst of the line's entries. Lines are sorted worst first, and
the repos with nothing to report collapse into a count on the last line, so
every adopted repo appears exactly once. A digest too long for Discord's limits
(4096 characters an embed, 6000 and 10 embeds a message) is split over several
messages.

GitHub's cron runs in UTC, so there are two: `30 22 * * 6` (18:30 EDT) and
`30 23 * * 6` (18:30 EST). Each run passes the cron that fired to
`scripts/digest.sh due`. That prints `true` only when the time the cron was due,
not the time the run started, is Saturday 18:30 in New York, so exactly one of
them posts each Saturday, across DST changes and late starts. GitHub turns off
scheduled workflows in a public repo after 60 days with no activity and says
so by email. Re-enable *digest* in the Actions tab if a quiet stretch stops it.

It needs the org secret `AUTOMATION_APP_PRIVATE_KEY` and the repo secret
`DISCORD_DEPENDENCIES_WEBHOOK`. Run it by hand from the Actions tab
(*digest* → *Run workflow*). A run by hand always posts. Tick `dry-run` to
write the digest to the run summary only. The script's steps also run on their
own:

```sh
scripts/digest.sh due --schedule "30 23 * * 6" [--now 2026-11-07T23:30:00Z]
GH_TOKEN=<installation token> scripts/digest.sh collect >ns.json
scripts/digest.sh render [--now <instant>] ns.json tb.json >payloads.jsonl
DISCORD_WEBHOOK=<url> scripts/digest.sh post <payloads.jsonl
```

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
| `image-docker` | `fixtures/docker` | the last stage, which runs as a non-root user; `build-args`; `.github/ci/smoke.sh` runs the image's CLI |
| `image-docker-allow-root` | `fixtures/docker` | an explicit `file`, `target: runtime-root` (no `USER` line), `allow-root: true` |
| `publish` | `fixtures/docker` | `image-publish.yml`, called the way a caller calls it (after `ci`, push to `main` only), pushing `ghcr.io/neuroticsasquat-ch/workflows-fixture` |

`dependency-branch.yml` can't be called here: it needs the app's private key.
Its script is tested instead by the `dependency-branch` job, which runs
`fixtures/dependency-branch/test.sh`. That builds scratch repos with
`git init` and a local bare remote and runs the script against them, with
`fixtures/dependency-branch/bin/gh` standing in for `gh`. Three dry-run cases
check the action list: behind only, ahead and behind merging cleanly, and
ahead and behind conflicting. Real runs then check that the clean merge lands
on the remote, the conflict leaves it alone, and the conflict comment isn't
repeated.

`digest.yml` needs the app's key and the webhook, so it isn't called here
either. The `digest` job runs `fixtures/digest/test.sh` instead. It checks the
zone check on both crons for every Saturday of 2026, including late starts. It
runs `collect` against canned GitHub answers (`fixtures/digest/bin/gh`),
renders the exact digest, splits a long one within Discord's limits, and posts
through a stand-in `curl` that rate-limits once.

A job that calls a reusable workflow can't take `continue-on-error`, so the
failing cases (a root image without `allow-root`, a smoke script that exits 1)
aren't in the harness. They are checked on a throwaway PR when the workflow
changes.

The harness also holds the gate self-test, which checks `actions/gate` on
success, skipped, failed and cancelled jobs. Every job except `publish` ends
in a job named `ci`, decided by `./actions/gate`, the only required check.
`publish` needs `ci`, so it can't also be in `ci`'s needs. It runs only on push
to `main`, so a PR never publishes, and a red `ci` skips it.

The actions used inside the workflows are pinned to exact versions. Dependabot
bumps them weekly into `updates/dependencies`.
