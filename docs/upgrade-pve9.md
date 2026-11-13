# Upgrading the nodes to Proxmox VE 9

Proxmox VE 8 reached its end of life on 31 August 2026. This is the runbook for moving
both nodes to Proxmox VE 9 (Debian 13, trixie). It follows Proxmox's own guide,
[Upgrade from 8 to 9](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9), and adds what is
particular to this lab.

One node at a time, the second node first. A cluster may run 8 and 9 side by side for the
weekend. VMs move from 8 to 9 but not back, so the second node goes first and takes the VMs
that must keep running while the main node is down.

| When | Node | What goes down |
|---|---|---|
| Saturday, 09:00 to 12:00 | pve2 | Single sign-on and the language model, about 20 minutes |
| Sunday, 07:00 to 10:00 | pve | Frigate, ragnarok, Vault and Vaultwarden, about 15 to 20 minutes |

DNS, the VPN, the gateway and push alerts stay up on Sunday: the apps and netbird VMs move to
pve2 first. The internet never depends on the nodes. Post both windows on the status page.

## What anvil does for it

- **Role `pve_repos`** writes each node's apt repositories by its release. On Proxmox VE 8 it
  writes the one-line lists. On 9 it writes the deb822 files of Proxmox's guide
  (`debian.sources`, `proxmox.sources`, `ceph.sources`). It removes every enterprise
  repository, which refuses downloads without a subscription. Before this role, pve2 still
  had them and had never received a Proxmox update.
- **`pve_repos_upgrade`** moves the named nodes' repositories one release ahead, so the
  upgrade can start on one node only.
- **The apps and netbird VMs** use the CPU model `x86-64-v2-AES`, which both nodes have.
  With `host` they could not move to pve2 while running.

## Before the weekend

The commands on a node name VMs by name. Define this once in each shell on a node:
`vmid() { qm list | awk -v n="$1" '$2 == n {print $1}'; }`

1. Release and update anvil: `anvil update`.
2. Give pve2 its repositories: `anvil apply host --tags repos`.
3. Apply the CPU model: `anvil apply tf`. It changes only the two VMs' CPU type. The change
   waits until each VM restarts. Restart them one at a time in a quiet moment, apps first:
   `qm reboot "$(vmid apps)"`, wait for DNS to answer, then `qm reboot "$(vmid netbird)"`. That restart is the only
   DNS gap of the whole upgrade, about 30 seconds.
4. Update both nodes to the latest 8.4, on each node: `apt update && apt full-upgrade`. It
   restarts no VM. `pveversion` must show 8.4.1 or newer. That release brings the checker.
5. Run the checker on each node: `pve8to9 --full`. Fix every FAIL. Read every WARN.
6. Back up: `anvil backup`, then the small VMs from the Proxmox web UI (Datacenter, Backup)
   or on pve `for v in apps netbird vault vaultwarden; do vzdump "$(vmid $v)" --mode snapshot --compress zstd --storage local; done`,
   and on pve2 the same for identity, wazuh and monitoring. Copy pve's
   dumps to pve2 (`/var/lib/vz/dump`), so a broken pve does not take its own backups with it.
   ragnarok and frigate are rebuilt from code. Their media and recordings are not backed up.
7. Check the consoles: a monitor and keyboard on pve, iDRAC on pve2. A new kernel can rename
   a network interface, and then only the console reaches the node.

## Saturday: pve2

Work in `tmux` on the node, so a dropped SSH session does not stop the upgrade.

1. `pveversion` shows 8.4.1 or newer, `pve8to9 --full` shows no FAIL, `pvecm status` shows
   Quorate: Yes.
2. A snapshot of the root to roll back to: `zfs snapshot rpool/ROOT/pve-1@pre-pve9`.
3. Shut down its VMs: `for v in identity wazuh monitoring; do qm shutdown "$(vmid $v)"; done`.
4. Fewer kernel audit lines during the upgrade: `systemctl disable --now systemd-journald-audit.socket`.
5. From the Mac, its repositories to trixie:
   `anvil apply host --tags repos --args "-e pve_repos_upgrade=pve2"`.
6. On the node: `apt update`, then `apt policy`. No error, and only trixie lines.
7. `apt full-upgrade`. For a changed configuration file, keep yours (N), except
   `/etc/lvm/lvm.conf` and `/etc/chrony/chrony.conf` if you never edited them.
8. `pve8to9 --full` again, then `reboot`.
9. After it: `pveversion` shows 9, `uname -r` shows 6.14 or newer, `ip -br link` shows the
   same interface names as before, `pvecm status` is quorate, and the VMs start.
10. From the Mac: `anvil apply host --tags repos` changes nothing, and
    `anvil test smoke` passes.

Roll back: choose the old kernel in the boot menu, or boot the Proxmox ISO's rescue mode and
`zfs rollback rpool/ROOT/pve-1@pre-pve9`. Drop the snapshot after a week:
`zfs destroy rpool/ROOT/pve-1@pre-pve9`.

## Sunday: pve

1. The checks of Saturday's step 1, and `ceph -s` shows HEALTH_OK.
2. Move the VMs that must keep running to pve2, one at a time, apps first:
   `qm migrate "$(vmid apps)" pve2 --online --with-local-disks --targetstorage vmdata`, check
   DNS, then the same for netbird. Nothing stops. Do not run `anvil apply tf` while they are on pve2:
   Terraform would try to move them back.
3. A snapshot of the root to roll back to (16 GB is free in the volume group):
   `lvcreate -s -L 15G -n root-pre-pve9 pve/root`.
4. Ceph keeps its data in place while the node is down: `ceph osd set noout`.
5. `systemctl disable --now systemd-journald-audit.socket`.
6. From the Mac: `anvil apply host --tags repos --args "-e pve_repos_upgrade=pve"`.
7. On the node: `apt update`, `apt policy`, then, because it boots UEFI from LVM,
   `apt install grub-efi-amd64`.
8. `apt full-upgrade`, with the same answers as Saturday. `pve8to9 --full`, then `reboot`.
9. After it: the checks of Saturday's step 9, then `ceph osd unset noout` and `ceph -s`.
   A warning about insecure key types is expected after the upgrade and is not an error.
10. Move apps and netbird back, from pve2:
    `qm migrate "$(vmid apps)" pve --online --with-local-disks --targetstorage local-lvm`, then
    the same for netbird.
11. From the Mac: `anvil apply host` changes nothing, `anvil check tf` shows no change, and
    `anvil test smoke` passes. Close the status page window.

Roll back: choose the old kernel in the boot menu, or merge the snapshot and reboot:
`lvconvert --merge pve/root-pre-pve9`. Remove it after a week, it fills as the root changes:
`lvremove pve/root-pre-pve9`.

## Good to know

- `/tmp` is a memory file system on Debian 13, and `/tmp` and `/var/tmp` are cleaned on a
  timer.
- `/etc/sysctl.conf` is no longer read. The nodes keep nothing there. IP forwarding comes from
  the network configuration (`post-up` in `/etc/network/interfaces`).
- `pve8to9` may suggest removing the `systemd-boot` package. Do what it says.
