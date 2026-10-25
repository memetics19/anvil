# Usage

Running a lab that is already built. To build one, see [setup.md](setup.md).

The `anvil` CLI runs these make targets for you, from `anvil up` for the whole lab to a
single service. See [cli.md](cli.md).

Placeholders: `<apps-address>` (the `apps` VM's lab address), `<apps-home-address>`,
`<domain>`, `<gateway-domain>`.

## Make targets

| Target | What it does |
|---|---|
| `make lint` | `terraform fmt -check`, tflint, yamllint and ansible-lint. Needs no secrets. |
| `make secrets-scan` | gitleaks over the git history and the working tree (tracked and untracked files, not ignored ones). Needs no secrets. |
| `make bootstrap-ssh` | Installs `~/.ssh/id_ed25519.pub` on the Proxmox host and the adopted guests, with passwords from the Keychain. |
| `make grow-disk HOST=<vm> ADD=<GB>` | Grows a VM's disk by ADD GB while it runs: Terraform (only that disk may change, and only grow), the site dict, then the partition and filesystem inside the VM. `CHECK=1` plans only, `MOUNT=` names the LVM volume. `anvil increase-disk` wraps it. |
| `make rotate SECRET=<names>` | New API keys for radarr, sonarr, prowlarr (or `arr`): each app makes its own, Prowlarr's links follow, then Vault and the dashboard. `CHECK=1` is check mode. `anvil rotate` wraps it. |
| `make forget-host HOST=<name>` | Drops one host's stored SSH host key after you rebuilt it on purpose, so the next run records the new key. Prints what it removed. `HOST=switch` drops the key in `build/switch/known_hosts`. |
| `make host` | Proxmox host base: repositories, packages, time, `/etc/hosts`, the Terraform API token, storage content types, and the Homepage token (`--tags homepage`). |
| `make host-network` | Proxmox `/etc/network/interfaces`, with a timed rollback. |
| `make enclave` | The secrets enclave on the Proxmox host: firewall, SDN apply, apt cache, NTP, cloud-init vendor data. |
| `make vlans` | VLANs 10, 20 and 30 on the Proxmox host: the routed segments firewall, then the gateway addresses, DHCP and NTP per VLAN. |
| `make switch` | The Cisco switch's ports and VLANs. A dry run that prints the commands. `ARGS="-e network_switch_apply=true"` applies, checks and saves. |
| `make ceph` | Single-node Ceph, the S3 gateway, the `tfstate` bucket and the S3 users. The first real run wipes the OSD disk. |
| `make vms` | Every play in `ansible/playbooks/vms.yml`: the base roles and all workloads. |
| `make vm HOST=<name>` | The same for one VM: `frigate`, `netbird`, `ragnarok`, `vault` or `apps`. |
| `make test-netplan HOST=<name>` | Checks that `guest_base` rejects a broken netplan, in a temporary root. `/etc/netplan` is not touched. |
| `make vault` | Installs and configures the Vault server. Leaves Vault sealed and refuses a restart unless allowed. |
| `make vault-unseal` | Unseals Vault with 3 of the 5 keys in Keychain `vault-init-json`. |
| `make vault-policies` | Writes each `vault/policies/<name>.hcl` that differs from Vault. |
| `make site-to-vault` | Copies Keychain `site-bootstrap` to `kv/homelab/site`. Refuses to overwrite a different value without `ARGS=--force`. |
| `make tf-init` | `terraform init`, with the S3 backend endpoint built from `PVE_IP`. |
| `make tf-plan` | Saves `terraform/homelab.tfplan` (mode 600) and runs the plan guard on it. |
| `make tf-apply` | Applies only the saved plan, after running the guard again, then deletes the plan. |
| `make backup` | Encrypted Terraform state, a Vault Raft snapshot and the newest Vaultwarden backup, into `~/homelab-backups`. |
| `make vaultwarden-drill` | Restores the newest Vaultwarden backup into a temporary container on the `vaultwarden` VM, checks it, then removes it. |
| `make provision-iso NAME=<box>` | Builds the Proxmox VE automated install ISO for `site.provision.machines.<box>` into `build/provision/<box>.iso`, mode 600, or for `media: pxe` the netboot payload on the Proxmox host ([provisioning.md](provisioning.md)). |
| `make provision NAME=<box>` | A dry run: the guard, read only BMC reads and every planned Redfish or IPMI call. `ARGS="-e provision_confirm=<box>"` installs. |
| `make provision-clean NAME=<box>` | Deletes the ISO and the netboot payload on the Proxmox host. Both hold the root password hash. |
| `make docs` | Builds this documentation into `build/site` with the `mkdocs` on your PATH. |
| `make docs-publish` | Builds the same site in a throwaway venv and publishes it at `https://docs.<gateway-domain>`. |
| `make cli` | Builds the `anvil` CLI into `build/anvil` ([cli.md](cli.md)). |

## Daily commands

The make targets load what they need from the Keychain. When you run `vault`,
`terraform` or the scripts by hand, source `env.sh` first:

```sh
source scripts/env.sh
```

It exports `PVE_IP`, `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_TOKEN` (the root token), the
Proxmox and S3 credentials and `TF_VAR_site_json`. It never prints a value.

Dry-run, then apply:

```sh
make vm HOST=apps ARGS="--check --diff"
make vm HOST=apps
```

`ARGS` goes to `ansible-playbook`, or to `terraform` for the `tf-*` targets, so tags and
extra vars work:

```sh
make vm HOST=ragnarok ARGS="--tags iptv"
make vm HOST=apps ARGS="--check --diff --tags pihole,caddy"
make host ARGS="--tags homepage"
make vault ARGS="-e vault_server_allow_restart=true"
```

The tags for `make vms` and `make vm` are listed at the top of `ansible/playbooks/vms.yml`.

## Adding a service behind the gateway

A service is one entry in `site.services` in Vault. Caddy serves it as
`https://<name>.<gateway-domain>`, Pi-hole answers that name with `<apps-home-address>`,
and Homepage shows a tile for it. The fields are documented in
`ansible/roles/caddy/defaults/main.yml`, and the optional dashboard fields (`title`,
`group`, `icon`, `description`, `widget`) in `ansible/roles/homepage/defaults/main.yml`.

Write the change with check-and-set, so a concurrent write fails instead of getting lost:

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

The run checks every entry before it touches Pi-hole. `tests/test_gateway.sh` and
`tests/test_homepage.sh` cover the rules. To take a service down but keep its entry, set
`enabled: false`, which removes its route and DNS record.

A site that Caddy serves itself, with no upstream, is a `static` entry: `{name: docs,
static: docs}`. `static` names a key of `caddy_static_sites` (the directory built on the
controller). It takes no `port`, `scheme` or other upstream field. See
[Publishing the docs](#publishing-the-docs).

To undo a bad write, list the versions with `vault kv metadata get -mount=kv homelab/site`
and restore one with `vault kv rollback -mount=kv -version=<n> homelab/site`.

## Publishing the docs

This documentation is also served privately at `https://docs.<gateway-domain>`, from the
LAN and over NetBird like the other open services. After a docs change:

```sh
make docs-publish
```

It builds the site the GitHub Pages workflow builds (`scripts/docs-build.sh`, the pinned
`docs/requirements.txt`) in a venv under `build/` that it removes afterwards. The build
date is the last commit's, so an unchanged tree builds identical files. Then it runs
`make vm HOST=apps ARGS="--tags docs"`, which copies `build/site` to
`/opt/caddy/sites/docs` on `apps` only when its content hash changed. Caddy serves those
files from a read-only mount (`file_server`), so no container restarts and no reload. Add
`ARGS=--check` for a dry run. The docs hold no secrets, addresses or domain.

The route is the `site.services` entry `{name: docs, static: docs}`. Pi-hole's record and
the Homepage tile (Infrastructure) come from that entry, like any other service.

## Secrets in Vault

[secrets.md](secrets.md) lists every path and key and who writes it. Keep values off the
command line and out of the terminal.

Write one key from the clipboard. `-` reads the value from stdin:

```sh
source scripts/env.sh
pbpaste | vault kv patch -mount=kv homelab/apps/vaultwarden smtp_password=-
pbcopy </dev/null    # clear the clipboard
```

`patch` adds or changes one key at a path that already exists. `put` creates a path, but
replaces every key at it:

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
scripts/vault-kv-digests.sh homelab/apps/vaultwarden kv # the mount, kv when none is given
```

After you change a secret, rerun the role that uses it, for example `make vm HOST=apps`.
`scripts/import-secrets.sh --verify` compares the secrets imported from the live VMs with
Vault and writes nothing.

## Backups

```sh
make backup
```

This writes to `~/homelab-backups` (directory mode 700, files 600) and keeps the newest 30
of each kind:

- `tfstate-YYYYMMDD-HHMM.json.age`: Terraform state, encrypted to Keychain
  `backup-age-recipient`
- `vault-YYYYMMDD-HHMM.snap`: a Vault Raft snapshot, encrypted by Vault's barrier, so it
  needs the unseal keys
- `vaultwarden-YYYYMMDD-HHMMSS.tar.age`: the newest nightly Vaultwarden backup, copied
  from the Ceph bucket `vaultwarden-backups`

The Vaultwarden job runs on the `vaultwarden` VM every night at about 03:30
([details](services.md#backups)). To run it by hand and fetch the result:

```sh
ssh -J root@<proxmox-address> ubuntu@<vaultwarden-address> 'sudo systemctl start vaultwarden-backup && journalctl -u vaultwarden-backup -n 20'
make backup
```

The restore drill uses the newest local copy, which must also be the newest object in the
bucket, so run `make backup` first:

```sh
make vaultwarden-drill
```

Read a Terraform state backup. It decrypts to stdout only:

```sh
scripts/backup-restore-tfstate.sh | jq .serial                    # newest
scripts/backup-restore-tfstate.sh ~/homelab-backups/tfstate-<YYYYMMDD-HHMM>.json.age | jq .serial
```

Push one back into the bucket:

```sh
source scripts/env.sh
scripts/backup-restore-tfstate.sh <file> | terraform -chdir=terraform state push -
```

Terraform refuses a push with a different lineage or a lower serial than the current state.
Restoring Vault and Vaultwarden on a new box is in
[setup.md](setup.md#rebuilding-on-a-new-box).

## Safety rails

### Plan guard

`make tf-plan` and `make tf-apply` run `scripts/plan-guard.sh` on the saved plan. It
refuses a plan that:

- deletes or replaces anything
- changes the storage behind the disks of `ragnarok` (the media library), `vault`, `apps`
  or `vaultwarden` (Vaultwarden's data)
- errored, or is incomplete, for example because it was made with `-target`

Don't pass `-target` in `ARGS`. All six VMs, and the VLAN zone with its VNets and
subnets, also carry `prevent_destroy`.

The saved plan holds site values, so it is mode 600. It is removed at the next `tf-plan`,
when the guard rejects it, and after `tf-apply`, whether that succeeds or fails. The guard
reads its JSON through a pipe, so the JSON never lands on disk. `tests/test_plan_guard.sh`
tests the guard.

### Timed rollbacks

Network changes arm a rollback before they apply, and disarm it only after the Mac
confirms the change:

- `make host-network`: the host restores its old `/etc/network/interfaces` after 120 s
  unless it can still reach the Mac after the reload.
- `make enclave`: the enclave firewall and the SDN apply each have a 120 s rollback.
- `make vlans`: the firewall and the VLAN gateway addresses each have a 120 s rollback.
- The `apps` firewall: ufw disables itself after 180 s unless a fresh SSH connection and
  the DNS and HTTP checks from the Mac succeed first.
- Guest netplan: applied only with `-e guest_base_netplan_apply=true`, with a 120 s
  rollback.

### No surprise restarts

Restarting Vault seals it. `make vault` refuses any change that would restart a running
Vault: config, systemd unit or package version, including a bump of
`vault_server_version`. Rerun with `ARGS="-e vault_server_allow_restart=true"`, then
`make vault-unseal`. The play fails at the end if it left Vault sealed. A certificate change
only reloads Vault and does not seal it.

The NetBird client on `netbird` is never restarted, re-enrolled or upgraded by a normal
run. That VM is the emergency VPN path, so never run `make host-network` together with a
`netbird` VM change.

### Scoped compose

Every app comes up through the `compose_project` role. It compares the config hash compose
stores on each container with the rendered file and runs `docker compose up -d --no-deps`
only for the services that differ. It never runs `down` or removes a container. Containers
that are not in the file, or whose labels it cannot read, are reported and left alone.
Check mode names the services a run would recreate.

This matters because the `apps` VM carries the home network's DNS. A project-wide `up`
would recreate Pi-hole, Vaultwarden and the gateway together. When you restart something by
hand, do the same: `sudo docker compose up -d --no-deps <service>` in the project
directory, or `sudo docker restart <container>`. For Pulse on `netbird`, don't run a plain
`docker compose up`, because it recreates the locally built container every time.

### Other guards

- `make ceph` refuses an OSD disk that holds the root or EFI file system, is mounted, or is
  used by a guest, a non-Ceph LVM volume group or a ZFS pool. The full list is in
  [Ceph](services.md#ceph).
- `tests/test_media_untouched.sh` checks that nothing in `ansible/` or `scripts/` can reach
  the media library.
- Secrets travel through pipes and stdin. They never go on argv and are never logged.

### Self-hosted NetBird

The server runs next to NetBird's cloud service on the `netbird` VM
([services.md](services.md#self-hosted-netbird-server)). If a client of the self-hosted
network does not connect while the dashboard loads, gRPC is not getting through the
Cloudflare tunnel. Check the hand steps in [setup.md](setup.md#self-hosted-netbird) (HTTP2
connection on the route, gRPC on in the zone). `docker logs netbird-caddy` on `netbird`
shows whether gRPC requests arrive. Until it works, use the `cloud` profile.

If peers connect but a connection that needs the relay fails (`Relayed` with no traffic in
`netbird status -d`), the relay's WebSocket may not pass the HTTP/2 route. Add a second
public hostname for the same name with path `^/relay`, the same service and TLS settings
but HTTP2 connection off, and move it above the first.

Status of the routing peer on the VM:
`sudo netbird status -d --daemon-addr unix:///var/run/netbird-home.sock`.

## Upgrading pinned versions

Edit the pin, dry-run, then apply. Check mode lists the containers a new image would
recreate.

| What | Where | Notes |
|---|---|---|
| Container images | `<role>_image` in `ansible/roles/<role>/defaults/main.yml` (pihole, unbound, homepage, socket proxy, vaultwarden, filestash, threadfin, iptv python) | Pinned as `tag@sha256:digest`. Change both. |
| Caddy | `caddy_version`, `caddy_cloudflare_version`, `caddy_xcaddy_version`, `caddy_go_version`, `caddy_builder_image`, `caddy_base_image` | Builds a new image on `ragnarok` and loads it on `apps`. Read the Go note in the defaults before you change Go. |
| Vault | `vault_server_version` | Restarts and seals Vault. Use `ARGS="-e vault_server_allow_restart=true"`, then `make vault-unseal`. |
| cloudflared | `cloudflared_version` | Held at that version. `make vms ARGS="--tags cloudflared"` upgrades one connector at a time and stops if one does not come back ready. |
| NetBird client | `netbird_peer_version` | The package is held. Bumping this is the upgrade, and it restarts the client. |
| Pulse | Nothing within a major version: `pulse-update` deploys each new release by itself. `pulse_track` picks the major (or pins a tag) | A failed release is rolled back and skipped until a newer one. Images for its Caddy, mkdocs, cosign and data copies are `pulse_*_image`. |
| Self-hosted NetBird | `netbird_server_image`, `netbird_server_dashboard_image`, `netbird_server_caddy_image` | Pinned as `tag@sha256:digest`. Read NetBird's release notes first. `make vm HOST=netbird ARGS="--tags netbird_server"` |
| IPTV tools | `iptv_streamlink_version`, `iptv_mpegts_version`, `iptv_threadfin_db_version` | `make vm HOST=ragnarok ARGS="--tags iptv"` |
| node_exporter | `node_exporter_version` | |
| Proxmox provider | `terraform/versions.tf` | `make tf-init ARGS=-upgrade`, then `make tf-plan` |
| Ubuntu cloud image | `terraform/vm_vault.tf` | Don't edit it in place, or the provider replaces the download. Follow the comment at the top of the file. |
| gitleaks | `.github/workflows/ci.yml`, `.pre-commit-config.yaml` | Keep both on the same version. |
| Lint hooks | `.pre-commit-config.yaml` | `pre-commit autoupdate` |

Docker on the guests is not pinned. apt and unattended-upgrades keep it current.

## Tests

CI runs `make lint secrets-scan`, every `tests/test_*.sh` and the CLI's Go tests. To run
them locally:

```sh
make lint secrets-scan
for t in tests/test_*.sh; do "$t" || echo "FAILED: $t"; done
(cd cli && go vet ./... && go test ./...)
```

`tests/test_vaultwarden.sh` needs `age` and `sqlite3`.

[gitleaks](https://github.com/gitleaks/gitleaks) also runs in pre-commit. Besides its
default rules, [`.gitleaks.toml`](../.gitleaks.toml) catches private IPv4 addresses,
Cloudflare tunnel tokens, NetBird setup keys, password hashes and literal passwords.
`tests/test_secrets_scan.sh` checks that each rule fires on generated fixtures.

## Troubleshooting

### `site-source: cannot read kv/homelab/site: Vault is sealed (make vault-unseal)`

Vault restarted, for example after a reboot or a `make vault` run with
`vault_server_allow_restart`. Run `make vault-unseal`. To repair Vault itself while it is
down, `make vault` falls back to the Keychain copy on its own. For other targets, set
`HOMELAB_SITE_SOURCE=keychain`.

### `the Keychain bootstrap copy (site-bootstrap) is stale`

`kv/homelab/site` changed since the Keychain copy was made. The run used Vault. Refresh
the copy:

```sh
scripts/site-to-keychain.sh --yes
```

### `env.sh: Keychain item pve-ip (service homelab) not found`

Add it (see [setup.md](setup.md#keychain-items)), or unlock the Keychain.

### `hvac is missing in the Python that runs Ansible`

Run the `pip install` command the message prints.

### Vaultwarden: `data/config.json (saved from the admin page) overrides <keys>`

Someone saved settings on the admin page, and they override the role's environment. As a
warning, the run continues. If a key weakens the setup, the run stops before it touches
the container. Open `https://pass.<gateway-domain>/admin`, choose Reset defaults, then
rerun `make vm HOST=apps`. The role never edits that file itself.

### Vaultwarden: `admin=429`

Each run's admin-login check counts against Vaultwarden's limit of 3 tries per 5 minutes.
Wait 5 minutes and rerun.

### Homepage: `WARNING: widgets with an error: [<name>=<code> error]`

The widget's app is down, or its credential is missing or stale. `000` means no
connection. Rerun the role that owns the credential:

```sh
make host ARGS="--tags homepage"                  # Proxmox and Ceph widgets
make vm HOST=ragnarok ARGS="--tags homepage"      # Sonarr, Radarr, Prowlarr
make vm HOST=frigate ARGS="--tags homepage"       # Frigate
make vm HOST=apps                                 # Pi-hole application password
```

To make widget errors fail the run, add `ARGS="-e homepage_strict_widgets=true"`.

### Pi-hole

The role checks that Pi-hole answers through Unbound on both addresses and that its web UI
answers. From a home device:

```sh
dig +short @<apps-home-address> example.com                 # resolution through Unbound
dig +short @<apps-home-address> dns.<gateway-domain>        # a gateway name
dig +short @<apps-home-address> <name>.lan.<domain>         # a local record
scutil --dns | grep nameserver                              # the Mac uses Pi-hole first
```

If a gateway name does not resolve, check that its entry is in `site.services` and not
`enabled: false`, then rerun `make vm HOST=apps ARGS="--tags pihole"`. Over NetBird,
check the nameserver entry in the dashboard and `netbird status -d`.

### Gateway: `routes not answering: [<name>=<code>]`

`000` means no TLS or no connection. Check the upstream from the Mac:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://<name>.<gateway-domain>/
```

The first run on a new box waits for the wildcard certificate. That needs
`cloudflare_dns_token` in `kv/homelab/apps/caddy`, and public resolvers that can see the
`_acme-challenge` record (`site.dns.acme_resolvers`). A `container` upstream whose project
has not run on `apps` yet is skipped with a warning, and the next run picks it up.

### `plan-guard: refusing delete/replace`

Find out why Terraform wants to replace the resource, usually a changed attribute that
forces a new one, and change the code so it doesn't. Don't work around the guard.

### `site.sdn.subnets.{servers,cameras,personal} need cidr ...`

The site dict lacks keys Terraform checks. Add them in Vault (see
[setup.md](setup.md#the-site-dict)).
