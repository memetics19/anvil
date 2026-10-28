#!/usr/bin/env bash
# Write the shell completion scripts into completions/, for the release archives and
# packages (.goreleaser.yaml runs it before the build). They come from anvil completion,
# so they hold the names of this checkout's catalog.
#   usage: scripts/completions.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/completions"
mkdir -p "$out" # each file below is written whole, so nothing is removed first
cd "$root/cli"
go run ./cmd/anvil completion bash >"$out/anvil.bash"
go run ./cmd/anvil completion zsh >"$out/_anvil"
go run ./cmd/anvil completion fish >"$out/anvil.fish"
