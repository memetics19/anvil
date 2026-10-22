# Installing anvil

`anvil` is one binary. Install it with Homebrew, a .deb or .rpm package, or build it from
the repo. A packaged `anvil` comes without the repo, so fetch that once afterwards.

## Homebrew

On macOS, and on Linux with Homebrew:

```sh
brew install memetics19/tap/anvil
```

The formula installs the bash, zsh and fish completions too. `brew upgrade anvil` gets a
new release.

## Debian and Ubuntu

Download the .deb for your machine from the
[Releases](https://github.com/memetics19/anvil/releases) page, then install it with apt,
which also installs `git`:

```sh
sudo apt install ./anvil_<version>_amd64.deb      # or _arm64.deb
```

apt also suggests `ansible`, `terraform`, `vault`, `jq` and `age`. The lab needs them.
Terraform and Vault come from the HashiCorp apt repository.

## Fedora and RHEL

```sh
sudo dnf install ./anvil-<version>-1.x86_64.rpm   # or .aarch64.rpm
```

Both packages put the binary in `/usr/bin/anvil` and the completions where bash, zsh and
fish look for them. A signed apt repository is planned. Until then, each release lists the
packages as files.

## Check the download

Each release has `checksums.txt`. Check a file against it before you install:

```sh
sha256sum --check --ignore-missing checksums.txt
```

On macOS, use `shasum -a 256 --check --ignore-missing checksums.txt`.

## From source

You need Go. An older Go fetches the version that `cli/go.mod` names on its own.

```sh
git clone https://github.com/memetics19/anvil && cd anvil
make cli                                  # builds build/anvil
sudo install -m 755 build/anvil /usr/local/bin/anvil
source <(anvil completion zsh)            # or bash, or: anvil completion fish | source
```

Inside that checkout, `anvil` uses it, so you can skip the next step.

## Then fetch the repo

```sh
anvil fetch     # clones the repo into ~/.local/share/anvil/repo
anvil doctor    # tools, Keychain items, Vault and versions, read-only
```

A release binary fetches its own tag, for example `v0.1.0`. After an upgrade,
`anvil update` moves that copy to the new tag. The copy is in your home because runs
write `build/` and `terraform/.terraform` inside it. [cli.md](cli.md#anvil-fetch-and-anvil-update)
has the details.

## Versions and releases

Versions follow semver and start at 0.1.0. release-please reads the conventional commits
on `main` and keeps a release pull request with the next version and `CHANGELOG.md`.
Merging it tags `vX.Y.Z` and creates the GitHub Release. GoReleaser
(`.goreleaser.yaml`) then builds the archives, checksums, .deb and .rpm packages, adds
them to the release and pushes the formula to `memetics19/homebrew-tap`.

Every pull request and push to `main` runs the same build as a snapshot that publishes
nothing. Run it locally with:

```sh
make release-snapshot     # dist/: archives, checksums, .deb, .rpm, the formula
```

It runs the pinned GoReleaser through `go run`, so nothing is installed.
