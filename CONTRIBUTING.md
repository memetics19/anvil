# Contributing

Issues and pull requests are welcome. This page covers the checks to run, the commit style,
and how pull requests are merged and stacked.

## Before you open a pull request

```sh
make test            # lint, secrets scan, Go tests, unit and integration tests
```

CI runs the same, plus Trivy (`.github/workflows/security.yml`). The integration tests need
Linux with passwordless sudo. On macOS they print `SKIP`, and CI runs them on Ubuntu. The
layers and how to write a test are in [tests/README.md](tests/README.md).

The CLI's layout is in [docs/cli.md](docs/cli.md#code-layout). A new command goes in its
own package under `cli/internal/` and is imported in `cli/cmd/anvil/main.go`.

Nothing site specific goes in a commit: no IP or MAC addresses, no internal names, no
secrets. They live in Vault and are read at run time ([docs/secrets.md](docs/secrets.md)).
`make secrets-scan` checks for the obvious ones.

## Commits

[Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`,
`ci:`, `build:`, `test:`, `refactor:`, `chore:`, with a scope when it helps, for example
`fix(pulse): ...`. A breaking change gets a `!` (`feat!: ...`) and a `BREAKING CHANGE:`
footer. release-please turns these into the version and the changelog.

No `Co-Authored-By` or other generated attribution lines.

## Pull requests

One logical change per pull request, small enough to review in one sitting. Put a change
and the tests it needs in the same commit, so every commit passes CI on its own.

Pull requests are squash-merged: the title becomes the commit on `main`, so it must be a
Conventional Commit too.

## Stacked pull requests

When a change builds on another one that is still in review, open it against that branch
instead of `main`. Its diff then shows only the new work.

```sh
git switch -c feat/a main
# commit, then
git push -u origin feat/a && gh pr create --base main

git switch -c feat/b feat/a
# commit, then
git push -u origin feat/b && gh pr create --base feat/a
```

Merge from the bottom of the stack up. When `feat/a` is merged, GitHub deletes its branch
and moves `feat/b` onto `main` by itself. Never merge `feat/b` while its base is still
`feat/a`: it would land in that branch, not in `main`.

A squash merge gives `main` a new commit, so `feat/b` still carries the old commits of
`feat/a`. Rebase it before you merge it:

```sh
git fetch origin
git rebase --onto origin/main feat/a feat/b    # only feat/b's own commits
git push --force-with-lease
```

If a lower branch changes during review, carry the change up the stack:

```sh
git switch feat/b
git rebase --update-refs feat/a
git push --force-with-lease origin feat/a feat/b
```

[git-town](https://www.git-town.com) or [Graphite](https://graphite.dev) do these steps for
you if you stack often.

## Releases

Merging to `main` keeps a release pull request up to date. Merging that one tags the
version, publishes the GitHub Release with the binaries, the .deb and .rpm packages and the
Homebrew formula, and the homelab's apt repository picks the packages up within 30 minutes.

The release workflow merges it by itself every Monday at 10:00 IST when `main` is green
and the release holds no breaking change. A breaking release is merged by hand. See
[docs/install.md](docs/install.md#versions-and-releases).
