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
| `ragnarok` | ARR stack, IPTV, Filestash (S3 browser), cloudflared          |
| `vault`    | HashiCorp Vault (planned)                                     |
| `apps`     | Pi-hole with Unbound (home and lab DNS), service gateway (Caddy), Homepage dashboard, Vaultwarden |

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
                                  #   node_exporter, frigate, arr, iptv_epg, filestash, iptv,
                                  #   pihole)
make vm HOST=frigate              # one VM at a time
make backup                       # Terraform state, Vault snapshot, newest Vaultwarden backup
make vaultwarden-drill            # restore the newest Vaultwarden backup into a temporary container
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

`make vm HOST=ragnarok` runs four compose projects, each through the `compose_project`
role. It compares the config hash compose stores on each container with the hash of the
rendered file and brings up only the services that differ (`up -d --no-deps`). Check mode
names them. It never runs `down` or removes anything. It reports containers that are not in
the file, and containers whose labels it cannot read, and leaves them alone. It refuses a
project directory inside the media library.
`tests/test_media_untouched.sh` (also in CI) checks `ansible/` and `scripts/` for anything
that could reach the media library.

- `arr_stack`: `/home/ubuntu/docker-compose.yaml` (qBittorrent, Prowlarr, Jackett,
  FlareSolverr, Radarr, Sonarr). The apps keep their own settings and API keys in
  `./<app>/config`, which is not templated. The media library appears only as bind-mount
  sources in the template, and `tests/test_media_untouched.sh` keeps it that way.
- `iptv_epg`: nginx on port 8899 serving `/home/ubuntu/iptv-epg/output`, where the `iptv`
  role's guide grabber writes `guide.xml`.
- `iptv`: IPTV, see [IPTV](#iptv).
- `filestash`: a read-only browser for the S3 gateway at `http://<ragnarok>:8334/`, bound
  to the VM's LAN address, with a 256 MB memory cap and no swap.
  - It runs as its own host user (uid 10001, not the VM's first user, who owns the media),
    on a read-only root filesystem, with all capabilities dropped and no-new-privileges.
    Only that user can read its state, where the S3 keys are. The role never changes owners
    recursively. After a uid change it stops with a message, and you chown
    `/opt/filestash/state` by hand once.
  - Log in with user `admin` and `admin_password` from Vault `kv/homelab/ragnarok/filestash`.
    The same password opens `/admin`.
  - The role generates the password straight into Vault on the first run.
  - `make ceph` creates the S3 user `filestash`. It owns no buckets and cannot create
    them; bucket policies let it list and read `tfstate`. Its keys go straight into the
    same Vault path, and Filestash keeps them on the server side.
  - Filestash rewrites its `config.json` at start, so the role manages only its own keys
    in it. Changes made in the admin console to the login, connections or sharing are
    overwritten.

## netbird

`make vm HOST=netbird` runs the "Netbird workloads" play. This VM is the emergency VPN path:
never run it in the same Ansible run as `make host-network`.

- `netbird_peer`: the NetBird client from NetBird's apt repository (signing key pinned by
  checksum), the routing peer on NetBird's cloud service. The package is pinned to
  `netbird_peer_version` and held, so neither a run nor unattended-upgrades moves it;
  bumping that variable is the (deliberate) upgrade, which restarts the client. The service
  is started and enabled but never restarted. A connected client
  is left alone: no `netbird up`, `down` or re-enrolment, and Vault is not read. Only a
  client that is not logged in or whose login expired (status `NeedsLogin`) is enrolled, with `setup_key` from
  Vault `kv/homelab/netbird/netbird`. The run stops with instructions when that key is
  missing. Any other state is reported and left alone. At the end of the play the run
  checks the client is still connected. Routes, groups and ACLs stay in the NetBird
  dashboard.
- `redis`: the Ubuntu package with its default config (localhost only). A hand edit to
  `redis.conf` is reported, not reverted.
- `ntfy`: compose project `~/ntfy` on port 8081, through `compose_project`. Users and
  access rules are in its auth database (app data, not templated). Anonymous access is
  denied.
- `pulse`: a checkout of the public `github.com/memetics19/pulse` at the commit in
  `pulse_version`, run with the repository's own `deploy/docker-compose.prod.yml` (Pulse,
  Caddy on port 80, and a one-shot docs builder).
  - The image is built only when `pulse:latest` is not the image tagged
    `git-<commit>`. That happens after a new `pulse_version` or a hand build. The whole
    project then comes up with `--build`. A Pulse container on another image than that
    (for example after an interrupted build) is brought up on its own.
  - The box was adopted once with `-e pulse_adopt_existing=true` (tag the existing image
    instead of rebuilding). Don't pass it otherwise.
  - Caddy and the docs builder are compared by config hash. Caddy is restarted when its
    Caddyfile is newer than the container.
  - `.env` is rendered from Vault (`docs/secrets.md`), mode 600.
  - Don't run a plain `docker compose up` for this project: compose recreates the
    locally built Pulse container every time.
