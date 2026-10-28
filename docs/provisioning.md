# Provisioning

Install Proxmox VE on a new server without sitting at it, or rebuild the current one the
same way. The repo uses the official Proxmox automated installer: an ISO with the answer
file inside. Any delivery path works, so the server brand does not matter.

The repo talks to the BMC through DMTF Redfish or plain IPMI. There is one opt-in
exception: turning a Dell RAID controller's disks into Non-RAID disks, which no vendor
neutral standard covers. See [The RAID controller](#the-raid-controller).

From bare metal to data pools, every step is an anvil command:

```sh
anvil provision-iso <box>                          # the answer file and the ISO
anvil provision <box> --power-off                  # dry run: reads only, prints every call
anvil provision <box> --install --power-off        # controller, shutdown, install, SSH
anvil pools <box>                                  # the ZFS data pools
```

Test status:

- Not yet run on a real second server.
- A full network install ran on a throwaway VM on the Proxmox host, with `media: pxe` and
  `bmc.type: none`. It booted from the network, installed Proxmox VE and came up on SSH
  with the operator key.
- The BMC calls are tested against a fake Redfish BMC.

## How it works

1. `make provision-iso NAME=<box>` renders the answer file from the site dict and Vault,
   and builds the ISO with it inside. For `media: pxe` it also turns the ISO into a
   netboot kernel and initrd on the Proxmox host.
2. `make provision NAME=<box>` is a dry run. It checks the guard, reads the BMC and prints
   every call it would make.
3. `make provision NAME=<box> ARGS="-e provision_confirm=<box>"` installs. It boots the
   server once into the installer, from the network or from virtual media. The installer
   powers the server off when done. The run powers it on and waits for SSH.
4. Hand the new host to the repo: [After the install](#after-the-install).

Pick the media per machine:

| `media` | When | What you do by hand |
|---|---|---|
| `pxe` | Recommended. Any server that can boot from the network, also with a BMC that has no InsertMedia | Nothing with a BMC. With `bmc.type: none`, press power and pick network boot |
| `redfish` | A Redfish BMC that offers `VirtualMedia.InsertMedia` with HTTP | Nothing |
| `manual` | No network boot and no InsertMedia | Write a USB stick, or mount the ISO in the BMC web UI |

## The machine in the site dict

Each server is an entry under `site.provision.machines`. The structure is in
[`site/site.example.yml`](../site/site.example.yml).

| Field | Meaning |
|---|---|
| `hostname` | Defaults to the entry's name. The FQDN is `<hostname>.<domain>`. |
| `keyboard`, `country`, `timezone` | Installer settings. Defaults `en-us`, `us` and `UTC`. |
| `network` | `dhcp`, or a static `cidr`, `gateway` and `dns` on the NIC with `mac`. |
| `mac` | The NIC that boots from the network, for `media: pxe` with `network: dhcp`. Otherwise `network.mac` is used. |
| `disks` | One disk, or two disk names for a ZFS mirror. See below. |
| `bmc.type` | `redfish`, `ipmi` or `none`. |
| `bmc.address` | The BMC's address. Not needed for `none`. |
| `media` | `pxe`, `redfish` or `manual`. Default `manual`. |
| `boot_mode` | `uefi` or `bios`. Only the IPMI boot device calls use it. |
| `serial` | Optional. The serial the BMC must report before anything changes. |
| `controller` | Optional. `{vendor: dell, mode: nonraid}`: turn the RAID controller's Ready disks into Non-RAID disks before the install. |

The BMC login goes into Vault at `kv/homelab/<box>/bmc`, keys `username` and `password`.
Write each value from stdin:

```sh
source scripts/env.sh
vault kv put -mount=kv homelab/<box>/bmc username=- <<<'<user>'
vault kv patch -mount=kv homelab/<box>/bmc password=-
```

### Disks

The installer picks disks by udev properties or by kernel name. The repo allows only these
three forms:

- One udev filter, such as `[{ID_SERIAL: "<serial>"}]` or `[{ID_MODEL: "<model>"}]`. The
  installer puts ext4 on LVM on the first disk that matches. A value that is only
  wildcards is refused, because it matches any disk.
- One kernel name, such as `[sda]` or `[nvme0n1]`. ext4 on LVM on that disk.
- Two kernel names, such as `[sda, sdb]`. A ZFS mirror of those two disks.

A mirror by filter is refused, because the installer would put every matching disk into
the mirror. The filters do not match on size. To find the serial or model, read the BMC's
storage inventory, or boot the ISO once and run `proxmox-auto-install-assistant
device-info`.

A RAID controller that only offers virtual disks shows each one to the installer. Filter on
that virtual disk, or name it.

## The guard

The repo refuses the current server as a target, because it runs everything.
`site.provision.refuse` lists its identifiers:

- `bmc_addresses`: extra BMC addresses. `site.pve.idrac_ip`, `site.pve.ip`,
  `site.pve.uplink_ip` and `site.pve.gateway_alias_ip` are always on the list.
- `macs`: its NICs.
- `serials`: what its BMC reports as the Redfish `SerialNumber` and `SKU`, or the IPMI FRU
  serials.

While `macs` or `serials` is empty, every target is refused.

Checks before any request:

- a BMC address, NIC MAC or `serial` on the list is refused
- a static address that a lab host already uses is refused

Then the run reads the target's BMC. It refuses when the BMC reports a serial of the
current server, or does not report the machine's `serial`. A real run also needs:

- `-e provision_confirm=<box>`, equal to the name
- the ISO in `build/provision/<box>.iso`
- the server powered off. A run never resets a running server.

To fill the refuse list:

| Value | Where to read it |
|---|---|
| NIC MACs | `/sys/class/net/<nic>/address` on the Proxmox host, for each physical NIC |
| Serials | The BMC: Redfish `GET /redfish/v1/Systems/<id>`, fields `SerialNumber` and `SKU` |
| Serials | `dmidecode -s system-serial-number` on the host |

## Build the ISO

```sh
make provision-iso NAME=<box>
```

Steps:

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

The build host is the Proxmox host, `root@<proxmox-address>`. `PROVISION_BUILD_HOST` picks
another Debian host with the Proxmox repository. To rebuild the current server, build on
the other server. The build host needs the assistant once:

```sh
apt-get install proxmox-auto-install-assistant xorriso
```

On the build host, the answer file and the result live only in a mode 700 directory under
`/var/tmp/anvil-provision`, which the run removes. The base ISO stays cached there. It
holds no secrets.

The built ISO holds the password hash. Treat it as a secret. `make provision` deletes it
after a Redfish media install. Otherwise delete it yourself after the install:

```sh
make provision-clean NAME=<box>
```

## Delivery

### Network boot (pxe)

With `media: pxe`, `make provision-iso` builds the netboot payload on the Proxmox host: the
installer kernel, and its initrd with the prepared ISO appended as `/proxmox.iso`. The 8.4
initrd looks for the ISO there.

- Proxmox documents this as `prepare-iso --pxe`, which builds the same kernel and initrd.
  That option exists only in assistants newer than the pinned 8.4 one.
- The payload lives in `/var/tmp/anvil-provision/pxe-<box>`, mode 700, and holds the
  password hash. Nothing is copied to the Mac.
- The build host must be the Proxmox host that serves the netboot.

`make provision` then starts a netboot service on the Proxmox host, for this run only: two
transient systemd units, `anvil-netboot-<box>-dhcp` and `anvil-netboot-<box>-http`, with
their config in `/run/anvil-netboot-<box>`:

- dnsmasq in proxyDHCP mode only: `dhcp-range=<network>,proxy` and `port=0`. It hands out
  no addresses and answers no DNS. The ONT stays the only DHCP server.
- It answers PXE requests only from the target's MAC (`dhcp-host` with a tag, and
  `dhcp-ignore` for every other client). Others get no reply at all.
- It listens only on the `vmbr` bridge that holds `site.pve.uplink_ip`, the network the
  ONT serves, plus loopback, which dnsmasq always adds. It never listens on the VLAN or
  enclave interfaces. The run refuses a bridge that is a VLAN interface.
- TFTP serves iPXE (`ipxe.efi` for UEFI, `undionly.kpxe` for BIOS) and a `boot.ipxe`
  script. They sit in a directory named after the target's MAC (`tftp-unique-root=mac`),
  so no other client can fetch them.
- `boot.ipxe` loads the kernel and initrd over HTTP from the uplink address, port 18199
  (`PROVISION_NETBOOT_PORT`), at a random path.

iPXE comes from the Debian bookworm `ipxe` package, pinned by version and by the SHA-256 of
the `.deb`, at the top of `scripts/provision-iso.sh`. It is cached in
`/var/tmp/anvil-provision/ipxe`.

Once the initrd has been served, the run stops both units, removes their directory and
deletes the payload. The installer runs from memory by then. A failed run, Ctrl-C, a closed
terminal or a kill cleans up the same way. Each unit also stops itself after 4 hours.

The server needs:

- network boot enabled on the NIC in `network.mac` (or `mac`), on a port in the native
  VLAN of the lab and home network
- Secure Boot off, because the iPXE binaries are not signed
- at least 4 GB of memory, because the initrd with the ISO is 1.6 GB

UEFI is tested, on a VM with the firmware's own PXE. BIOS boot through `undionly.kpxe` is
not tested.

### Redfish virtual media

With `bmc.type: redfish` and `media: redfish`, the run uses the standard
`VirtualMedia.InsertMedia` action with an HTTP URL. It first checks that the BMC offers
InsertMedia and EjectMedia for a virtual CD, and allows HTTP as a transfer protocol. If
not, it refuses and tells you to use `media: manual`.

The Mac serves the ISO for this run only:

- on the Mac's address on the route to the BMC, a random port and a random path
- with byte range requests, because BMCs read the ISO in ranges

If the macOS firewall asks, allow incoming connections for Python.

### Manual media

With `media: manual` you attach the ISO yourself. Write it to a USB stick:

```sh
diskutil list                              # find the stick, /dev/diskN
diskutil unmountDisk /dev/diskN
sudo dd if=build/provision/<box>.iso of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

Or use balenaEtcher, or mount the ISO as a virtual CD in the BMC web UI. Then add
`-e provision_media_ready=true` to the run. The run sets the boot device once and powers
on. When the installer has powered the server off, remove the media and power it on.

### Power and boot once

| `bmc.type` | Calls |
|---|---|
| `redfish` | `PATCH` the system's `Boot` with `BootSourceOverrideTarget` `Pxe` (or `Cd`) and `BootSourceOverrideEnabled` `Once`, then `ComputerSystem.Reset` with `ResetType` `On` |
| `ipmi` | `ipmitool chassis bootdev pxe options=efiboot` (or `cdrom`, and no option for `boot_mode: bios`), then `ipmitool chassis power on`. The password goes through `IPMI_PASSWORD`, never argv. |
| `none` | You power on and pick network boot or the media in the boot menu. Then power it on again when the installer has powered it off. The run waits for SSH. |

Redfish requests use basic auth, so the run opens no BMC session. IPMI needs `brew install
ipmitool`.

### The current server's iDRAC8

A read-only check of the current server's iDRAC8 (firmware 2.43, Redfish 1.0.2) found:

- `ComputerSystem.Reset` offers `On`, `ForceOff`, `GracefulRestart`, `PushPowerButton` and
  `Nmi`.
- The boot override offers `Pxe` and `Cd` among others. The boot mode is UEFI.
- The virtual CD has no InsertMedia or EjectMedia action.

Rebuilding that server would use `media: pxe`, with a Redfish boot once to `Pxe` and power
on. No USB stick is needed. BMCs of any brand that offer InsertMedia can also use
`media: redfish`.

## The RAID controller

Disks in "Ready" state under a RAID controller are not visible to the installer or to ZFS.
They must be Non-RAID (pass-through, also called HBA or IT mode). Redfish has no standard
action for that, so:

- Dell iDRAC 7, 8 and 9: set `controller: {vendor: dell, mode: nonraid}` on the machine.
  anvil does it as part of `anvil provision`. This is the only vendor-specific code, in
  `scripts/provision_dell.py`.
- Any other brand: set the disks to Non-RAID or HBA mode in the controller's setup or the
  BMC's web UI before the install.

What the Dell step does, after the serial check proved the BMC is the target's:

1. It reads every physical disk's RAID state over the iDRAC's WS-Man interface
   (`DCIM_PhysicalDiskView`).
2. Disks already Non-RAID are left alone. When all are, it does nothing.
3. Ready disks go to Non-RAID with `DCIM_RAIDService.ConvertToNonRAID`, then one
   Lifecycle Controller job per controller (`CreateTargetedConfigJob`, graceful reboot).
   The server reboots once, about 10 minutes. The run waits for the job.
4. It reads the disks again and stops unless every one is Non-RAID.

It refuses, before any change, a disk inside a RAID volume, and a disk that is Foreign,
Failed, Offline or Blocked. anvil never deletes or changes a RAID volume. Delete it in the
iDRAC, then rerun. The job leaves the server running, so a machine with `controller` needs
`--power-off`.

## Power off

`anvil provision` never resets a running server. With `--power-off`
(`-e provision_power_off=true`) it shuts a running target down first:

- Redfish: `ComputerSystem.Reset` with `GracefulShutdown`, or `PushPowerButton` when the BMC
  has no `GracefulShutdown`. Both ask the OS to shut down.
- IPMI: `ipmitool chassis power soft`.

It runs only after the serial check, so it can only reach the target. It waits up to 15
minutes. A server that does not shut down is refused: anvil never forces one off. Look at
its console, shut it down, then rerun.

## The dry run

```sh
make provision NAME=<box>
```

It prints one line per step, never a secret:

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
for it yet, it skips the reads and still prints the plan. With `media: pxe` the plan
starts the netboot service and boots once to `Pxe`:

```
plan: on the Proxmox host, start anvil-netboot-<box>-dhcp: dnsmasq proxyDHCP (no addresses, no DNS) and TFTP on the bridge with the uplink address, PXE answers for <mac> only
plan: on the Proxmox host, start anvil-netboot-<box>-http: the installer kernel and initrd over HTTP on the uplink address, port 18199, at a random path
plan: PATCH /redfish/v1/Systems/<id> {"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Pxe"}}
plan: POST /redfish/v1/Systems/<id>/Actions/ComputerSystem.Reset {"ResetType": "On"}
plan: wait for the installer kernel and initrd to be served
plan: stop and remove anvil-netboot-<box>-dhcp and anvil-netboot-<box>-http, delete the netboot payload
plan: wait for the installer to power the server off (up to 90 min)
plan: POST /redfish/v1/Systems/<id>/Actions/ComputerSystem.Reset {"ResetType": "On"}
plan: wait for SSH on <address>:22
```

## Install

```sh
make provision NAME=<box> ARGS="-e provision_confirm=<box>"
```

The real run prints `do:` where the dry run printed `plan:`. Cleanup when it stops early:

- after the ISO was attached: it ejects the ISO and stops serving
- while the netboot runs: it stops and removes the service, and deletes the payload

The installer powers the server off at the end, so attached media cannot start a second
install.

## The network boot test

The full chain was tested on the Proxmox host with throwaway VMs, deleted afterwards.

1. A UEFI VM with a fake MAC, Secure Boot off and its NIC's own boot ROM off, so the
   firmware's PXE loaded `ipxe.efi` over TFTP. A temporary site entry with `media: pxe` and
   `bmc.type: none`.
2. `make provision` started the netboot. The VM booted iPXE, then `boot.ipxe`, then the
   kernel and initrd over HTTP. The run stopped the netboot about a minute after it started.
   The installer put Proxmox VE 8.4 on ext4 and powered off. After a power on the run saw
   SSH, the root password hash matched Vault and the operator key worked.
3. A second VM with another MAC and an iPXE boot ROM booted from the network while the
   netboot ran. dnsmasq logged each of its 10 requests as `proxy-ignored` and sent it
   nothing. Its only offers came from the ONT.
4. A run killed while the netboot ran stopped both units and deleted the payload.

## After the install

The new host has the root password from `kv/homelab/<box>/install` and your SSH key for
root. Hand it to the repo, as in [First build](setup.md#first-build):

1. Add it to `ansible/inventory/hosts.yml` and give it its own `site` values. The
   `pve_host` and `pve_network` roles read `site.pve`, the current server, so a second
   Proxmox host needs its own variables first. That is the next roadmap step.
2. `make bootstrap-ssh ARGS="--limit <box>"` installs the operator key. The installer
   already put it there, so this only checks it. It reads the root password from the
   Keychain item `pve-root-password`. If the box took over the address of an older
   machine, run `make forget-host HOST=<box>` first, or its new SSH key is refused.
3. `make host ARGS="--limit <box> --check --diff"`, then without `--check`.
4. Continue with the other steps of [First build](setup.md#first-build) or
   [Rebuilding on a new box](setup.md#rebuilding-on-a-new-box).

Delete the ISO and the netboot payload if the run did not: `make provision-clean NAME=<box>`.

## The cluster

A provisioned server joins the main host's Proxmox cluster:

```yaml
cluster: {name: lab, votes: {pve: 2}, members: [pve2]}
```

```sh
anvil check cluster     # what it would run
anvil apply cluster     # the name is typed to confirm
```

1. On the main host, once: `pvecm create <name> --link0 <uplink address> --votes <n>`.
   Guests keep running. `local-lvm` is limited to the main host, because a member has no
   LVM thin pool.
2. On each member, once: its root key is allowed on the main host, and the main host's SSH
   host key is pinned on it from the main host's own file. Then `pvecm add --use_ssh`.
   A member with guests is refused.
3. The member's `local-zfs` storage, which joining drops, is added back for that node only.
4. It checks the cluster is quorate.

The cluster link (corosync) is the home network: the main host's uplink address and each
member's address.

Votes decide what happens when a server is down. A cluster needs more than half of all
votes. With `votes: {pve: 2}` and one member, the main host holds 2 of 3 and keeps working
alone. A member alone has 1 of 3: its guests keep running, but nothing can be started,
stopped or changed until the main host is back. With equal votes, either server being down
freezes the other. A QDevice on a third machine avoids that, and anvil does not set one up.

Join first, then create the data pools: joining replaces the member's storage list with the
cluster's. `anvil pools` registers each pool for its own node only.

anvil never removes a node from a cluster or deletes one. That is manual (`pvecm delnode`).

## Data pools

The installer only builds the boot pool `rpool`, on the disks in `disks`. The other disks
become ZFS data pools, declared under the machine's `pools`:

```yaml
pools:
  - {name: vmdata, layout: mirror, disks: [<by-id>, <by-id>], proxmox_storage: true}
  - {name: tank, layout: raidz1, disks: [<by-id>, <by-id>, <by-id>, <by-id>]}
