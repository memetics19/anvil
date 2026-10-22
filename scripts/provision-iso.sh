#!/usr/bin/env bash
# Build the Proxmox VE automated install ISO for one machine (docs/provisioning.md):
#   make provision-iso NAME=<box>
# 1. Checks site.provision.machines.<box> and the guard against the current server.
# 2. Makes sure kv/homelab/<box>/install holds root_password (generated once, never printed).
# 3. Renders the answer file (scripts/provision.py answer) with the password hash.
# 4. On the build host (PROVISION_BUILD_HOST, default root@$PVE_IP, any Debian with the
#    Proxmox repository and proxmox-auto-install-assistant): downloads the pinned ISO once
#    into /var/tmp/anvil-provision, checks its SHA-256, validates the answer file and runs
#    prepare-iso --fetch-from iso. The answer file and the result live there only in a
#    mode 700 directory that is removed at the end.
# 5. Copies the result to build/provision/<box>.iso, mode 600.
#    media pxe instead: builds the netboot payload on the build host, which must be the
#    netboot host (PROVISION_NETBOOT_HOST, default root@$PVE_IP): the installer kernel and
#    its initrd with the prepared ISO appended as /proxmox.iso (the 8.4 initrd looks for it
#    there), in /var/tmp/anvil-provision/pxe-<box>, mode 700. The pinned iPXE binaries are
#    cached in /var/tmp/anvil-provision/ipxe. Nothing is copied to the Mac.
# The ISO holds the password hash. make provision deletes it after the install.
# Delete it by hand with make provision-clean NAME=<box>.
set -euo pipefail
{ set +x; } 2>/dev/null

PVE_ISO_VERSION=8.4-1
PVE_ISO_SHA256=d237d70ca48a9f6eb47f95fd4fd337722c3f69f8106393844d027d28c26523d8
PVE_ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_${PVE_ISO_VERSION}.iso"
# media pxe: iPXE from the Debian bookworm package, pinned by version and .deb SHA-256.
IPXE_DEB_VERSION=1.0.0+git-20190125.36a4c85-5.1
IPXE_DEB_SHA256=49dc854857dcfb354292bdc79ce7419e0d72988666723395b2e102d147c3730d

die() { echo "provision-iso: $*" >&2; exit 1; }
[ $# -eq 1 ] && [ -n "$1" ] || die "usage: $0 <name>"
name=$1
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN is not set (source scripts/env.sh)"
builder=${PROVISION_BUILD_HOST:-root@${PVE_IP:?PVE_IP is not set}}
ssh_b() { ssh -o BatchMode=yes "$builder" "$@"; }

python3 "$root/scripts/provision.py" check --name "$name"
media=$(python3 "$root/scripts/provision.py" get --name "$name" --key media)
if [ "$media" = pxe ] && [ "${PROVISION_NETBOOT_HOST:-root@$PVE_IP}" != "$builder" ]; then
  die "media pxe: build on the netboot host (PROVISION_BUILD_HOST = PROVISION_NETBOOT_HOST)"
fi

path="homelab/$name/install"
if ! vault kv get -mount=kv -field=root_password "$path" >/dev/null 2>&1; then
  err=$(vault kv get -mount=kv "$path" 2>&1 >/dev/null || true)
  case $err in
    *"No value found"*) ;;
    *) die "cannot read kv/$path" ;;
  esac
  python3 -c 'import secrets; print(secrets.token_urlsafe(24))' |
    vault kv put -mount=kv "$path" root_password=- >/dev/null || die "cannot write kv/$path"
  echo "generated the root password into kv/$path"
fi

umask 077
out_dir="$root/build/provision"
mkdir -p "$out_dir"
tmp=$(mktemp -d "$out_dir/.answer.XXXXXX")
rdir=
cleanup() {
  rm -rf "$tmp"
  rm -f "$out_dir/$name.iso.part"
  [ -z "$rdir" ] || ssh_b rm -rf "$rdir" || echo "provision-iso: remove $builder:$rdir by hand" >&2
}
trap cleanup EXIT

vault kv get -mount=kv -field=root_password "$path" |
  python3 "$root/scripts/provision.py" answer --name "$name" >"$tmp/answer.toml"

ssh_b 'command -v proxmox-auto-install-assistant >/dev/null && command -v xorriso >/dev/null' ||
  die "the build host needs: apt-get install proxmox-auto-install-assistant xorriso"

