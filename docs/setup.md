# Setup

How to go from a bare Proxmox VE install to a running lab, and how to rebuild the lab on a
new box from backups. Day-to-day work is in [usage.md](usage.md).

Placeholders used below: `<proxmox-address>` (the host's lab address, Keychain `pve-ip`),
`<vault-address>`, `<apps-address>`, `<apps-home-address>`, `<domain>` and
`<gateway-domain>` (`<subdomain>.<domain>`, see [Service gateway](../README.md#service-gateway-private)).

## Operator machine

The operator machine is a Mac. Secrets and bootstrap values live in the macOS Keychain, and
the scripts call `security`.

Versions pinned in the repo:

| Tool | Version | Where it is pinned |
|---|---|---|
| Terraform | >= 1.10 | `terraform/versions.tf` |
| bpg/proxmox provider | 0.117.0 | `terraform/versions.tf` |
| gitleaks | 8.28.0 | `.github/workflows/ci.yml`, `.pre-commit-config.yaml` |
| ansible-lint | 25.9.2 | `.pre-commit-config.yaml` |
| yamllint | 1.37.1 | `.pre-commit-config.yaml` |
| Vault (server) | 2.2.0-1 | `vault_server_version` in `ansible/roles/vault_server/defaults/main.yml` |

Everything else is unpinned: Ansible, tflint, the Vault CLI, jq, age, awscli, sshpass,
pre-commit. Install them:

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/terraform hashicorp/tap/vault ansible ansible-lint \
  gitleaks tflint yamllint jq pre-commit sshpass awscli age
ansible-galaxy collection install -r ansible/requirements.yml -p ~/.ansible/collections
# hvac for the community.hashi_vault lookup, in the Python that runs Ansible
"$(brew --prefix ansible)/libexec/bin/python" -m pip install hvac
pre-commit install
```

Every Ansible target checks for `hvac` first and prints the exact `pip install` command when
it is missing.

`scripts/env.sh` converts the Keychain copy of the site dict from YAML with `python3` and
PyYAML, or with the system Ruby when PyYAML is missing. macOS ships Ruby, so nothing extra
is needed.

You need an SSH key pair at `~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`.
`make bootstrap-ssh` installs the public key on the hosts. Terraform puts it into cloud-init
for the `vault` and `apps` VMs (`ssh_public_key_path` in `terraform/variables.tf`).

## Keychain items

All items use service `homelab`. `scripts/env.sh` reads most of them and exports them as
environment variables. It skips missing items, so it works at every stage of the
bootstrap. Only `pve-ip` is required.

| Account | Holds | Created by | Read by |
|---|---|---|---|
| `pve-ip` | Proxmox host lab address | you | `env.sh` (`PVE_IP`, `PROXMOX_VE_ENDPOINT`, the Terraform S3 backend) |
| `vault-ip` | Vault VM address | you | `env.sh` (`VAULT_ADDR`) |
| `site-bootstrap` | Bootstrap copy of the `site` dict | you, then `scripts/site-to-keychain.sh` | `env.sh`, Ansible inventory, `scripts/site-to-vault.sh` |
| `pve-root-password` | Proxmox root password | you | `make bootstrap-ssh` |
| `vm-sudo-password` | `ubuntu` user's password on the guests | you | `make bootstrap-ssh`; `env.sh` (`ANSIBLE_BECOME_PASSWORD`) |
| `pve-api-token` | Terraform's Proxmox API token | `make host` (role `pve_host`) | `env.sh` (`PROXMOX_VE_API_TOKEN`) |
| `ceph-osd-disk-id` | `/dev/disk/by-id/` name of the Ceph OSD disk | you | `make ceph`, unless `site.pve.ceph_osd_disk_id` is set |
| `ceph-s3-access-key`, `ceph-s3-secret-key` | S3 keys for the Terraform state bucket | you, copied after `make ceph` | `env.sh` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) |
| `ceph-dashboard-password` | Ceph dashboard `admin` password | you, copied after `make ceph` | nobody (kept for you) |
| `vault-init-json` | Vault unseal keys and root token (JSON) | `scripts/vault-init.sh` | `env.sh` (`VAULT_TOKEN`), `scripts/vault-unseal.sh` |
| `backup-age-recipient` | age public key for backups | `scripts/backup-key-init.sh` | `scripts/backup.sh`, the `vaultwarden` role |
| `backup-age-identity` | age private key for backups | `scripts/backup-key-init.sh` | `scripts/backup-restore-tfstate.sh`, `make vaultwarden-drill` |

`scripts/vault-init.sh` also creates and deletes a throwaway `vault-init-probe` item to test
the Keychain write before it initializes Vault.

Add the plain values yourself:

```sh
security add-generic-password -s homelab -a pve-ip -w <proxmox-address>
security add-generic-password -s homelab -a vault-ip -w <vault-address>
security add-generic-password -s homelab -a ceph-osd-disk-id -w <by-id-name>
security add-generic-password -s homelab -a pve-root-password -w
security add-generic-password -s homelab -a vm-sudo-password -w
```

With `-w` as the last argument, `security` prompts for the password, so it stays off the
command line. To replace an item, add `-U`.

## The site dict

Nothing site-specific is committed. Addresses, MACs, VM IDs, the domain and the e-mail
address live in one `site` dict. [`site/site.example.yml`](../site/site.example.yml) shows
its structure with documentation addresses.

Ansible and Terraform read it from:

1. Vault, `kv/homelab/site` (KV v2, mount `kv`, key `site`). This is the canonical copy.
2. The Keychain item `site-bootstrap`. This is used when `VAULT_TOKEN` is not set yet, or when
   `kv/homelab/site` does not exist yet.

`scripts/site-source.sh` makes the choice and fails closed. If `VAULT_TOKEN` is set and Vault
is sealed, unreachable or rejects the token, the run stops. It does not quietly fall back to
the Keychain. Set `HOMELAB_SITE_SOURCE=keychain` to use the Keychain copy on purpose.
`make vault` allows the fallback on its own, with a warning, so it can repair a broken Vault.
Each run prints which source it used.

Terraform validates more than the example file shows. The plan stops with a validation
error until these keys exist (`terraform/variables.tf`):

- `sdn.subnets.servers`, `sdn.subnets.cameras`, `sdn.subnets.personal`: each needs `cidr` and `gateway`
- `sdn.enclave`: `subnet` and `gateway`
- quoted MACs and numeric `vmid`s for every host

### Create the bootstrap copy

Write the dict as YAML with a top-level `site:` key, outside the repo. Store it compressed,
the same form `scripts/site-to-keychain.sh` writes. `security -i` only reads lines under
4000 bytes.

```sh
source scripts/keychain-lib.sh
printf 'gz64:%s' "$(gzip -9n < ~/site.yml | base64 | tr -d '\n')" | kc_store_stdin site-bootstrap
rm ~/site.yml
scripts/site-keychain-read.sh | head -n 3   # check that it decodes
```

`kc_store_stdin` never overwrites an item. To replace it, delete it first with
`security delete-generic-password -s homelab -a site-bootstrap`.

### Move it into Vault

Once Vault is initialized and unsealed:

```sh
make site-to-vault             # prints "written" or "unchanged"
```

It refuses to replace a different value in Vault unless you pass `ARGS=--force`.

From then on, change the dict in Vault (see [usage.md](usage.md#adding-a-service-behind-the-gateway)).
When a run warns that the Keychain copy is stale, refresh it:

```sh
scripts/site-to-keychain.sh --yes
```

## First build

Run each step with `ARGS="--check --diff"` first, then without. A host that matches the code
reports `changed=0`.

1. **SSH keys.** Install your public key on the Proxmox host. The guests are added once they exist.

   ```sh
   make bootstrap-ssh ARGS="--limit proxmox"
   ```

2. **Proxmox host.** This step sets up apt repositories, packages, time and `/etc/hosts`.
   It creates the Terraform API user and token, and stores the token in the Keychain
   (`pve-api-token`). It also enables the `import` content type on storage `local`, which
   Terraform uses. The `homepage` tag needs Vault, so skip it for now.

   ```sh
   make host ARGS="--skip-tags homepage"
   ```

3. **Host network.** This writes `/etc/network/interfaces`: the bridges, the LAN gateway and
   NAT, and the IPTV port forwards. The change
   has a timed rollback (see [usage.md](usage.md#safety-rails)). Never run it in the same
   Ansible run as a change to the `netbird` VM.

   ```sh
   make host-network ARGS="--check --diff"
   make host-network
   ```

4. **Ceph and the state bucket.** The first real run wipes the OSD disk. Read
   [Ceph](../README.md#ceph-and-the-terraform-state-bucket) before you run it.

   ```sh
   make ceph ARGS="--check --diff"
   make ceph
   ```

   The `filestash` and `vaultwarden-backup` S3 users write their keys to Vault, which does
   not exist yet. The `tfstate` bucket and its S3 user are created before that step. Rerun
   `make ceph` after step 7.

   Copy the state bucket's keys into the Keychain:

   ```sh
   source scripts/env.sh && source scripts/keychain-lib.sh
   keys=$(ssh root@"$PVE_IP" cat /root/.ceph-rgw-terraform.json)
   jq -r .access_key <<<"$keys" | kc_store_stdin ceph-s3-access-key
   jq -r .secret_key <<<"$keys" | kc_store_stdin ceph-s3-secret-key
   unset keys
   ```

   The Ceph dashboard password is in `/root/.ceph-dashboard-admin` on the host. Copying it
   to `ceph-dashboard-password` is optional.

5. **Terraform.** This creates the `vault` and `apps` VMs and the SDN zone and VNets. The
   `frigate`, `netbird` and `ragnarok` VMs are adopted with `import` blocks in
   `terraform/imports.tf`, so they must already exist with their VM IDs.

   ```sh
   make tf-init
   make tf-plan            # prints the site source; the plan guard runs on the saved plan
   make tf-apply
   ```

6. **Vault.**

   ```sh
   make vault                    # installs and configures Vault; leaves it sealed
   scripts/vault-init.sh         # once: 5 unseal keys and the root token go to Keychain vault-init-json
   make vault-unseal             # 3 of the 5 keys, read from the Keychain
   make vault-policies
   make site-to-vault
   scripts/backup-key-init.sh    # once: age key pair for backups
   ```

   `make vault` copies Vault's CA certificate to `~/.config/homelab/vault-ca.pem`.
   `scripts/vault-init.sh` tells you how to print the unseal keys for an offline paper copy.
   Keep an offline copy of `backup-age-identity` too. Without it the backups cannot be read.

7. **Secrets.** Put the secrets the roles read into Vault. [secrets.md](secrets.md) lists
   every path and key. Some values come from the old VMs, through
   `scripts/import-secrets.sh`. Some are generated by the roles. You add the rest yourself:
   the Cloudflare tunnel token for each tunnel host, `kv/homelab/apps/caddy`
   `cloudflare_dns_token` (a Cloudflare API token that may only edit DNS in your zone), the
   NetBird setup keys, and optionally the Vaultwarden SMTP keys. See
   [usage.md](usage.md#secrets-in-vault) for writing them without putting them on the
   command line.

   Then finish the steps that needed Vault:

   ```sh
   make ceph                          # S3 users for Filestash and the Vaultwarden backups
   make host ARGS="--tags homepage"   # read-only Proxmox token for the dashboard
   ```

8. **Secrets enclave.** This step sets up the enclave's firewall, the SDN apply, the apt
   cache, NTP and the cloud-init vendor data on the Proxmox host. Terraform must have
   created the zone and VNet first.

   ```sh
   make enclave ARGS="--check"
   make enclave
   ```

9. **Guests.** Install your key on the guests, then configure them.

   ```sh
   make bootstrap-ssh ARGS="--limit guests"
   make vms ARGS="--check --diff"
   ```

   Run the VMs one at a time. Do `apps` last, because its dashboard reads credentials that
   the other roles create:

   ```sh
   make vm HOST=vault
   make vm HOST=frigate
   make vm HOST=netbird
   make vm HOST=ragnarok
   make vm HOST=apps
   ```

10. **Backups.**

    ```sh
    make backup
    make vaultwarden-drill   # after the first nightly Vaultwarden backup exists
    ```

Then do the hand steps under [Not managed here](#not-managed-here).

## Rebuilding on a new box

This runbook has not been tested on a second server yet (see the Roadmap in the README). It
needs:

- the Mac's Keychain (service `homelab`)
- `~/homelab-backups`, with `tfstate-*.json.age`, `vault-*.snap` and `vaultwarden-*.tar.age`
- the offline copies of the unseal keys and the age identity, if the Keychain is lost

The repo does not back up the disks of `frigate`, `netbird` and `ragnarok`. That includes
the media library, app databases and Frigate recordings. Restore those VMs from your own
Proxmox backups with their old VM IDs before you plan. Otherwise the plan shows them as new
VMs to create. Do not apply that plan.

1. Install Proxmox VE with the same addresses as before. If the addresses change, update
   `pve-ip`, `vault-ip` and the Keychain copy of the site dict.
2. Set the new OSD disk: `ceph-osd-disk-id`, or `site.pve.ceph_osd_disk_id` in the site dict.
3. Run steps 1 to 4 of [First build](#first-build). The new S3 user has new keys. Delete the
   old `ceph-s3-access-key` and `ceph-s3-secret-key` items before you copy the new ones in.
4. Restore the Terraform state into the empty bucket, then plan:

   ```sh
   source scripts/env.sh
   make tf-init
   scripts/backup-restore-tfstate.sh | jq .serial      # check the newest backup decrypts
   scripts/backup-restore-tfstate.sh | terraform -chdir=terraform state push -
   make tf-plan
   make tf-apply
   ```

   `backup-restore-tfstate.sh` takes a file name to restore an older backup. It only ever
   writes to stdout.
5. Restore Vault from the newest Raft snapshot. The new Vault VM starts uninitialized.
   `scripts/vault-init.sh` refuses to run because `vault-init-json` still holds the old keys.
   That is what you want, because the snapshot needs those keys. Initialize a throwaway
   cluster, restore the snapshot over it, then unseal with the old keys. This is not
   scripted:

   ```sh
   make vault
   source scripts/env.sh
   init=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)   # throwaway
   jq -r '.unseal_keys_b64[0]' <<<"$init" | jq -R '{key: .}' |
     curl -fsS --cacert "$VAULT_CACERT" -X PUT --data-binary @- "$VAULT_ADDR/v1/sys/unseal" | jq .sealed
   VAULT_TOKEN=$(jq -r .root_token <<<"$init") \
     vault operator raft snapshot restore -force ~/homelab-backups/vault-<YYYYMMDD-HHMM>.snap
   unset init
   make vault-unseal                 # the old keys, from vault-init-json
   ```

   After this, the site dict, every secret and the old root token are back.
6. Run `make ceph` again. The new S3 users' keys replace the old ones in Vault. Then run
   `make host ARGS="--tags homepage"`.
7. Run steps 8 and 9 of [First build](#first-build). `make vm HOST=apps` starts Vaultwarden
   with an empty data directory.
8. Restore Vaultwarden. Run `make vaultwarden-drill` first if the bucket already holds a
   backup. Then restore into the live data directory with the container stopped. The
   archive holds one directory, `vaultwarden/`, with the database, attachments, sends, the
   RSA keys and any `config.json`. This step is not scripted:

   ```sh
   age -d -i <(security find-generic-password -s homelab -a backup-age-identity -w) \
       ~/homelab-backups/vaultwarden-<YYYYMMDD-HHMMSS>.tar.age |
     ssh ubuntu@<apps-address> 'sudo install -d -m 700 /var/tmp/vw-restore && sudo tar -x -f - -C /var/tmp/vw-restore'
   ssh ubuntu@<apps-address>
   sudo docker stop vaultwarden
   sudo mv /opt/vaultwarden/data /opt/vaultwarden/data.empty
   sudo mv /var/tmp/vw-restore/vaultwarden /opt/vaultwarden/data
   sudo docker start vaultwarden
   exit
   make vm HOST=apps   # checks /alive, the admin token and that sign-ups are closed
   ```

   If the run warns that `data/config.json` overrides settings, see
   [usage.md](usage.md#troubleshooting).
9. Run `make backup` and redo the hand steps below.

## Not managed here

These are set by hand and must be redone after a rebuild:

- **Cloudflare:** the tunnels and their public hostnames, and the API token Caddy uses for
  DNS-01.
- **NetBird dashboard:** routes, groups, ACLs, setup keys, and the nameserver entry. That
  entry points at `<apps-address>` on port 53, with match domains left empty, or set to
  `lan.<domain>` and `<gateway-domain>`. See the README, [apps (Pi-hole)](../README.md#apps-pi-hole).
- **Home router:** the DHCP reservation for the Proxmox uplink, and the reservation of
  `site.hosts.apps.home_ip` for `site.hosts.apps.home_mac`. Also the DNS servers DHCP hands
  out: `<apps-home-address>` first, the router second.
- **The Cisco switch:** its ports and VLANs.
- **App-level settings kept in app databases:** indexers and download clients in the ARR
  apps, Threadfin mappings, ntfy users and access rules, Frigate recordings, Pi-hole block
  lists added in its UI, and Vaultwarden accounts. The repo does not template them.
