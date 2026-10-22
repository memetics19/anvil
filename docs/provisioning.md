# Provisioning

How to install Proxmox VE on a new server without sitting at it, and how to rebuild the
current one the same way. The core is the official Proxmox automated installer: an ISO with
the answer file inside. It works from any delivery path, so it does not depend on the server
brand.

The repo talks to the server's BMC only through standards. That is DMTF Redfish or plain
IPMI. It uses no vendor tools and no vendor OEM APIs.

This runbook has not been run on a real second server yet. The answer file, the ISO build
and the guard are tested. The BMC calls are tested against a fake Redfish BMC.

## How it works

1. `make provision-iso NAME=<box>` renders the answer file from the site dict and Vault. It
   builds the ISO with the answer file inside.
2. `make provision NAME=<box>` is a dry run. It checks the guard, reads the BMC and prints
   every call it would make.
3. `make provision NAME=<box> ARGS="-e provision_confirm=<box>"` installs. With Redfish
   virtual media it serves the ISO from the Mac, attaches it, boots once from CD, powers on
   and waits for the installer. The installer powers the server off when it is done. Then
   the run ejects the ISO, powers on and waits for SSH.
4. You hand the new host to the repo: [After the install](#after-the-install).

## The machine in the site dict

Each server is an entry under `site.provision.machines`. The structure is in
[`site/site.example.yml`](../site/site.example.yml).

| Field | Meaning |
|---|---|
| `hostname` | Defaults to the entry's name. The FQDN is `<hostname>.<domain>`. |
| `keyboard`, `country`, `timezone` | Installer settings. Defaults `en-us`, `us` and `UTC`. |
| `network` | `dhcp`, or a static `cidr`, `gateway` and `dns` on the NIC with `mac`. |
| `disks` | One disk, or two disk names for a ZFS mirror. See below. |
| `bmc.type` | `redfish`, `ipmi` or `none`. |
| `bmc.address` | The BMC's address. Not needed for `none`. |
| `media` | `redfish` or `manual`. Default `manual`. |
| `boot_mode` | `uefi` or `bios`. Only the IPMI boot device call uses it. |
| `serial` | Optional. The serial the BMC must report before anything changes. |

The BMC login goes into Vault at `kv/homelab/<box>/bmc`, keys `username` and `password`.
Write each value from stdin:

```sh
source scripts/env.sh
vault kv put -mount=kv homelab/<box>/bmc username=- <<<'<user>'
vault kv patch -mount=kv homelab/<box>/bmc password=-
```

### Disks

The installer picks disks by udev properties or by kernel name. The repo allows three
forms, and nothing else:

- One udev filter, such as `[{ID_SERIAL: "<serial>"}]` or `[{ID_MODEL: "<model>"}]`. The
  installer puts ext4 on LVM on the first disk that matches. A value that is only
  wildcards is refused, because it matches any disk.
- One kernel name, such as `[sda]` or `[nvme0n1]`. ext4 on LVM on that disk.
- Two kernel names, such as `[sda, sdb]`. A ZFS mirror of those two disks.

A mirror by filter is refused. The installer would put every disk the filter matches into
the mirror. The installer's filters do not match on size. Find the serial or model in the
BMC's storage inventory, or boot the ISO once and run `proxmox-auto-install-assistant
device-info`.

A RAID controller that only offers virtual disks shows each virtual disk to the installer.
Then filter on that virtual disk, or name it.

## The guard

The current server runs everything, so the repo refuses it as a target.
`site.provision.refuse` lists its identifiers:

- `bmc_addresses`: extra BMC addresses. `site.pve.idrac_ip`, `site.pve.ip`,
  `site.pve.uplink_ip` and `site.pve.gateway_alias_ip` are always on the list.
- `macs`: its NICs.
- `serials`: what its BMC reports as the Redfish `SerialNumber` and `SKU`, or the IPMI FRU
  serials.

While `macs` or `serials` is empty, every target is refused.

Before any request, a run refuses a machine whose BMC address, NIC MAC or `serial` is on the
list. It also refuses a static address that a lab host already uses. Then it reads the
target's BMC. It refuses when the BMC reports a serial of the current server, or does not
report the machine's `serial`. A real run also needs:

- `-e provision_confirm=<box>`, equal to the name
- the ISO in `build/provision/<box>.iso`
- the server powered off. A run never resets a running server.

To fill the refuse list, read the current server's NIC MACs on the Proxmox host
(`/sys/class/net/<nic>/address` for each physical NIC). Read the serials from its BMC
(Redfish `GET /redfish/v1/Systems/<id>`, fields `SerialNumber` and `SKU`) and from
`dmidecode -s system-serial-number` on the host.

## Build the ISO

```sh
make provision-iso NAME=<box>
```

It runs these steps:

1. It checks the machine entry and the guard.
2. It generates the root password once into `kv/homelab/<box>/install`, key
   `root_password`. The password is never printed.
3. It renders the answer file. The file holds a SHA-512 crypt hash of the password, your
   `~/.ssh/id_ed25519.pub` and `reboot_mode = "power-off"`.
4. On the build host it downloads the pinned ISO once, checks its SHA-256, validates the
   answer file with `proxmox-auto-install-assistant validate-answer` and runs `prepare-iso
   --fetch-from iso`.
5. It copies the result to `build/provision/<box>.iso`, mode 600.

The pinned version is Proxmox VE 8.4-1, the same Debian release the `pve_host` role
expects. Its URL and SHA-256 are at the top of `scripts/provision-iso.sh`.

The build host is the Proxmox host, `root@<proxmox-address>`. Set `PROVISION_BUILD_HOST` to
use another Debian host with the Proxmox repository. To rebuild the current server, build
on the other server. The build host needs the assistant once:

```sh
apt-get install proxmox-auto-install-assistant xorriso
```

The answer file and the result stay on the build host only in a mode 700 directory under
`/var/tmp/anvil-provision`, and the run removes it. The base ISO stays cached there. It
holds no secrets.

The ISO holds the password hash. Treat it as a secret. `make provision` deletes it after a
Redfish media install. Otherwise delete it yourself once the install is done:

```sh
make provision-clean NAME=<box>
```

## Delivery

### Redfish virtual media

With `bmc.type: redfish` and `media: redfish`, the run uses the standard
`VirtualMedia.InsertMedia` action with an HTTP URL. It checks at runtime that the BMC
offers InsertMedia and EjectMedia for a virtual CD, and that HTTP is an allowed transfer
protocol. If not, it refuses and tells you to use `media: manual`.

The Mac serves the ISO for this run only. The server binds to the Mac's address on the
route to the BMC, on a random port and a random path. It answers byte range requests,
because BMCs read the ISO in ranges. If the macOS firewall asks, allow incoming
connections for Python.

### Manual media

With `media: manual` you attach the ISO yourself. Write it to a USB stick:

```sh
diskutil list                              # find the stick, /dev/diskN
diskutil unmountDisk /dev/diskN
sudo dd if=build/provision/<box>.iso of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

Or write it with balenaEtcher, or mount it as virtual CD in the BMC web UI. Then run with
`-e provision_media_ready=true` as well. The run sets the boot device once and powers on.
When the installer has powered the server off, remove the media and power it on.

### Power and boot once

| `bmc.type` | Calls |
|---|---|
| `redfish` | `PATCH` the system's `Boot` with `BootSourceOverrideTarget` `Cd` and `BootSourceOverrideEnabled` `Once`, then `ComputerSystem.Reset` with `ResetType` `On` |
| `ipmi` | `ipmitool chassis bootdev cdrom options=efiboot` (no option for `boot_mode: bios`), then `ipmitool chassis power on`. The password goes through `IPMI_PASSWORD`, never argv. |
| `none` | You power on and pick the boot device in the boot menu. |

Redfish requests use basic auth, so the run opens no BMC session. IPMI needs `brew install
ipmitool`.

### The current server's iDRAC8

A read only check of the current server's iDRAC8 (firmware 2.43, Redfish 1.0.2) found:

- `ComputerSystem.Reset` offers `On`, `ForceOff`, `GracefulRestart`, `PushPowerButton` and
  `Nmi`.
- The boot override offers `Pxe` and `Cd` among others. The boot mode is UEFI.
- The virtual CD has no InsertMedia or EjectMedia action.

So rebuilding that server would use `media: manual` with Redfish power and boot once. It
is one example of a Redfish BMC. Newer BMCs of any brand that offer InsertMedia can use
`media: redfish`.

## The dry run

```sh
make provision NAME=<box>
```

It prints one line per step, and never a secret:

```
provision <box>: dry run, nothing changes. Apply with -e provision_confirm=<box>
guard: ok (BMC address, NIC MAC and serial are not the current server's)
read: GET /redfish/v1
read: GET /redfish/v1/Systems
read: GET /redfish/v1/Systems/<id>
...
read: serial check ok, power Off
plan: serve build/provision/<box>.iso over HTTP on this Mac's LAN address, for this run only
plan: POST <virtual CD>/Actions/VirtualMedia.InsertMedia {"Image": "http://...", "Inserted": true, "WriteProtected": true}
plan: PATCH /redfish/v1/Systems/<id> {"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Cd"}}
plan: POST /redfish/v1/Systems/<id>/Actions/ComputerSystem.Reset {"ResetType": "On"}
plan: wait for the installer to power the server off (up to 90 min)
plan: POST <virtual CD>/Actions/VirtualMedia.EjectMedia {}
plan: stop serving and delete build/provision/<box>.iso
plan: POST /redfish/v1/Systems/<id>/Actions/ComputerSystem.Reset {"ResetType": "On"}
plan: wait for SSH on <address>:22
```

The dry run sends only GET requests. When the BMC does not answer, or Vault has no login
for it yet, it skips the reads and still prints the plan.

## Install

```sh
make provision NAME=<box> ARGS="-e provision_confirm=<box>"
```

The real run prints `do:` where the dry run printed `plan:`. If it stops after the ISO was
attached, it ejects it and stops serving. The installer powers the server off at the end,
so an attached ISO cannot start a second install.

## After the install

The new host has the root password from `kv/homelab/<box>/install` and your SSH key for
root. Then hand it to the repo, as in [First build](setup.md#first-build):

1. Add it to `ansible/inventory/hosts.yml` and give it its own `site` values. The
   `pve_host` and `pve_network` roles read `site.pve`, the current server, so a second
   Proxmox host needs its own variables first. That is the next roadmap step.
2. `make bootstrap-ssh ARGS="--limit <box>"` installs the operator key. The installer has
   already put it there, so this only checks it. It reads the root password from the
   Keychain item `pve-root-password`.
3. `make host ARGS="--limit <box> --check --diff"`, then without `--check`.
4. Continue with the other steps of [First build](setup.md#first-build) or
   [Rebuilding on a new box](setup.md#rebuilding-on-a-new-box).

Delete the ISO if the run did not: `make provision-clean NAME=<box>`.