# The base ISO, cached on the build host. It holds no secrets.
ssh_b bash -s -- "$PVE_ISO_URL" "$PVE_ISO_SHA256" <<'EOF'
set -euo pipefail
url=$1 sum=$2 dir=/var/tmp/anvil-provision iso=/var/tmp/anvil-provision/${1##*/}
install -d -m 700 "$dir"
if ! echo "$sum  $iso" | sha256sum -c --status 2>/dev/null; then
  echo "downloading ${url##*/}"
  curl -fsSL --retry 3 -o "$iso.part" "$url"
  echo "$sum  $iso.part" | sha256sum -c --status || { rm -f "$iso.part"; echo "SHA-256 mismatch for ${url##*/}" >&2; exit 1; }
  mv "$iso.part" "$iso"
fi
echo "base ISO ${url##*/}: SHA-256 ok"
EOF

rdir=$(ssh_b 'umask 077; mktemp -d /var/tmp/anvil-provision/build.XXXXXX')
ssh_b "cat > '$rdir/answer.toml'" <"$tmp/answer.toml"
ssh_b "set -e; cd '$rdir'; proxmox-auto-install-assistant validate-answer answer.toml;
  proxmox-auto-install-assistant prepare-iso --fetch-from iso --answer-file answer.toml \
    --tmp '$rdir' --output '$rdir/out.iso' '/var/tmp/anvil-provision/proxmox-ve_${PVE_ISO_VERSION}.iso' >/dev/null"
if [ "$media" = pxe ]; then
  ssh_b bash -s -- "$rdir" "$name" "$IPXE_DEB_VERSION" "$IPXE_DEB_SHA256" <<'EOF'
set -euo pipefail
rdir=$1 name=$2 ver=$3 sum=$4
ipxe=/var/tmp/anvil-provision/ipxe pxe=/var/tmp/anvil-provision/pxe-$name
if [ "$(cat "$ipxe/deb.sha256" 2>/dev/null)" != "$sum" ] || [ ! -s "$ipxe/ipxe.efi" ] || [ ! -s "$ipxe/undionly.kpxe" ]; then
  mkdir "$rdir/deb"
  (cd "$rdir/deb" && apt-get download -q -o APT::Sandbox::User=root "ipxe=$ver" >/dev/null)
  deb=$(ls "$rdir"/deb/ipxe_*.deb)
  echo "$sum  $deb" | sha256sum -c --status || { echo "SHA-256 mismatch for ${deb##*/}" >&2; exit 1; }
  dpkg-deb -x "$deb" "$rdir/deb/x"
  install -d -m 755 "$ipxe"
  install -m 644 "$rdir/deb/x/boot/ipxe.efi" "$rdir/deb/x/usr/lib/ipxe/undionly.kpxe" "$ipxe/"
  echo "$sum" >"$ipxe/deb.sha256"
fi
cd "$rdir"
xorriso -osirrox on -indev out.iso -extract /boot/linux26 linux26 -extract /boot/initrd.img initrd.img >/dev/null 2>&1
chmod u+w linux26 initrd.img
# The kernel reads concatenated initramfs archives. The appended one must start 4 aligned.
truncate -s %4 initrd.img
mkdir cpio
ln out.iso cpio/proxmox.iso
(cd cpio && echo proxmox.iso | cpio -o -H newc --quiet) | cat initrd.img - >initrd
install -d -m 700 "$pxe"
install -m 600 linux26 initrd "$pxe/"
echo "netboot payload ready on the build host: initrd $(stat -c %s "$pxe/initrd") bytes"
EOF
  echo "media pxe: nothing is copied to the Mac. make provision deletes the payload after the install."
  exit 0
fi
scp -q -o BatchMode=yes "$builder:$rdir/out.iso" "$out_dir/$name.iso.part"
chmod 600 "$out_dir/$name.iso.part"
mv "$out_dir/$name.iso.part" "$out_dir/$name.iso"
size=$(wc -c <"$out_dir/$name.iso" | tr -d ' ')
sum=$(shasum -a 256 "$out_dir/$name.iso" | cut -d' ' -f1)
echo "built build/provision/$name.iso: $size bytes, SHA-256 $sum, mode 600"
echo "It holds the root password hash. make provision deletes it after the install."
