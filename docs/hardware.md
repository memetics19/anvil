# Hardware

Two Dell PowerEdge servers, one switch. Nothing in the repo is tied to these models: they
are what this lab runs on. Addresses, serials and MACs live in the site dict in Vault,
never here.

| | `pve`, the main server | `pve2`, the second server |
|---|---|---|
| Model | PowerEdge T130 tower | PowerEdge R620, 1U rack |
| Role | Runs the whole lab today | Backups, data pools and new workloads. Being installed |
| CPU | 1 × Xeon E3-1220 v6, 4 cores, 4 threads, 3.0 GHz | 2 × Xeon E5-2640 v2, 16 cores, 32 threads, 2.0 GHz |
| RAM | 32 GB DDR4-2400 ECC (4 × 8 GB) | 128 GB DDR3-1600 ECC LRDIMM (4 × 32 GB, 20 slots free) |
| RAID controller | PERC H730, each disk its own virtual disk | PERC H310 Mini, every disk Non-RAID (pass-through) |
| Disks | 4 TB and 1 TB Seagate Exos, 7200 rpm | 8 × 2.5" SAS: 4 × 1 TB and 4 × 2 TB Seagate, 7200 rpm |
| Network | 2 × 1 GbE (Broadcom BCM5720) | 2 × 10 GbE (Intel X540, copper) and 2 × 1 GbE (Intel I350) |
| Out-of-band | iDRAC8, Redfish | iDRAC7 Enterprise, Redfish 1.0.2 and WS-Man |
| Proxmox VE | 8.4 | 8.4, from `anvil provision` |

## pve, the T130

It runs everything that exists today: the VMs in [services.md](services.md), Vault, the
secrets enclave, Ceph on one disk for the Terraform state, and the netboot service for
`anvil provision`.

| Disk | Use |
|---|---|
| 4 TB | Proxmox, the VM disks and the media library |
| 1 TB | The Ceph OSD that holds the Terraform state |

Limits: 4 cores and 32 GB. It is near its memory limit with the current VMs. The CPU has
AVX2. Its two free 3.5" bays can take more disks.

## pve2, the R620

It is installed from bare metal with `anvil provision` (see
[provisioning.md](provisioning.md)): the disks set to Non-RAID through the iDRAC, a
graceful power-off, a network boot into the Proxmox installer, then `anvil pools`.

Disk layout:

| Pool | Disks | Layout | Usable | Use |
|---|---|---|---|---|
| `rpool` | 2 × 1 TB | ZFS mirror | about 0.9 TB | Proxmox, made by the installer |
| `vmdata` | 2 × 1 TB | ZFS mirror | about 0.9 TB | VM disks and containers |
| `tank` | 4 × 2 TB | ZFS RAIDZ1 | about 5.4 TB | Backups of `pve` and a copy of the media library |

Each pool survives one failed disk. 1 TB and 2 TB disks are in separate pools because ZFS
sizes a group to its smallest disk.

What to know about it:

- **No AVX2.** Ivy Bridge CPUs have AVX but not AVX2. Most software runs fine. Some newer
  builds need AVX2, for example recent MongoDB and some local LLM runtimes.
- **Spinning disks only.** VMs on `vmdata` are slower than on an SSD. The 1 TB disk of
  model ST91000640SS is the oldest, and the first to swap for a SATA SSD.
- **The H310's queue depth is low (25).** It is fine for this lab. For heavy disk load,
  an HBA in IT mode does better.
- **10 GbE.** The X540 ports run at 1 Gb/s today, because the switch is 1 GbE. They are
  10GBASE-T, copper, so a 10 GbE switch or a direct cable to another 10 GbE machine
  gives 10 Gb/s.
- **Noise and power.** A 1U server with small fans is loud and draws more than the T130
  at idle. Keep it away from where people sleep. It has two 750 W supplies, redundant:
  plug them into different sockets.
- **Memory.** 20 DIMM slots are free. DDR3 LRDIMMs of the same type are cheap used. Do
  not mix LRDIMMs with RDIMMs.

## Network

| Part | Model |
|---|---|
| Switch | Cisco SG300-52, 52 × 1 GbE, managed as code ([cisco-switch.md](cisco-switch.md)) |
| Router | The ISP's ONT, the only DHCP server on the home network |

Both servers and their iDRACs sit on the home and lab network. The VLANs, the secrets
enclave and the routed segments are on `pve` ([services.md](services.md)).