- No PHP: `php*`, `composer` and `jsonlint` are kept absent (purged if they come back;
  `guest_base_absent_packages` in `inventory/host_vars/netbird.yml`, tag
  `packages_absent`). They were removed by hand on 2026-10-21 (php2shell,
  CVE-2026-109618/109619). No autoremove.

## apps (Pi-hole)

`apps` is one small VM (1 vCPU, 1.5 GB) for always-on services: Pi-hole, the service
gateway, Homepage and Vaultwarden. It has two NICs on `vmbr0`, both set by cloud-init
(`terraform/vm_apps.tf`): a lab address with the default route, and a home-network address
(`site.hosts.apps.home_ip`) with no gateway, so home devices reach Pi-hole on their own
subnet. Each NIC answers ARP only for its own address.

`make vm HOST=apps` runs the `pihole` role, compose project `/opt/pihole`:

- Pi-hole (pinned tag and digest) publishes DNS (53) on those two addresses only. Its web
  UI is not published; it is reached through the service gateway as
  `https://dns.<gateway domain>` (below). It is not a DHCP server.
- Its only upstream is Unbound, at a fixed address on the project's own Docker network
  (`site.hosts.apps.dns_subnet` / `dns_unbound_ip`, never published). Unbound resolves
  from the root servers and validates DNSSEC. Either container can restart on its own
  (crash, memory cap, `docker restart`, daemon restart) and resolution comes back without
  a run. Unbound has a healthcheck.
- Per-client rate limit: 1000 queries per 60 seconds.
- Local records come from `site.dns.local_records` in Vault. An entry with `name` is
  served as `<name>.lan.<domain>`; the `lan` sub-zone keeps it from shadowing a public
  hostname. An entry with `fqdn` is served under exactly that name, for split horizon: a
  public hostname (Vaultwarden's, the self-hosted NetBird server's) answered at home with
  a home-reachable address. The address is `ref` (a path into the site dict) or `ip`.
  `tests/test_pihole_records.sh` covers the rules. The records (these and the gateway's
  names) are applied to the running Pi-hole live (`pihole-FTL --config dns.hosts`), only
  when they differ, so a change never restarts Pi-hole or interrupts DNS.
- Block lists (`pihole_blocklists`): StevenBlack plus a few lists from firebog and
  URLhaus. A change runs a gravity update. Lists added in the web UI are left alone.
- Web UI: `https://dns.<gateway domain>/admin/`, password `web_password` from Vault
  `kv/homelab/apps/pihole`. Settings passed by the role are read-only in the UI. Local DNS
  records come from Vault: one added in the UI is removed on the next run.

Host firewall (`host_firewall` role, ufw): inbound denied by default; SSH (22), DNS (53
tcp/udp) and the gateway (80, 443) are allowed, each bound to its NIC and address. A firewall
change is applied with a timed rollback: ufw disables itself after 3 minutes unless a
fresh SSH connection and DNS and HTTP checks from the controller succeed first.

