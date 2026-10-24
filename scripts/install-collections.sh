#!/usr/bin/env bash
# install-collections.sh <path>: the pinned collections of ansible/requirements.yml into
# <path>. From Galaxy, with three tries. When Galaxy keeps failing (it has outages), from
# each collection's GitHub repository at the same tag: the source Galaxy's release is built
# from, so the code is the same.
set -euo pipefail
cd "$(dirname "$0")/.."
dest=${1:?usage: scripts/install-collections.sh <path>}
req=ansible/requirements.yml

for try in 1 2 3; do
  if ansible-galaxy collection install --force -r "$req" -p "$dest"; then exit 0; fi
  echo "install-collections: Galaxy failed (try $try of 3)" >&2
  [ "$try" = 3 ] || sleep $((try * 20))
done

echo "install-collections: Galaxy keeps failing: installing from GitHub at the pinned tags" >&2
# requirements.yml lists "- name: <ns>.<name>" then "version: <x.y.z>" for each collection.
awk '/^  - name:/ { n = $3 } /^    version:/ { print n, $2 }' "$req" |
  while read -r name version; do
    [[ $name =~ ^[a-z_]+\.[a-z_]+$ && $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
      { echo "install-collections: cannot read '$name $version' from $req" >&2; exit 1; }
    ansible-galaxy collection install --force --no-deps -p "$dest" \
      "git+https://github.com/ansible-collections/$name.git,$version"
  done