```

| Field | Meaning |
|---|---|
| `name` | The pool name. Not `rpool` or `bpool`. |
| `layout` | `mirror` (2 disks or more), `raidz1` (3), `raidz2` (4) or `raidz3` (5). |
| `disks` | Whole disks by their names under `/dev/disk/by-id`. Never `sdX`, which can change at boot. |
| `proxmox_storage` | `true` adds the pool as Proxmox storage for VM disks and containers, on that node only. |

```sh
anvil pools <box>               # lists the disks and what it would do, asks, then creates
anvil pools <box> --wipe tank   # a disk of tank has old signatures and nothing on it is needed
anvil pools <box> --wipe vmdata,tank   # several pools at once
```

The first run lists every disk with its by-id name, size, model and use, so you can copy
the names into the site dict. Pools get `ashift=12`, `compression=lz4`, `atime=off`,
`xattr=sa` and `acltype=posixacl`.

Rules:

- An existing pool with the declared disks is left as it is. One with other disks is an
  error. anvil never changes, grows or destroys a pool.
- A disk in any pool, mounted or used as swap is refused.
- A disk with partitions or signatures (an old filesystem, RAID or ZFS label, or an empty
  partition table left by a previous owner, shown as `PMBR`) is refused. `--wipe <pool>`
  wipes the signatures on that pool's disks first, `--wipe vmdata,tank` on several pools'
  disks. Use it only when nothing on them is needed. Any refusal stops the whole run before
  anything changes.

ZFS wants each disk on its own. A RAID controller must pass the disks through, see
[The RAID controller](#the-raid-controller).
