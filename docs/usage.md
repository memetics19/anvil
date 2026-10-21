# Usage

Day-to-day operation of a lab that is already built. To build one, see [setup.md](setup.md).

Placeholders: `<apps-address>` (the `apps` VM's lab address), `<apps-home-address>`, `<domain>`,
`<gateway-domain>`.

## Make targets

| Target | What it does |
|---|---|
| `make lint` | `terraform fmt -check`, tflint, yamllint and ansible-lint. Needs no secrets. |
| `make secrets-scan` | gitleaks over the git history and over the working tree (tracked and untracked, not ignored files). |
| `make bootstrap-ssh` | Installs `~/.ssh/id_ed25519.pub` on the Proxmox host and the adopted guests, with passwords from the Keychain. |
| `make host` | Proxmox host base: repositories, packages, time, `/etc/hosts`, Terraform API token, storage content types, the Homepage token (`--tags homepage`). |
| `make host-network` | Proxmox `/etc/network/interfaces` with a timed rollback. |
| `make enclave` | The secrets enclave on the Proxmox host: firewall, SDN apply, apt cache, NTP, cloud-init vendor data. |
| `make ceph` | Single-node Ceph, the S3 gateway, the `tfstate` bucket and the S3 users. The first real run wipes the OSD disk. |
| `make vms` | Every guest play in `ansible/playbooks/vms.yml`: base roles and all workloads. |
| `make vm HOST=<name>` | The same, limited to one VM: `frigate`, `netbird`, `ragnarok`, `vault` or `apps`. |
| `make test-netplan HOST=<name>` | Proves `guest_base`'s netplan checks reject broken input. It uses a temporary root and leaves `/etc/netplan` alone. |
| `make vault` | Installs and configures the Vault server. It leaves Vault sealed and refuses a restart unless allowed. |
| `make vault-unseal` | Unseals Vault with 3 of the 5 keys in Keychain `vault-init-json`. |
| `make vault-policies` | Writes each `vault/policies/<name>.hcl` that differs from Vault. |
| `make site-to-vault` | Copies Keychain `site-bootstrap` to `kv/homelab/site`. It refuses to overwrite a different value without `ARGS=--force`. |
| `make tf-init` | `terraform init` with the S3 backend endpoint built from `PVE_IP`. |
| `make tf-plan` | Saves `terraform/homelab.tfplan` (mode 600) and runs the plan guard on it. |
| `make tf-apply` | Applies the saved plan only, after running the guard again. Then it deletes the plan. |
| `make backup` | Terraform state (age-encrypted), a Vault Raft snapshot and the newest Vaultwarden backup, into `~/homelab-backups`. |
| `make vaultwarden-drill` | Restores the newest Vaultwarden backup into a temporary container on `apps`, checks it, then removes it. |

## Daily commands

Make targets that touch the lab load the Keychain values themselves. Source `env.sh` when
you run `vault`, `terraform` or the scripts by hand:

```sh
source scripts/env.sh
```

It exports `PVE_IP`, `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_TOKEN` (the root token),
the Proxmox and S3 credentials, and `TF_VAR_site_json`. It never prints a value.

Dry-run first, then apply:

```sh
make vm HOST=apps ARGS="--check --diff"
make vm HOST=apps
```

`ARGS` is passed to `ansible-playbook` (or to `terraform` for the `tf-*` targets), so tags and
extra vars work:

```sh
make vm HOST=ragnarok ARGS="--tags iptv"
make vm HOST=apps ARGS="--check --diff --tags pihole,caddy"
make host ARGS="--tags homepage"
make vault ARGS="-e vault_server_allow_restart=true"
```

The tags of `make vms`/`make vm` are listed at the top of `ansible/playbooks/vms.yml`.

## Adding a service behind the gateway

A service is one entry in `site.services` in Vault. Caddy serves it as
`https://<name>.<gateway-domain>`. Pi-hole answers that name with `<apps-home-address>`, and
Homepage shows a tile for it. Fields are documented in
`ansible/roles/caddy/defaults/main.yml`. The optional dashboard fields (`title`, `group`,
`icon`, `description`, `widget`) are in `ansible/roles/homepage/defaults/main.yml`.

Write the change with check-and-set, so a concurrent write is refused rather than lost:

```sh
source scripts/env.sh
cur=$(vault kv get -format=json -mount=kv homelab/site)
ver=$(jq -r .data.metadata.version <<<"$cur")
jq -c '.data.data | .site.services += [{name: "wiki", host: "hosts.ragnarok.ip", port: 8090,
       scheme: "http", title: "Wiki", group: "Other", description: "Notes"}]' <<<"$cur" |
  vault kv put -mount=kv -cas="$ver" homelab/site -
unset cur ver
```

`host` is a dotted path into the site dict. If the upstream is a new host, add it under
`site.hosts` in the same write. For a container on a network Caddy shares, use
`container: <name>` instead.

Then refresh the Keychain copy and apply:

```sh
scripts/site-to-keychain.sh --yes
make vm HOST=apps ARGS="--check --diff"
make vm HOST=apps
```

Before Pi-hole is touched, the run checks every entry. `tests/test_gateway.sh` and
`tests/test_homepage.sh` cover the rules. A name not in the Homepage catalog gets group
`Other` and no widget, unless the entry sets them. To take a service down but keep its
entry, set `enabled: false`. That removes its route and DNS record.

To undo a bad write, `vault kv rollback -mount=kv -version=<n> homelab/site` restores an
earlier version. `vault kv metadata get -mount=kv homelab/site` lists the versions.

## Secrets in Vault

[secrets.md](secrets.md) lists every path and key, and who writes each one. Keep values off
the command line and out of the terminal.

Write one key from the clipboard. `-` reads the value from stdin:

```sh
source scripts/env.sh
pbpaste | vault kv patch -mount=kv homelab/apps/vaultwarden smtp_password=-
pbcopy </dev/null    # clear the clipboard
```

`patch` adds or changes one key and needs the path to exist. `put` creates a path, but it
replaces every key at that path:

```sh
pbpaste | vault kv put -mount=kv homelab/apps/caddy cloudflare_dns_token=-
```

Read one key into the clipboard:

```sh
vault kv get -field=admin_token -mount=kv homelab/apps/vaultwarden | pbcopy
```

List what a path holds without printing values:

```sh
scripts/vault-kv-digests.sh homelab/apps/vaultwarden    # "<key> <sha256>" per key
```

After you change a secret, rerun the role that uses it, for example `make vm HOST=apps`.
`scripts/import-secrets.sh --verify` compares the secrets imported from the live VMs with
Vault and writes nothing.

## Backups

```sh
make backup
```

This writes to `~/homelab-backups` (directory mode 700, files 600) and keeps the newest 30 of
each kind:

- `tfstate-YYYYMMDD-HHMM.json.age`: Terraform state, encrypted to Keychain
  `backup-age-recipient`.
- `vault-YYYYMMDD-HHMM.snap`: a Vault Raft snapshot. It is encrypted by Vault's barrier and
  needs the unseal keys.
- `vaultwarden-YYYYMMDD-HHMMSS.tar.age`: the newest nightly Vaultwarden backup, copied from
  the Ceph bucket `vaultwarden-backups`.

The Vaultwarden job runs on `apps` every night at about 03:30 (`vaultwarden-backup.timer`).
It encrypts the backup with the same age key, uploads it to the bucket and keeps the newest
14. To run it by hand:

```sh
ssh ubuntu@<apps-address> 'sudo systemctl start vaultwarden-backup && journalctl -u vaultwarden-backup -n 20'
make backup
```

Restore drill: this needs the newest local copy to be the newest object in the bucket, so
run `make backup` first.

```sh
make vaultwarden-drill
```

Read a Terraform state backup. It decrypts to stdout only:

```sh
scripts/backup-restore-tfstate.sh | jq .serial                    # newest
scripts/backup-restore-tfstate.sh ~/homelab-backups/tfstate-<YYYYMMDD-HHMM>.json.age | jq .serial
```

To put a backup back into the bucket:

```sh
source scripts/env.sh
scripts/backup-restore-tfstate.sh <file> | terraform -chdir=terraform state push -
```

Terraform refuses a push with a different lineage or a lower serial than the current state.
Restoring Vault and Vaultwarden on a new box is covered in
[setup.md](setup.md#rebuilding-on-a-new-box).

## Safety rails

**Plan guard.** `make tf-plan` and `make tf-apply` run `scripts/plan-guard.sh` on the saved
plan. It refuses a plan that:

- deletes or replaces anything
- changes the storage behind the disks of `ragnarok` (the media library), `vault` or `apps`
- errored
- was made with `-target`

Don't pass `-target` in `ARGS`. The saved plan holds site values, so it is mode 600. It is
removed at the next `tf-plan`, when the guard rejects it, and after `tf-apply`. Its JSON is
only ever read through a pipe. `tests/test_plan_guard.sh` tests the guard.

**Timed rollbacks.** Network changes arm a rollback before they apply, and disarm it only
after the change is confirmed from the Mac:

- `make host-network`: the host restores its old `/etc/network/interfaces` after 120 s,
  unless it can still reach the Mac after the reload.
- `make enclave`: the enclave firewall and the SDN apply each use a timed rollback.
- `apps` firewall (`host_firewall`, ufw): ufw disables itself after 180 s, unless a fresh
  SSH connection and the DNS and HTTP checks from the Mac succeed first.
- Guest netplan: applied only with `-e guest_base_netplan_apply=true`, with a 120 s rollback.

**No surprise restarts.**

- `make vault` refuses a change that would restart a running Vault, because a restart seals
  it. Rerun with `ARGS="-e vault_server_allow_restart=true"`, then `make vault-unseal`.
- The NetBird client on `netbird` is never restarted, re-enrolled or upgraded by a normal
  run. Never run `make host-network` together with a `netbird` VM change: that VM is the
  emergency VPN path.

**Scoped compose.** Apps are brought up through the `compose_project` role. It compares the
config hash compose stores on each container with the rendered file, and runs
`docker compose up -d --no-deps` only for the services that differ. It never runs `down`
and never removes a container. Containers that are not in the file are reported and left
alone. Check mode names exactly the services a run would recreate.

This matters because one `apps` VM carries the home network's DNS. A project-wide `up`
would recreate Pi-hole, Vaultwarden and the gateway together. When you restart something by
hand, do the same: `sudo docker compose up -d --no-deps <service>` in the project directory,
or `sudo docker restart <container>`. For Pulse on `netbird`, don't run a plain
`docker compose up`. It recreates the locally built container every time.

**Other guards.**

- `make ceph` refuses an OSD disk that holds the root or EFI file system, is mounted, or is
  used by a guest, a non-Ceph LVM volume group or a ZFS pool.
- `tests/test_media_untouched.sh` checks that nothing in `ansible/` or `scripts/` can reach
  the media library.
- Secrets travel through pipes and stdin. They are never put on argv and never logged.

## Upgrading pinned versions

Edit the pin, dry-run, then apply. Check mode lists the containers that a new image would
recreate.

| What | Where | Notes |
|---|---|---|
| Container images | `<role>_image` in `ansible/roles/<role>/defaults/main.yml` (pihole, unbound, homepage, socket proxy, vaultwarden, filestash, threadfin, iptv python) | Pinned as `tag@sha256:digest`. Change both the tag and the digest. |
| Caddy | `caddy_version`, `caddy_cloudflare_version`, `caddy_xcaddy_version`, `caddy_go_version`, `caddy_builder_image`, `caddy_base_image` | A change builds a new image on `ragnarok` and loads it on `apps`. Read the Go version note in the defaults before you change Go. |
| Vault | `vault_server_version` | Restarts and seals Vault. Use `ARGS="-e vault_server_allow_restart=true"`, then `make vault-unseal`. |
| NetBird client | `netbird_peer_version` | The package is held. Bumping the version is the deliberate upgrade, and it restarts the client. |
| Pulse | `pulse_version` (a commit) | Rebuilds the image on `netbird`. |
| IPTV tools | `iptv_streamlink_version`, `iptv_mpegts_version`, `iptv_threadfin_db_version` | `make vm HOST=ragnarok ARGS="--tags iptv"` |
| node_exporter | `node_exporter_version` | |
| Proxmox provider | `terraform/versions.tf` | `make tf-init ARGS=-upgrade`, then `make tf-plan` |
| Ubuntu cloud image | `terraform/vm_vault.tf` | Don't edit it in place, because the provider would replace the download. Follow the comment at the top of the file. |
| gitleaks | `.github/workflows/ci.yml` and `.pre-commit-config.yaml` | Keep both on the same version. |
| Lint hooks | `.pre-commit-config.yaml` | `pre-commit autoupdate` |

Docker on the guests is not pinned. apt and unattended-upgrades update it.

## Tests

CI runs `make lint secrets-scan` and every `tests/test_*.sh`. To run them locally:

```sh
make lint secrets-scan
for t in tests/test_*.sh; do "$t" || echo "FAILED: $t"; done
```

`tests/test_vaultwarden.sh` needs `age` and `sqlite3`.

## Troubleshooting

**`site-source: cannot read kv/homelab/site: Vault is sealed (make vault-unseal)`.**
Vault restarted, for example after a reboot or a `make vault` run with
`vault_server_allow_restart`. Run `make vault-unseal`. To repair Vault itself while it is
down, `make vault` falls back to the Keychain copy on its own. For other targets, set
`HOMELAB_SITE_SOURCE=keychain` on purpose.

**`the Keychain bootstrap copy (site-bootstrap) is stale`.** Vault's `kv/homelab/site`
changed since the Keychain copy was made. Vault was used. Refresh the copy:

```sh
scripts/site-to-keychain.sh --yes
```

**`env.sh: Keychain item pve-ip (service homelab) not found`.** Add it (see
[setup.md](setup.md#keychain-items)). If the Keychain is locked, unlock it.

**`hvac is missing in the Python that runs Ansible`.** Run the `pip install` command the
message prints.

**Vaultwarden: `data/config.json (saved from the admin page) overrides <keys>`.** Someone
saved settings on the admin page. They are written to `data/config.json` and override the
role's environment. As a warning, the run continues. If a key weakens the setup (open
sign-ups, hints shown, no admin token, another domain, and similar), the run stops before
it touches the container. Open `https://pass.<gateway-domain>/admin`, choose **Reset
defaults**, then rerun `make vm HOST=apps`. The role never edits that file itself.

**Vaultwarden: `admin=429`.** Each run's admin-login check counts against Vaultwarden's rate
limit of 3 tries per 5 minutes. Wait 5 minutes and rerun.

**Homepage: `WARNING: widgets with an error: [<name>=<code> error]`.** The widget's app is
down, or its credential is missing or stale. `000` means no connection. Rerun the role that
owns that credential (see [secrets.md](secrets.md)):

```sh
make host ARGS="--tags homepage"                  # Proxmox and Ceph widgets
make vm HOST=ragnarok ARGS="--tags homepage"      # Sonarr, Radarr, Prowlarr
make vm HOST=frigate ARGS="--tags homepage"       # Frigate
make vm HOST=apps                                 # Pi-hole application password
```

To make widget errors fail the run instead, add `ARGS="-e homepage_strict_widgets=true"`.

**Pi-hole.** The role checks that Pi-hole answers through Unbound on both addresses, and that
its web UI answers. From a home device:

```sh
dig +short @<apps-home-address> example.com                 # resolution through Unbound
dig +short @<apps-home-address> dns.<gateway-domain>        # a gateway name
dig +short @<apps-home-address> <name>.lan.<domain>         # a local record
scutil --dns | grep nameserver                              # the Mac uses Pi-hole first
```

If a gateway name does not resolve, check that the entry is in `site.services` and is not
`enabled: false`. Then rerun `make vm HOST=apps ARGS="--tags pihole"`. Records added in the
Pi-hole UI are removed on the next run. Over NetBird, check the nameserver entry in the
dashboard and `netbird status -d`.

**Gateway: `routes not answering: [<name>=<code>]`.** `000` means no TLS or no connection.
Check the upstream from the Mac:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://<name>.<gateway-domain>/
```

The first run on a new box waits for the wildcard certificate. That needs
`cloudflare_dns_token` in `kv/homelab/apps/caddy`, and public resolvers that can see the
`_acme-challenge` record (`site.dns.acme_resolvers`). A `container` upstream whose project
has not run on `apps` yet is skipped, with a warning naming it. The next run picks it up.

**`plan-guard: refusing delete/replace`.** Find out why Terraform wants to replace the
resource, usually a changed attribute that forces a new one, and change the code so it
doesn't. Don't work around the guard.

**`site.sdn.subnets.{servers,cameras,personal} need cidr ...`.** The site dict lacks keys
Terraform validates. Add them in Vault (see [setup.md](setup.md#the-site-dict)).