ufw does **not** filter ports that Docker publishes: they are forwarded to the container
(FORWARD chain, Docker's chains first) and never reach ufw's input rules. For those ports
the `ip:port` binding in the compose file is the boundary. Bind every published port to
specific addresses, never `0.0.0.0`; Caddy's 80 and 443 are bound that way.

### Service gateway (private)

Every web UI in the lab has a name, `https://<name>.<gateway domain>`, served by Caddy on
the `apps` VM (`caddy` role, compose project `/opt/caddy`) with a publicly trusted
certificate. The gateway domain is `<subdomain>.<domain>` with `site.gateway.subdomain`
from Vault (`internal` here, so `https://pve.internal.<domain>`), or `<domain>` itself when
that key is empty or absent. It is built in one place,
`ansible/inventory/group_vars/all/gateway.yml` (`gateway_domain`), which the caddy,
pihole and homepage roles use; `site.domain` itself (public tunnel names) is unchanged.

- **Private only.** The names exist only in Pi-hole: each one is a local record pointing at
  the `apps` home address. They are reachable only on the home or lab network, or over the
  VPN (NetBird, using Pi-hole as its nameserver; the gateway names point at the `apps`
  home address, so that network, or that one address, must be a route the peers use). Nothing is added to public DNS, no
  Cloudflare tunnel or router port forward points at the gateway, and Caddy is published
  only on the `apps` lab and home addresses.
- **One wildcard certificate**, `*.<gateway domain>`, from Let's Encrypt by the DNS-01 challenge:
  Caddy creates a `_acme-challenge` TXT record through the Cloudflare API, and removes it
  once the certificate is issued. Certificate Transparency logs therefore show only the
  wildcard, never the individual names. The API token (`cloudflare_dns_token` in Vault
  `kv/homelab/apps/caddy`) may only edit DNS in that zone; it reaches Caddy through a 0600
  env file.
- **One list drives both sides**: `site.services` in Vault (structure in
  `site/site.example.yml`, fields in `ansible/roles/caddy/defaults/main.yml`): name,
  upstream (`host`, a path into the site dict, or `container`), port, scheme, and per
  service: self-signed upstream, own CA (Vault's), websockets, long streams (TV), the
  upstream's Host header. Adding a service is one entry there and `make vm HOST=apps`.
  `tests/test_gateway.sh` covers the rules.
- Under the private subdomain no public name is shadowed: `frigate.<domain>` and
  `ntfy.<domain>` (Cloudflare tunnel names) resolve to their tunnels as everywhere else,
  and the local path is `frigate.<gateway domain>`. (Without a subdomain the gateway names
  would answer those public names at home.)
- HTTP redirects to HTTPS. Names not in the list get the connection closed. Only HTTP/1.1
  and HTTP/2 (no UDP published).
- The image is Caddy with the `caddy-dns/cloudflare` module, built by xcaddy from pinned
  versions and base-image digests (`caddy_*` in the role defaults). It is built on
  `ragnarok`, not on `apps` (1.5 GB, no swap: a Go build of Caddy needs more than it has
  free), then copied through the controller and loaded; the tag includes a hash of the
  Dockerfile, so a version change builds a new one. Memory cap 128 MB.
- Apps that should have their own login: the gateway does not add authentication. Turn
  it on in each app (for qBittorrent: set a password and remove the "bypass
  authentication for clients in whitelisted IP subnets" entry), because every client
  reaches it through the gateway's address.

Rate limit caveat: the limit (1000 queries per 60 s) counts per client address. Hand
Pi-hole out to devices directly (router DHCP, below). If the router is instead set up to
forward its own DNS to Pi-hole, every device appears as the router and shares one limit;
NetBird clients behind the masquerading routing peer likewise share the `netbird` VM's
address. Raise `pihole_rate_limit_count` if that is the setup.

Hand steps on the home router (not managed here):

1. Reserve `site.hosts.apps.home_ip` for `site.hosts.apps.home_mac` (the `apps` VM's home NIC,
   Proxmox `net1`, pinned by Terraform) in the router's DHCP.
2. In the router's DHCP settings, hand out that address as the primary DNS server and the
   router itself as the secondary. Devices pick it up when they renew their lease (or
   reconnect to Wi-Fi). On a Mac, `scutil --dns` then lists Pi-hole first.

Hand step in NetBird (dashboard, not managed here), for each network: the NetBird cloud
network now, and the self-hosted one once it exists.

1. DNS > Nameservers > Add nameserver: custom, IP = the `apps` lab address, port 53, UDP.
   The lab network must be a route the peers use (the `netbird` routing peer).
2. Distribution groups: the peer groups that should use it (for example All).
3. Either leave match domains empty (all queries go to Pi-hole, so remote devices get
   filtering too), or set match domains `lan.<domain>` and `<gateway domain>` for local
   names and the gateway's names only. Leave
   "Enabled" on and save. Peers pick it up within a minute; check with `netbird status -d`.

### Homepage dashboard (private)

`https://home.<gateway domain>` (the `home` entry of `site.services`) is a
[Homepage](https://gethomepage.dev) dashboard on `apps` (`homepage` role, compose project
`/opt/homepage`) with a link and, where it has one, a live widget for every enabled
gateway service.

- **Generated from `site.services`.** Groups: Infrastructure (pve, ceph, vault, dns,
  idrac), Media (sonarr, radarr, prowlarr, jackett, qbit, files, tv, threadfin), Home
  (frigate, gotify, ntfy, pulse), Security (pass; later netbird), later Monitoring (grafana);
  disabled entries are left out. Title, group, icon, description and widget per name come
  from `homepage_catalog` in the role defaults; an entry in `site.services` may override
  them with the same optional fields (`widget: none` turns a widget off). The files hold
  no secret: widget keys are `{{HOMEPAGE_VAR_*}}` placeholders that Homepage fills from
  `/opt/homepage/homepage.env` (mode 600, values from Vault). `tests/test_homepage.sh`
  covers the rules.
- **Widgets:** Proxmox (read-only token), Ceph (health, OSDs, space, from the Proxmox
  API with the same token: Homepage has no Ceph widget and the Ceph dashboard API needs a
  session login), Pi-hole (an application password, not the web password), Sonarr, Radarr,
  Prowlarr (their API keys), qBittorrent (no login), Frigate (a viewer login) and the
  container status of `apps` services that are containers (Pi-hole). Each run checks
  every widget through Homepage's own API; a widget with an error is a warning that names
  it (its app is on another VM, and the gateway and firewall still run after it), and
  `ARGS="-e homepage_strict_widgets=true"` makes it fail.
- **Credentials** (docs/secrets.md), each made by the role that owns the app and checked on
  every run: `make host ARGS="--tags homepage"` (Proxmox user `homepage@pve`, no password,
  and its privilege-separated token, both PVEAuditor), `make vm HOST=ragnarok ARGS="--tags
  homepage"` (API keys read from the apps' `config.xml`; nothing on ragnarok changes),
  `make vm HOST=frigate ARGS="--tags homepage"` (Frigate user `homepage`, role viewer) and
  `make vm HOST=apps` (Pi-hole application password, set live). On a new site run those
  before `make vm HOST=apps`.
- **Hardening:** pinned image (tag and digest); no published port (Caddy reaches it on
  the project network `homepage_web`); only `home.<gateway domain>` is an allowed Host; runs as its
  own uid with a read-only config directory; memory cap 192 MB. Container status goes
  through a Docker socket proxy (pinned) on an internal network only Homepage shares,
  whose rules allow only `GET /containers/json` and `GET /containers/<id>/stats`: no
  inspect (container environments hold secrets), logs, exec or writes. Containers on
  other VMs show no status: a socket proxy there would listen on the lab network, where
  Docker-published ports bypass ufw.
- **Look:** dark slate theme, blurred cards, clean header, status dots, no version
  footer; Infrastructure and Media in 3 columns, the other groups in 2; a date and time
  widget (no search widget: it would send what is typed to an internet search engine).
  Weather (Open-Meteo) appears only when `site.homepage.weather` has `latitude` and
  `longitude`. An optional background picture is a file on the controller outside the
  repo, `~/homelab-assets/homepage-bg.jpg` (`homepage_background_src`); when it exists the
  run copies it to `/opt/homepage/images` (served as `/images/`, Homepage restarts once)
  and uses it with blur, saturation, brightness and opacity filters.
- Homepage has no login of its own here; like the other gateway names it is reachable
  only from the home and lab networks and the VPN.

### Vaultwarden (private)

`https://pass.<gateway domain>` (the `pass` entry of `site.services`) is
[Vaultwarden](https://github.com/dani-garcia/vaultwarden), a Bitwarden-compatible password
manager, on `apps` (`vaultwarden` role, compose project `/opt/vaultwarden`, data in
`/opt/vaultwarden/data`). Like the other gateway names it exists only in Pi-hole and is
reachable only from the home and lab networks and the VPN. Bitwarden apps and browser
extensions use it as a self-hosted server URL.

- **Container:** `vaultwarden/server` pinned by tag and digest; no published port (Caddy
  reaches it on the project network `vaultwarden_web`); runs as its own uid (10004) on
  port 8080 with a read-only root filesystem, no capabilities and a 128 MB memory cap.
  Websocket notifications (`/notifications/hub`) go through the gateway on the same name.
- **Settings:** `DOMAIN` is the gateway name; sign-ups are closed (`SIGNUPS_ALLOWED=false`),
  invitations are on, password hints are never shown. **Don't save settings on the admin
  page:** they go to `data/config.json`, which overrides the role's environment. Each run
  lists (by name) the keys there that shadow a role setting and stops before touching the
  container when one weakens it (open sign-ups, email verification or email two-step login
  off while SMTP is on, hints shown, no admin token, another domain, fewer iterations, or a
  pinned `admin_token`): `data/config.json (saved from the admin page) overrides <keys>;
  open /admin → Reset defaults, then rerun`. The role never deletes or rewrites that file.
- The run's admin-login check counts against Vaultwarden's admin rate limit (3 tries per
  5 minutes per address); several runs within 5 minutes can fail with `admin=429`: wait
  and rerun.
- **Mail (SMTP) is managed by code**, from `kv/homelab/apps/vaultwarden`: the pair
  `smtp_username` + `smtp_password` turns it on (with it, invitations are mailed and
  `SIGNUPS_VERIFY` is on); `smtp_host`, `smtp_port`, `smtp_security` (starttls, force_tls,
  off) and `smtp_from` are optional (defaults: `smtp.gmail.com`, 587, starttls, the
  username). Without the pair there is no SMTP; only one of the two stops the run.
  - Gmail: `smtp_username` = the Gmail address, `smtp_password` = a Google App Password
    (account with 2-step verification); nothing else needed.
  - Resend: `smtp_host=smtp.resend.com`, `smtp_username=resend`, `smtp_password` = the API
    key, `smtp_from` = an address on the verified domain.
  Store each value from stdin, e.g. `vault kv patch -mount=kv homelab/apps/vaultwarden
  smtp_password=-`, then `make vm HOST=apps`.
- **Two-step login.** With SMTP, every account registered from an invitation gets email
  two-step login automatically (`EMAIL_2FA_ENFORCE_ON_VERIFIED_INVITE`; codes valid 10
  minutes, 3 tries). That is the only factor the server enforces. Add an authenticator app
  (TOTP) or a passkey as your main second factor and save the recovery code (Settings →
  Security → Two-step login). If you create an organization, turn on its "Require
  two-step login" policy. `REQUIRE_DEVICE_EMAIL=true` (a mail on every new-device login)
  is left off on purpose: with it every login fails while mail cannot be sent, which can
  lock you out of your passwords; add it to `vaultwarden_settings` if you want it.
- **Admin token:** generated into Vault (`kv/homelab/apps/vaultwarden` `admin_token`).
  Vaultwarden gets only its Argon2id hash (`admin_token_hash`, in `/opt/vaultwarden/
  vaultwarden.env`, mode 600). Each run checks that the hash belongs to the token, the
  admin page accepts the token, `/alive` answers and an uninvited email cannot sign up.
  To change the token, write a new `admin_token` to Vault and rerun `make vm HOST=apps`.

**Creating your account** (once):

1. Copy the admin token to the clipboard:
   `source scripts/env.sh && vault kv get -field=admin_token -mount=kv homelab/apps/vaultwarden | pbcopy`
2. Open `https://pass.<gateway domain>/admin`, paste the token, then **Users → Invite
   User** with your email address.
3. With SMTP: open the invitation mail and follow its link, then create the account with
   that address. Without SMTP: open `https://pass.<gateway domain>/`, choose **Create
   account** with that address (an invited address registers directly).
4. Set a strong master password: it cannot be recovered (Vaultwarden only stores a hash).
5. On the admin page, **Log out**; clear the clipboard.

**Backups.** A systemd timer on `apps` (`vaultwarden-backup.timer`, nightly around 03:30)
runs `/usr/local/sbin/vaultwarden-backup` as the Vaultwarden user:

1. an online SQLite backup of the database (checked with `integrity_check`), plus
   `attachments/`, `sends/`, `rsa_key*` and `config.json`;
2. a tar, encrypted with `age` to the same public key as the Terraform state backups
   (Keychain `backup-age-recipient`): only the operator's identity can read it, and the VM
   holds nothing that can decrypt one;
3. uploaded to the Ceph S3 bucket `vaultwarden-backups` as
   `vaultwarden-YYYYMMDD-HHMMSS.tar.age` (UTC) and checked by size;
4. the newest 14 of those objects are kept; nothing else in the bucket is touched.

The work files (the plaintext copy and the archive) are on tmpfs
(`/run/vaultwarden-backup`, removed when the job ends), never on disk; the job stops if
that has less than twice the data free (`/run` is about 145 MB on `apps`).
Follow-up, not done: object versioning or object lock on the bucket, so that a
compromised `apps` (which owns the bucket) could not delete the backups; today the Mac
copies from `make backup` are the second copy.

The bucket belongs to the RGW user `vaultwarden-backup` (`make ceph`), which may own no
other bucket and cannot read any other; its keys are in Vault
(`kv/homelab/apps/vaultwarden-backup`). `make backup` copies the newest object to
`~/homelab-backups/` (keeps 30). Run a backup by hand with
`sudo systemctl start vaultwarden-backup` on `apps`; see the result with
`journalctl -u vaultwarden-backup`.

**Restore drill:** `make vaultwarden-drill` takes the newest backup (it must be the copy
`make backup` pulled), decrypts it on the Mac straight into a one-time key made on `apps`
(no plaintext on the Mac's disk, the identity never leaves it), restores it into a
temporary container `vaultwarden-restore-drill` (no network, no gateway route, no admin
page; a restored `config.json` is moved aside so it cannot override that), checks that
`/alive` answers, that the user count equals the live one and that every restored user is
live, then removes that container (by its ID) and its directory. A real restore is the same steps into
`/opt/vaultwarden/data` with the `vaultwarden` container stopped.

## IPTV

IPTV setup. The lineup is [`iptv/channels.yml`](iptv/channels.yml), checked by
`tests/test_iptv_lineup.sh`.

`make vm HOST=ragnarok ARGS="--tags iptv"` runs, on `ragnarok`, in `/opt/iptv`:

- Threadfin (port 34400): playlist and guide. Web UI login: user `admin`, password
  `admin_password` in Vault `kv/homelab/ragnarok/threadfin`. The role owns its two sources
  and its settings; sources added by hand in the UI are left alone and not recreated on a
  rebuild.
- Stream helper (port 34401): reads the entire generated Threadfin M3U, streams a selected
  channel on request (streamlink), at most two at once, and serves the web TV page and
  `/guide.json` (now/next). The web page refreshes its channel list from Threadfin every
  minute, so channels enabled in Threadfin's Mapping appear without changing the repo lineup.
- Guide grabber (timer `iptv-epg-grab`, 03:30 and 15:30): writes `iptv-epg`'s `guide.xml`.

Memory caps: 64 + 192 MB, and 40 MB for the grabber while it runs.

`make host-network` forwards ports 34400 and 34401 (nothing else) from the Proxmox host's
home-network address to `ragnarok`, so home Wi-Fi devices (and NetBird clients that route
the home network) can use these URLs; devices on the lab network cannot.

- Web TV page: `http://<proxmox-home-address>:34401/`
- Playlist: `http://<proxmox-home-address>:34400/m3u/threadfin.m3u`
- Guide (XMLTV): `http://<proxmox-home-address>:34400/xmltv/threadfin.xml`

The web TV page reads this Threadfin playlist and shows every channel currently enabled in
Threadfin's Mapping. It refreshes the list once a minute; adding or enabling a channel there
does not require a repo lineup change.

Web TV page (Fire TV, phone, laptop): opens playing the last-watched channel. Left/Right
or FF/REW change channel, OK shows what is on, Up/Down open the channel list, Back closes it.

- On a Vega-OS Fire TV: open Silk → `http://<proxmox-home-address>:34401/`
- Fire OS with sideloading: TiviMate (Add playlist > Enter URL > the playlist URL) or VLC
  for Fire (Browse > New favorite > the playlist URL; no guide).

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

It also makes the S3 users `filestash` (read-only, see ragnarok) and `vaultwarden-backup`
(owner of the bucket `vaultwarden-backups` and of no other; its keys go straight into Vault,
see [Vaultwarden](#vaultwarden-private)).

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
storage backs the disks of `ragnarok` (the media library), `vault` or `apps` (Vaultwarden's
data), errored, or was made with `-target`.
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
- NetBird routes, ACLs, setup keys and nameserver groups
- DHCP reservation for the Proxmox uplink on the home router
- The home router's DHCP: the `apps` home address reservation and the DNS servers it hands
  out (see [apps (Pi-hole)](#apps-pi-hole))
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
- [x] Workload roles for `frigate`, `ragnarok`, `netbird`
- [ ] Rebuild runbook, tested on a second server

## Known issues

- Frigate's camera has not answered since 2026-01-13, so there are no new recordings.
- Frigate's `genai` provider points at an Ollama address that does not answer.
- `ragnarok` `/home` is 98% full

## License

[MIT](LICENSE)
