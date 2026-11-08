# Releasing

Callers float on the `v1` tag (ADR-0005 in the ops repo). Moving `v1` changes
what every adopted repo runs on its next CI run, so a release is cut by hand,
from `main`, only once this repo's own CI is green on the commit being
released.

Releases are tagged `v1.x.y`. `v1` always points at the latest `v1.x.y`.

## Pick the version

| Change | Release |
|---|---|
| A fix, an action bump, a doc change that ships in the tag | `v1.x.(y+1)` |
| A new optional input, a new workflow or action, a new optional convention file | `v1.(x+1).0` |
| A breaking change: an input removed or renamed, a new required input, a default that fails existing callers, or a change to the repo contract (a new required file, script or setting, or a renamed check) | `v2.0.0`. See [A breaking change](#a-breaking-change). Never moved into `v1`. |

List the current releases to find the last one:

```sh
git fetch origin --tags --force
git tag --list 'v1.*' --sort=-v:refname
```

## Cut a release

The commands below release `v1.4.2`. Use the version picked above.

1. Merge the PR into `main`.

2. Wait until `self-test` is green on that merge commit. This must print
   `success` for the merge commit's SHA:

   ```sh
   gh run list --workflow self-test.yml --branch main --event push --limit 1 \
     --json headSha,conclusion --jq '.[0] | "\(.headSha) \(.conclusion)"'
   ```

3. Check out exactly that commit:

   ```sh
   git checkout main
   git pull --ff-only origin main
   git log -1 --format=%H
   ```

   The SHA printed last must match step 2's SHA. If it doesn't, `main` has
   moved on. Go back to step 2 for the newer commit.

4. Tag the release and push the tag:

   ```sh
   git tag v1.4.2
   git push origin v1.4.2
   ```

5. Move `v1` to the release and force-push it:

   ```sh
   git tag -f v1 v1.4.2
   git push -f origin v1
   ```

6. Check that both tags name the same commit:

   ```sh
   git ls-remote --tags origin v1 v1.4.2
   ```

   It prints two lines, `refs/tags/v1` and `refs/tags/v1.4.2`, with the same
   SHA.

`v1.x.y` tags never move once pushed. Only `v1` moves.

## Roll back

If a release breaks callers, move `v1` back to the previous release. This
example goes back to `v1.4.1`:

```sh
git fetch origin --tags --force
git tag -f v1 v1.4.1
git push -f origin v1
git ls-remote --tags origin v1 v1.4.1
```

Then fix forward on `main` and cut `v1.4.3`. Don't delete or re-point
`v1.4.2`.

## A breaking change

A breaking change ships as `v2`, never in `v1`. `v1` stays on its last
`v1.x.y`, and callers move to `@v2` repo by repo, each in its own PR.

1. Merge the change into `main` and wait for `self-test` on it (steps 1–3
   above).
2. Tag `v2.0.0` and create `v2`:

   ```sh
   git tag v2.0.0
   git push origin v2.0.0
   git tag v2 v2.0.0
   git push origin v2
   ```

3. Update the `@v1` references in `README.md` and the ops project spec's caller
   templates to `@v2`.

From then on, `main` is the `v2` line, and every release above uses `v2` and
`v2.x.y` in place of `v1` and `v1.x.y`.
