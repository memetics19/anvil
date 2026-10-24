# Installing anvil

`anvil` is one binary. Install it with one command, Homebrew, a .deb or .rpm package, or
build it from the repo. A packaged `anvil` comes without the repo, so fetch that once
afterwards.

## One command

On macOS and Linux, amd64 or arm64:

```sh
curl -fsSL https://memetics19.github.io/anvil/install.sh | sh
```

The script is [scripts/install.sh](../scripts/install.sh), served with these docs. It
downloads the archive for your machine from the latest release, checks it against the
release's `checksums.txt`, and puts `anvil` in `/usr/local/bin`, or in `~/.local/bin` when
`/usr/local/bin` is not writable. It needs `curl`, `tar` and `sha256sum` or `shasum`.

To pick a version or a place, set these before `sh`:

```sh
curl -fsSL https://memetics19.github.io/anvil/install.sh | ANVIL_VERSION=v0.1.0 ANVIL_INSTALL_DIR=~/bin sh
```

Run the same command again to upgrade. To read the script before running it, download it
first:

```sh
curl -fsSLO https://memetics19.github.io/anvil/install.sh
less install.sh
sh install.sh
```

## Homebrew

On macOS, and on Linux with Homebrew:

```sh
brew tap memetics19/anvil https://github.com/memetics19/anvil
brew install anvil
```

The tap is this repo. Its `Formula/` directory holds the formula, which each release
updates. The first command is needed once.

The formula installs the bash, zsh and fish completions too. `brew upgrade anvil` gets a
new release.

## Debian and Ubuntu

The apt repository at `apt.shreeda.xyz` has every release for amd64 and arm64, signed. Add
it once, and `apt upgrade` brings new releases:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.shreeda.xyz/anvil.gpg | sudo tee /etc/apt/keyrings/anvil.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/anvil.gpg] https://apt.shreeda.xyz stable main" |
  sudo tee /etc/apt/sources.list.d/anvil.list
sudo apt update && sudo apt install anvil
```

The signing key's fingerprint is `E583 2FE9 662C 5F40 21A7 D4A5 2DE3 AD52 8436 9C1D`. Check
it with `gpg --show-keys /etc/apt/keyrings/anvil.gpg`.

Or download the .deb for your machine from the
[Releases](https://github.com/memetics19/anvil/releases) page and install it:

```sh
sudo apt install ./anvil_<version>_amd64.deb      # or _arm64.deb
```

Both ways install `git` too. apt also installs the recommended `ansible`, `terraform`,
`vault`, `jq` and `age` when it can find them, because the lab needs them. Terraform and
Vault come from the HashiCorp apt repository. Add `--no-install-recommends` to skip them.

## Fedora and RHEL

```sh
sudo dnf install ./anvil-<version>-1.x86_64.rpm   # or .aarch64.rpm
```

Both packages put the binary in `/usr/bin/anvil` and the completions where bash, zsh and
fish look for them.

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

Any command offers to do the fetch the first time, so `anvil media status` right after the
install works too. A release binary fetches its own tag, for example `v0.1.0`. After an upgrade,
`anvil update` moves that copy to the new tag. The copy is in your home because runs
write `build/` and `terraform/.terraform` inside it. [cli.md](cli.md#anvil-fetch-and-anvil-update)
has the details.

## Versions and releases

Versions follow semver and start at 0.1.0. release-please reads the conventional commits
on `main` and keeps a release pull request with the next version and `CHANGELOG.md`.
Merging it tags `vX.Y.Z` and creates the GitHub Release. GoReleaser
(`.goreleaser.yaml`) then builds the archives, checksums, .deb and .rpm packages, adds
them to the release and commits the formula to `Formula/` in this repo.

Releases are weekly. Every Monday at 10:00 IST the release workflow merges the release
pull request by itself, when all of these hold:

- there is one, so a week with nothing to release makes no release
- every check on the latest commit of `main` finished and passed
- the pull request is up to date with `main`
- it holds no breaking change

A breaking release is always made by hand: merge its release pull request yourself. Any
other release can come early the same way, or from **Actions > release-please > Run
workflow**, which applies the same checks.

Every pull request and push to `main` runs the same build as a snapshot that publishes
nothing. Run it locally with:

```sh
make release-snapshot     # dist/: archives, checksums, .deb, .rpm, the formula
```

It runs the pinned GoReleaser through `go run`, so nothing is installed.
