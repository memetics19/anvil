# anvil

[![ci](https://github.com/memetics19/anvil/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/memetics19/anvil/actions/workflows/ci.yml?query=branch%3Amain)

Terraform and Ansible for a single-node Proxmox homelab.

An anvil is the fixed block a smith shapes everything else on. This repo plays the same
part for the lab: every host is forged from it, and if one breaks, it gets re-forged here
rather than repaired by hand.

- Terraform ([bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox)) defines the VMs.
- Ansible configures the Proxmox host and the guests.
- Secrets and site-specific values come from HashiCorp Vault.
- Terraform state lives in a single-node Ceph cluster, using its S3 gateway.

Work in progress. See [Roadmap](#roadmap).

## Hosts

| Host       | Role                                                          |
|------------|---------------------------------------------------------------|
| `pve`      | Proxmox VE 8.4, LAN gateway/NAT, NetBird, Ceph                |
| `frigate`  | Frigate, Mosquitto, Gotify, nginx, cloudflared                |
| `netbird`  | NetBird routing peer, Redis, ntfy, pulse, cloudflared         |
| `ragnarok` | ARR stack, IPTV EPG web, Filestash (S3 browser), cloudflared  |
| `vault`    | HashiCorp Vault (planned)                                     |

## Requirements

- macOS operator machine (uses the Keychain)
- Terraform >= 1.10
- Ansible, ansible-lint, yamllint, tflint, gitleaks, sshpass

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/terraform hashicorp/tap/vault ansible ansible-lint \
  gitleaks tflint yamllint jq pre-commit sshpass awscli age
ansible-galaxy collection install -r ansible/requirements.yml -p ~/.ansible/collections
# hvac for the community.hashi_vault lookup, in the Python that runs Ansible
"$(brew --prefix ansible)/libexec/bin/python" -m pip install hvac
pre-commit install
```

## Configuration

Nothing site-specific is committed: no addresses, MACs, domain, credentials or VM IDs.
Code refers to hosts by name only. Ansible and Terraform read one `site` dict from:

1. Vault, `kv/homelab/site`, when `VAULT_TOKEN` is set (`make site-to-vault` copies it
   there from the Keychain)
2. macOS Keychain, service `homelab`, account `site-bootstrap`, when there is no token
   yet or `kv/homelab/site` does not exist

This fails closed: with `VAULT_TOKEN` set, any other Vault error (sealed, unreachable,
token rejected) stops the run instead of quietly using the Keychain copy. Set
`HOMELAB_SITE_SOURCE=keychain` to use the Keychain copy on purpose; `make vault` allows
that fallback by itself (with a warning) so it can repair Vault. Each run prints which
source it used, and warns, without values, when the two copies differ.

[`site/site.example.yml`](site/site.example.yml) documents the structure.

Keychain accounts (service `homelab`):

| Account                                    | Used for                        |
|--------------------------------------------|---------------------------------|
| `pve-ip`, `vault-ip`                       | reaching Proxmox and Vault      |
| `site-bootstrap`                           | `site` dict before Vault exists |
| `pve-root-password`, `vm-sudo-password`    | SSH bootstrap, become password  |
| `pve-api-token`                            | Terraform provider              |
| `ceph-osd-disk-id`                         | Ceph OSD disk (by-id name)      |
| `ceph-s3-access-key`, `ceph-s3-secret-key` | Terraform state (S3 keys)       |
| `ceph-dashboard-password`                  | Ceph dashboard `admin` login    |
| `vault-init-json`                          | Vault unseal keys, root token   |
| `backup-age-recipient`, `backup-age-identity` | encrypting tfstate backups   |

## Usage

```sh
make bootstrap-ssh                # once: install your SSH key on all hosts
make host ARGS="--check --diff"   # dry run against the Proxmox host
make host
make ceph ARGS="--check --diff"   # see below before the first real run
make vms ARGS="--check --diff"    # guest roles and workloads (tags: base, docker, cloudflared,
                                  #   node_exporter, frigate, arr, iptv_epg, filestash)
make vm HOST=frigate              # one VM at a time
make lint
make secrets-scan
```

Infrastructure targets source `scripts/env.sh`, which loads endpoints and tokens from
the Keychain. Dry-run first. A box that matches the code reports `changed=0`.

## Vault

```sh
make vault                  # install/configure; leaves Vault sealed on a new box
scripts/vault-init.sh       # once, by the operator: keys go straight into the Keychain
make vault-unseal           # 3 of the 5 keys, read from the Keychain
make vault-policies site-to-vault
scripts/backup-key-init.sh  # once, by the operator: age key pair for backups
scripts/site-to-keychain.sh --yes  # by the operator: refresh the Keychain bootstrap copy from Vault
make backup                 # ~/homelab-backups: tfstate (age-encrypted) + Raft snapshot
scripts/backup-restore-tfstate.sh | jq .serial   # decrypts to stdout only
```

Restarting Vault seals it, so `make vault` refuses a run that would restart a running
Vault (config, systemd unit or package version change, including bumping
`vault_server_version`). Rerun it with `ARGS="-e vault_server_allow_restart=true"`, then
`make vault-unseal`; the play fails at the end if it left Vault sealed. A certificate change
only reloads Vault and does not seal it.

Vault's `kv/homelab/site` is the canonical site dict. The Keychain item `site-bootstrap` is
only a bootstrap copy; when a run warns that it is stale, refresh it with
`scripts/site-to-keychain.sh --yes`.

## Frigate

The `frigate_stack` role (`make vm HOST=frigate ARGS="--tags frigate"`) owns Frigate's
`config.yml`: edits made in the Frigate UI are overwritten on the next run. Change
`ansible/roles/frigate_stack/templates/config.yml.j2` instead. To try settings in the UI
first, run with `-e frigate_stack_manage_frigate_config=false`, then copy the result into
the template. A changed compose service is brought up on its own (`up -d --no-deps`); a
changed Frigate, mosquitto or frigate-notify config restarts only that container.
The public hostname reaches Frigate through nginx on the VM, and Frigate's own login
(port 8971) is the access control; the admin password is in Vault (`docs/secrets.md`).

## ragnarok

`make vm HOST=ragnarok` runs three compose projects, each through the `compose_project`
role. It compares the config hash compose stores on each container with the hash of the
rendered file and brings up only the services that differ (`up -d --no-deps`). Check mode
names them.

- `arr_stack`: `/home/ubuntu/docker-compose.yaml` (qBittorrent, Prowlarr, Jackett,
  FlareSolverr, Radarr, Sonarr). The apps keep their own settings and API keys in
  `./<app>/config`, which is not templated. The media library appears only as bind-mount
  sources in the template, and `tests/test_media_untouched.sh` keeps it that way.
- `iptv_epg`: nginx on port 8899 serving `/home/ubuntu/iptv-epg/output`. Nothing fills
  that directory, so the site returns 403.
- `filestash`: a read-only browser for the S3 gateway at `http://<ragnarok>:8334/`, bound
  to the VM's LAN address, with a 256 MB memory cap and no swap.
  - Log in with user `admin` and `admin_password` from Vault `kv/homelab/ragnarok/filestash`.
    The same password opens `/admin`.
  - The role generates the password straight into Vault on the first run.
  - `make ceph` creates the S3 user `filestash`. It owns no buckets and cannot create
    them; bucket policies let it list and read `tfstate`. Its keys go straight into the
    same Vault path, and Filestash keeps them on the server side.
  - Filestash rewrites its `config.json` at start, so the role manages only its own keys
    in it. Changes made in the admin console to the login, connections or sharing are
    overwritten.

## Ceph and the Terraform state bucket

`make ceph` builds a one-disk Ceph cluster on `pve` (monitor, manager, one OSD, pool
size 1), a RADOS Gateway on port 7480 of the host address, an S3 user `terraform` and a
bucket `tfstate`. The OSD disk is the `/dev/disk/by-id/` name in Keychain account
`ceph-osd-disk-id` (later `site.pve.ceph_osd_disk_id` in Vault), or
`-e ceph_osd_device=/dev/disk/by-id/...`.

**The first real run wipes that disk.** Before touching anything, the play refuses a disk
that holds `/` or `/boot/efi`, that the host boots from (EFI BootCurrent,
`proxmox-boot-uuids`, grub-pc install devices), has a mounted partition, kernel holders or
open handles, is named in a guest config or `storage.cfg`, is a PV in any non-Ceph VG, or
carries a ZFS pool that is imported or importable in any state other than `UNAVAIL`. A disk
that is already an OSD (Ceph VG, LVM on the disk and `ceph-volume` agree) is left alone; if
those signals disagree the play stops.

```sh
make ceph ARGS="--check --diff"   # safety checks plus a list of what would run
make ceph
```

The S3 keys are written to `/root/.ceph-rgw-terraform.json` (mode 600) on the host. Copy
them into the Keychain once:

```sh
source scripts/env.sh && keys=$(ssh root@"$PVE_IP" cat /root/.ceph-rgw-terraform.json) && security add-generic-password -U -s homelab -a ceph-s3-access-key -w "$(jq -r .access_key <<<"$keys")" && security add-generic-password -U -s homelab -a ceph-s3-secret-key -w "$(jq -r .secret_key <<<"$keys")"; unset keys
```

### Ceph dashboard

The dashboard is at `https://<pve-ip>:8443/` (self-signed certificate), user `admin`. The
generated password is in `/root/.ceph-dashboard-admin` (mode 600) on the host. Copy it into
the Keychain account `ceph-dashboard-password` once (`security` takes the secret on argv, so
it is briefly visible in the process list on your Mac):

```sh
source scripts/env.sh && security add-generic-password -U -s homelab -a ceph-dashboard-password -w "$(ssh root@"$PVE_IP" cat /root/.ceph-dashboard-admin)"
```

Known issue: Object Gateway zone and multisite pages return 500 on Proxmox. The mgr drops
supplementary groups and cannot read /etc/ceph/ceph.conf (a link into pmxcfs). Buckets and
users pages work; use Filestash on `ragnarok` or the aws CLI to browse objects.

## Terraform

Terraform manages the VMs and the Proxmox SDN zone and VNets. State is in the Ceph S3
bucket above. Site values (VM IDs, MACs) reach Terraform as `TF_VAR_site_json`, which
`scripts/env.sh` builds from the site source above (for the Keychain copy, python3 with
PyYAML, else the system Ruby, converts the YAML). `make tf-plan` prints the source.

```sh
make tf-init
make tf-plan     # writes terraform/homelab.tfplan and runs the plan guard
make tf-apply    # applies only that saved plan, after re-running the guard
```

Plans are transient: a saved plan contains site values, so it is written mode 600, removed
at the start of the next `tf-plan`, when the guard rejects it, and after `tf-apply`
(success or failure). The guard reads `terraform show -json` through a pipe; the JSON is
never written to disk.

`scripts/plan-guard.sh` refuses a plan that destroys or replaces anything, changes which
storage backs `ragnarok`'s disk (the media library), errored, or was made with `-target`.
Don't pass `-target` in `ARGS`. All three adopted VMs also carry `prevent_destroy`.
`tests/test_plan_guard.sh` tests the guard.

`frigate`, `netbird` and `ragnarok` were adopted with `import` blocks
([`terraform/imports.tf`](terraform/imports.tf)); a plan against the current box reports
no changes. SDN subnets need `sdn.subnets.<vnet>` entries (`cidr`, `gateway`) in the site
dict for `servers`, `cameras` and `personal`; the plan stops with a validation error until
they exist. `site_json` is also checked for quoted MACs and numeric VM IDs.

## Layout

```
ansible/
  inventory/      hosts by name; group_vars/all/site.yml resolves `site`
  playbooks/
  roles/
scripts/          env.sh, plan-guard.sh
site/             site.example.yml
terraform/        VMs, SDN, import blocks
tests/
```

## Secret scanning

[gitleaks](https://github.com/gitleaks/gitleaks) runs in pre-commit and in CI, over the full
history. [`.gitleaks.toml`](.gitleaks.toml) adds rules for:

- private IPv4 addresses
- Cloudflare tunnel tokens
- NetBird setup keys
- password hashes and literal passwords

`tests/test_secrets_scan.sh` checks that each rule fires on generated fixtures.

## Not managed here

- Cloudflare tunnels and public hostnames
- NetBird routes, ACLs and setup keys
- DHCP reservation for the Proxmox uplink on the home router
- App state kept in databases (indexers, API keys, Frigate recordings), which is
  reconfigured by hand after a rebuild

## Roadmap

- [x] Secret scanning, linters, CI
- [x] Inventory, SSH bootstrap, Proxmox host base role
- [ ] Host network, with automatic rollback
- [ ] SDN VLANs and inter-VLAN firewall
- [ ] Single-node Ceph and S3 gateway for Terraform state
- [ ] Terraform: adopt existing VMs and SDN, guard against destroys
- [x] Vault VM, Keychain-held unseal keys, snapshot backups
- [ ] Move secrets and site values into Vault
- [ ] Guest roles: base, Docker, node_exporter, cloudflared
- [ ] Workload roles for `frigate`, `ragnarok`, `netbird`
- [ ] Rebuild runbook, tested on a second server

## Known issues

- Frigate's camera has not answered since 2026-01-13, so there are no new recordings.
- Frigate's `genai` provider points at an Ollama address that does not answer.
- `ragnarok` `/home` is 98% full
- `ragnarok`'s IPTV EPG web serves an empty directory (403): no grabber fills it.

## License

[MIT](LICENSE)
