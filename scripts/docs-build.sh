#!/usr/bin/env bash
# Build the docs site into build/site: README.md becomes the home page, docs/*.md the other
# pages, and scripts/install.sh sits at the root. Links to files outside docs/ point at
# GitHub, since the site holds only the pages.
#   usage: scripts/docs-build.sh   (needs mkdocs from docs/requirements.txt)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
blob=https://github.com/memetics19/anvil/blob/main
src="$root/build/docs-src"
mkdir -p "$src"
rm -f "$src"/*.md "$src/install.sh" # only the copied files live here

# README links: docs/x.md -> x.md, other repo files -> GitHub
sed -E -e 's#\]\(docs/#](#g' \
  -e "s#\\]\\((site/|LICENSE|\\.gitleaks|iptv/|ansible/|terraform/|scripts/)#](${blob}/\\1#g" \
  "$root/README.md" >"$src/index.md"
# docs/*.md links: ../x -> GitHub
for f in "$root"/docs/*.md; do
  sed -E "s#\\]\\(\\.\\./#](${blob}/#g" "$f" >"$src/$(basename "$f")"
done
# The one-line installer is served from the site root: <site>/install.sh
cp "$root/scripts/install.sh" "$src/install.sh"

cd "$root" && mkdocs build --quiet
