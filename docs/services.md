# Services

What each host runs and how the roles manage it. Commands to run them are in
[usage.md](usage.md), and the Vault paths in [secrets.md](secrets.md).

Placeholders: `<domain>`, `<gateway-domain>`, `<proxmox-address>` (the host's lab address),
`<proxmox-home-address>`, `<ragnarok-address>`.

All compose projects go through the `compose_project` role. It recreates only the
services whose config changed and never runs `down`. See
[Scoped compose](usage.md#safety-rails).

## frigate

`make vm HOST=frigate ARGS="--tags frigate"` runs the `frigate_stack` role.

The role owns Frigate's `config.yml`, so the next run overwrites edits made in the Frigate
UI. Change `ansible/roles/frigate_stack/templates/config.yml.j2` instead. To try settings
in the UI first, run with `-e frigate_stack_manage_frigate_config=false`, then copy the
result into the template.

A changed compose service is brought up on its own. A changed Frigate, Mosquitto or
frigate-notify config restarts only that container.

The public hostname reaches Frigate through nginx on the VM. Frigate's own login on port
8971 is the access control. The `admin` password is in Vault.

## ragnarok

`make vm HOST=ragnarok` runs four compose projects. None of them may live inside the media
library, and `tests/test_media_untouched.sh` checks that nothing in `ansible/` or
`scripts/` can reach it.

### ARR stack

The `arr_stack` role manages `/home/ubuntu/docker-compose.yaml`: qBittorrent, Prowlarr,
Jackett, FlareSolverr, Radarr and Sonarr. The apps keep their settings and API keys in
`./<app>/config`, which is not templated. The media library appears in the template only
as bind-mount sources.

### Guide server

The `iptv_epg` role runs nginx on port 8899. It serves `/home/ubuntu/iptv-epg/output`,
where the IPTV guide grabber writes `guide.xml`.

### Filestash

A read-only browser for the S3 gateway at `http://<ragnarok-address>:8334/`. It is bound
to the VM's LAN address, with a 256 MB memory cap and no swap.

It runs as its own host user, uid 10001, because the VM's first user owns the media. The
container has a read-only root file system, no capabilities and no-new-privileges. Only
that user can read its state, which holds the S3 keys. The role never changes owners
recursively: after a uid change it stops, and you chown `/opt/filestash/state` by hand
once.

Log in as `admin` with `admin_password` from `kv/homelab/ragnarok/filestash`. The same
password opens `/admin`. The role generates it into Vault on the first run.

`make ceph` creates the S3 user `filestash`. It owns no buckets and cannot create any.
Bucket policies let it list and read `tfstate`. Its keys go into the same Vault path, and
Filestash keeps them on the server side.

Filestash rewrites its `config.json` at start, so the role manages only its own keys in
it. Changes made in the admin console to the login, connections or sharing are
overwritten.

### IPTV

`make vm HOST=ragnarok ARGS="--tags iptv"` runs the `iptv` role in `/opt/iptv`. The
lineup is [`iptv/channels.yml`](../iptv/channels.yml), checked by
`tests/test_iptv_lineup.sh`.

- Threadfin (port 34400) serves the playlist and guide. Log in as `admin` with
  `admin_password` from `kv/homelab/ragnarok/threadfin`. The role owns its two sources and
  its settings. Sources added by hand in the UI are left alone, and a rebuild does not
  recreate them.
- The stream helper (port 34401) streams a channel on request with streamlink, at most two
  at once. It also serves the web TV page and `/guide.json` (now and next).
- The guide grabber (timer `iptv-epg-grab`, 03:30 and 15:30) writes the guide server's
  `guide.xml`.

Memory caps are 64 MB for Threadfin, 192 MB for the stream helper and 40 MB for the
grabber while it runs.

`make host-network` forwards ports 34400 and 34401, and nothing else, from the Proxmox
host's home address to `ragnarok`. Home devices, and NetBird clients that route the home
network, can use these URLs. Devices on the lab network cannot.

- Web TV page: `http://<proxmox-home-address>:34401/`
- Playlist: `http://<proxmox-home-address>:34400/m3u/threadfin.m3u`
- Guide (XMLTV): `http://<proxmox-home-address>:34400/xmltv/threadfin.xml`

The web TV page shows every channel enabled in Threadfin's Mapping and refreshes that list
once a minute, so enabling a channel there needs no change to the repo lineup. It opens on
the last channel watched. Left and Right (or FF and REW) change channel, OK shows what is
on, Up and Down open the channel list, and Back closes it.

On a Vega OS Fire TV, open the web TV page in Silk. On Fire OS with sideloading, add the
playlist URL in TiviMate (Add playlist, Enter URL) or in VLC for Fire (Browse, New
favorite). VLC shows no guide.

## netbird

`make vm HOST=netbird` runs the "Netbird workloads" play. This VM is the emergency VPN
path, so never run it in the same Ansible run as `make host-network`.

### NetBird client

The `netbird_peer` role installs the client from NetBird's apt repository, with the
signing key pinned by checksum. It is the routing peer on NetBird's cloud service.

The package is pinned to `netbird_peer_version` and held, so neither a run nor
unattended-upgrades moves it. Bumping that variable is the upgrade, and it restarts the
client. Otherwise the service is never restarted.

A connected client is left alone: no `netbird up`, no `down`, no re-enrollment, and Vault
is not read. Only a client in state `NeedsLogin` is enrolled, with `setup_key` from
`kv/homelab/netbird/netbird`. The run stops with instructions if that key is missing. Any
other state is reported and left alone. At the end the run checks that the client is
still connected. Routes, groups and ACLs stay in the NetBird dashboard.

### Other services

- `redis`: the Ubuntu package with its default config, localhost only. A hand edit to
  `redis.conf` is reported, not reverted.
- `ntfy`: compose project `~/ntfy` on port 8081. Anonymous access is denied. Users and
  access rules live in its auth database, which is not templated.
- `pulse`: a checkout of [memetics19/pulse](https://github.com/memetics19/pulse) at the
  commit in `pulse_version`, run with the repo's own `deploy/docker-compose.prod.yml`
  (Pulse, Caddy on port 80 and a one-shot docs builder). `.env` is rendered from Vault with
  mode 600.

The Pulse image is built only when `pulse:latest` is not the image tagged for the current
commit, which happens after a new `pulse_version` or a hand build. The whole project then
comes up with `--build`. A Pulse container on some other image, for example after an
interrupted build, is brought up on its own. Caddy and the docs builder are compared by
config hash, and Caddy restarts when its Caddyfile is newer than the container. Don't run
a plain `docker compose up` for this project, because it recreates the locally built
container every time.

The box was adopted once with `-e pulse_adopt_existing=true`, which tags the existing image
instead of rebuilding. Don't pass it otherwise.

PHP is kept off this VM. `php*`, `composer` and `jsonlint` were removed by hand on
2026-10-21 (php2shell, CVE-2026-109618/109619), and the role purges them if they come back.
The list is `guest_base_absent_packages` in `inventory/host_vars/netbird.yml`, tag
`packages_absent`. There is no autoremove.

## apps

`apps` is one small VM (1 vCPU, 1.5 GB) for the always-on services: Pi-hole, the service
gateway and Homepage. Vaultwarden ran here first. It now runs on its own VM in the
[secrets enclave](#secrets-enclave).

It has two NICs on `vmbr0`, both set by cloud-init in `terraform/vm_apps.tf`. One has a lab
address and the default route. The other has a home-network address
(`site.hosts.apps.home_ip`) and no gateway, so home devices reach Pi-hole on their own
subnet. Each NIC answers ARP only for its own address.

### Firewall

The `host_firewall` role sets up ufw. Inbound traffic is denied by default. SSH (22), DNS
(53, TCP and UDP) and the gateway (80, 443) are allowed, each bound to its NIC and
address. A change has a timed rollback: ufw disables itself after 3 minutes unless a fresh
SSH connection and DNS and HTTP checks from the Mac succeed first.

ufw does not filter ports that Docker publishes. Docker forwards them to the container
through its own chains, so they never reach ufw's input rules. For those ports the
`ip:port` binding in the compose file is the boundary. Bind every published port to a
specific address, never `0.0.0.0`, as Caddy's 80 and 443 are.

### Pi-hole

The `pihole` role runs compose project `/opt/pihole`.

Pi-hole publishes DNS on port 53 on the two `apps` addresses only. It is not a DHCP
server. Its web UI is not published either: it is at `https://dns.<gateway-domain>/admin/`
through the gateway, with `web_password` from `kv/homelab/apps/pihole`. Settings the role
passes are read-only in the UI.

Its only upstream is Unbound, at a fixed address on the project's own Docker network
(`site.hosts.apps.dns_subnet` and `dns_unbound_ip`, never published). Unbound resolves
from the root servers and validates DNSSEC, and has a healthcheck. Either container can
restart on its own and resolution comes back without a run.

Each client may send 1000 queries per 60 seconds. The limit counts per client address, so
hand Pi-hole out to devices directly through the router's DHCP. If the router forwards its
own DNS to Pi-hole instead, every device shows up as the router and shares one limit.
NetBird clients behind the routing peer also share the `netbird` VM's address. Raise
`pihole_rate_limit_count` if that is your setup.

Local records come from `site.dns.local_records` in Vault. An entry with `name` is served
as `<name>.lan.<domain>`, and the `lan` sub-zone keeps it from shadowing a public name. An
entry with `fqdn` is served under exactly that name, for split horizon: a public hostname
answered at home with a home address. The address is `ref`, a path into the site dict, or
`ip`. The role applies these records, and the gateway's names, to the running Pi-hole with
`pihole-FTL --config dns.hosts`, only when they differ, so DNS is never interrupted. A
record added in the UI is removed on the next run. `tests/test_pihole_records.sh` covers
the rules.

The block lists are in `pihole_blocklists`: StevenBlack plus a few lists from firebog and
URLhaus. A change runs a gravity update. Lists added in the web UI are left alone.

Pointing the home router and NetBird at Pi-hole are hand steps, in
[setup.md](setup.md#not-managed-here).

### Service gateway

Every web UI in the lab is at `https://<name>.<gateway-domain>`, served by Caddy on `apps`
(`caddy` role, compose project `/opt/caddy`) with a publicly trusted certificate.

The gateway domain is `<subdomain>.<domain>`, with the subdomain from
`site.gateway.subdomain` (for example `internal`), or just `<domain>` when that key is
empty. `ansible/inventory/group_vars/all/gateway.yml` builds it as `gateway_domain` for the
caddy, pihole and homepage roles. `site.domain` itself, used for the public tunnel names,
does not change.

The gateway is private. Its names exist only as Pi-hole records that point at the `apps`
home address, so they work only on the home and lab networks and over NetBird. For NetBird,
that address must be on a route the peers use. Nothing goes into public DNS, no tunnel or
port forward points at the gateway, and Caddy listens only on the two `apps` addresses.
With a subdomain, no public name is shadowed: `frigate.<domain>` still reaches its tunnel,
and the local name is `frigate.<gateway-domain>`.

Caddy gets one wildcard certificate, `*.<gateway-domain>`, from Let's Encrypt through the
DNS-01 challenge. It creates the `_acme-challenge` TXT record through the Cloudflare API
and removes it afterwards, so Certificate Transparency logs show only the wildcard. The API
token is `cloudflare_dns_token` in `kv/homelab/apps/caddy`. It may only edit DNS in that
zone, and it reaches Caddy through a mode 600 env file.

One list drives Caddy, Pi-hole and Homepage: `site.services` in Vault. Each entry has a
name, an upstream (`host`, a path into the site dict, or `container`), a port and a scheme.
Optional fields cover self-signed upstreams, Vault's CA, websockets, long streams and the
upstream Host header. They are documented in `ansible/roles/caddy/defaults/main.yml`, and
`tests/test_gateway.sh` covers the rules. See
[Adding a service](usage.md#adding-a-service-behind-the-gateway).

HTTP redirects to HTTPS. Names not in the list get the connection closed. Only HTTP/1.1
and HTTP/2 are served. No UDP port is published.

The image is Caddy with the `caddy-dns/cloudflare` module, built by xcaddy from the pinned
`caddy_*` versions and base-image digests. It is built on `ragnarok`, because a Go build
of Caddy needs more memory than `apps` has free, then copied through the Mac and loaded on
`apps`. The tag includes a hash of the Dockerfile, so a version change builds a new image.
The memory cap is 128 MB.

The gateway adds no authentication. Turn on each app's own login. Every client reaches the
app from the gateway's address, so for qBittorrent, set a password and remove the "bypass
authentication for clients in whitelisted IP subnets" entry.

### Homepage

`https://home.<gateway-domain>` is a [Homepage](https://gethomepage.dev) dashboard (the
`home` entry of `site.services`, `homepage` role, compose project `/opt/homepage`). It has
a link, and a live widget where one exists, for every enabled gateway service. It has no
login, like the other gateway names.

The config is generated from `site.services`. Title, group, icon, description and widget
for each name come from `homepage_catalog` in the role defaults, and an entry in
`site.services` can override any of them (`widget: none` turns a widget off). A name not
in the catalog goes to group `Other` with no widget. Disabled entries are left out. The
groups are Infrastructure, Media, Home, Security and, later, Monitoring.
`tests/test_homepage.sh` covers the rules.

The config files hold no secrets. Widget keys are `{{HOMEPAGE_VAR_*}}` placeholders that
Homepage fills from `/opt/homepage/homepage.env` (mode 600, values from Vault).

The widgets are Proxmox, Ceph, Pi-hole, Sonarr, Radarr, Prowlarr, qBittorrent, Frigate and
the container status of Pi-hole. Homepage has no Ceph widget, so the Ceph one reads the
Proxmox API with the same read-only token. Pi-hole uses an application password, not the
web password. qBittorrent needs no login. Each credential is made by the role that owns
the app:

- `make host ARGS="--tags homepage"`: Proxmox user `homepage@pve`, with no password, and its
  privilege-separated token, both PVEAuditor
- `make vm HOST=ragnarok ARGS="--tags homepage"`: the ARR API keys, read from the apps'
  `config.xml` without changing anything on `ragnarok`
- `make vm HOST=frigate ARGS="--tags homepage"`: Frigate user `homepage`, role viewer
- `make vm HOST=apps`: the Pi-hole application password

On a new site, run the first three before `make vm HOST=apps`. Each run checks every
widget through Homepage's API. A widget with an error is a warning, because its app may be
on another VM. `ARGS="-e homepage_strict_widgets=true"` makes it fail the run instead.

Hardening: the image is pinned by tag and digest. No port is published. Caddy reaches it
on the project network `homepage_web`. Only `home.<gateway-domain>` is an allowed Host. It
runs as its own uid with a read-only config directory and a 192 MB memory cap. Container
status goes through a pinned Docker socket proxy on an internal network that only Homepage
shares. The proxy allows only `GET /containers/json` and `GET /containers/<id>/stats`, with
no inspect (container environments hold secrets), logs, exec or writes. Containers on other
VMs show no status, because a socket proxy there would listen on the lab network, where
Docker-published ports bypass ufw.

Look: a dark slate theme, blurred cards, status dots and no version footer.
Infrastructure and Media use 3 columns, the other groups 2. There is a date and time widget
but no search widget, which would send what you type to a search engine. Weather
(Open-Meteo) shows only when `site.homepage.weather` has `latitude` and `longitude`. For a
background picture, put `~/homelab-assets/homepage-bg.jpg` on the Mac
(`homepage_background_src`). The run then copies it to `/opt/homepage/images`, restarts
Homepage once and shows it with blur, saturation, brightness and opacity filters.

### Vaultwarden

`https://pass.<gateway-domain>` is
[Vaultwarden](https://github.com/dani-garcia/vaultwarden), a Bitwarden-compatible password
manager (the `pass` entry of `site.services`, `vaultwarden` role, compose project
`/opt/vaultwarden`, data in `/opt/vaultwarden/data`). Bitwarden apps and browser
extensions use it as a self-hosted server URL.

It runs on the `vaultwarden` VM in the [secrets enclave](#secrets-enclave)
(`make vm HOST=vaultwarden`). The container is `vaultwarden/server`, pinned by tag and
digest. The VM has no registry access, so the image is pulled by digest on `ragnarok`,
exported, copied through the Mac and loaded by tag (never pulled there). The run checks
that its layer list equals the pulled image's. Docker comes from Ubuntu's archive
(`docker.io`, `docker-compose-v2`) through the apt cache. The port is published on the VM's
enclave address only, where the enclave firewall lets only Caddy (`apps`) in. It runs as
uid 10004 on port 8080, with a read-only root file system, no capabilities and a 128 MB
memory cap. Websocket notifications (`/notifications/hub`) go through the gateway on the
same name. On a VM with no database the role refuses to start an empty Vaultwarden.
The flag `-e vaultwarden_allow_empty_start=true` is for a deliberate fresh install.

The Vault paths keep the name of the VM it was first set up on: `kv/homelab/apps/vaultwarden`
and `kv/homelab/apps/vaultwarden-backup`.

#### The move from `apps` (2026-10-21)

The `apps` copy's backup job ran one last time and was checked. Then its container was
stopped, the database was copied with `sqlite3 .backup` (plus `rsa_key.pem`), the new VM
started on that copy, and the `pass` entry was switched to `host: hosts.vaultwarden.ip`.
The users and ciphers rows, and digests of both tables, were equal on both sides. After a
day on the new VM (a fresh backup decrypted, the drill passed, the counts unchanged), the old
copy on `apps` was removed: its container, `/opt/vaultwarden` (data included), its backup
units and `/etc/vaultwarden-backup` (the S3 keys), and Caddy left the network
`vaultwarden_web` (one recreate), which was then removed.

`DOMAIN` is the gateway name. Sign-ups are closed (`SIGNUPS_ALLOWED=false`), invitations
are on, and password hints are never shown.

Don't save settings on the admin page. They go to `data/config.json`, which overrides the
role's environment. Each run lists the keys there that shadow a role setting. If one
weakens it (open sign-ups, email verification or email two-step login off while SMTP is
on, hints shown, no admin token, another domain, fewer iterations, or a pinned
`admin_token`), the run stops before it touches the container. The fix is in
[Troubleshooting](usage.md#troubleshooting). The role never deletes or rewrites that file.

The admin token is generated into `kv/homelab/apps/vaultwarden` as `admin_token`.
Vaultwarden gets only its Argon2id hash, `admin_token_hash`, in
`/opt/vaultwarden/vaultwarden.env` (mode 600). Each run checks that the hash matches the
token, the admin page accepts the token, `/alive` answers and an uninvited address cannot
sign up. To change the token, write a new `admin_token` to Vault and rerun
`make vm HOST=vaultwarden`.

#### Mail

SMTP is set from `kv/homelab/apps/vaultwarden`. The pair `smtp_username` and
`smtp_password` turns it on. With only one of the two, the run stops. With SMTP,
invitations are mailed and `SIGNUPS_VERIFY` is on. `smtp_host`, `smtp_port`,
`smtp_security` (starttls, force_tls or off) and `smtp_from` are optional. They default to
`smtp.gmail.com`, 587, starttls and the username.

- Gmail: `smtp_username` is the Gmail address and `smtp_password` a Google App Password,
  which needs 2-step verification on the account.
- Another relay: set `smtp_host`, `smtp_username`, `smtp_password` and an address on its
  verified domain as `smtp_from`.

Write each value from stdin (see [Secrets in Vault](usage.md#secrets-in-vault)), then run
`make vm HOST=vaultwarden`. When `smtp_host` or `smtp_port` changed, also run
`make enclave ARGS="--tags firewall"`: the enclave firewall's mail hole (the relay set and
its port) is built from them.

#### Two-step login

With SMTP, every account registered from an invitation gets email two-step login
(`EMAIL_2FA_ENFORCE_ON_VERIFIED_INVITE`). Codes last 10 minutes, 3 tries. That is the only
factor the server enforces. Add an authenticator app or a passkey as your main second
factor and save the recovery code (Settings, Security, Two-step login). If you create an
organization, turn on its "Require two-step login" policy.

`REQUIRE_DEVICE_EMAIL=true`, a mail on every new-device login, is off on purpose: with it,
every login fails while mail cannot be sent, and you can be locked out of your passwords.
Add it to `vaultwarden_settings` if you want it.

#### Creating your account

1. Copy the admin token to the clipboard:

   ```sh
   source scripts/env.sh
   vault kv get -field=admin_token -mount=kv homelab/apps/vaultwarden | pbcopy
   ```

2. Open `https://pass.<gateway-domain>/admin`, paste the token, and go to Users, Invite
   User with your e-mail address.
3. With SMTP, follow the link in the invitation mail and create the account with that
   address. Without SMTP, open `https://pass.<gateway-domain>/` and choose Create account
   with that address. An invited address can register even though sign-ups are closed.
4. Pick a strong master password. It cannot be recovered.
5. Log out of the admin page and clear the clipboard.

#### Backups

`vaultwarden-backup.timer` runs `/usr/local/sbin/vaultwarden-backup` as the Vaultwarden
user every night at about 03:30. The job:

1. takes an online SQLite backup of the database, checked with `integrity_check`, plus
   `attachments/`, `sends/`, `rsa_key*` and `config.json`
2. tars it and encrypts it with `age` to Keychain `backup-age-recipient`, the same key as
   the Terraform state backups, so the VM holds nothing that can decrypt it
3. uploads it to the Ceph bucket `vaultwarden-backups` as
   `vaultwarden-YYYYMMDD-HHMMSS.tar.age` (UTC) and checks the size
4. keeps the newest 14 of its objects and touches nothing else in the bucket

The plaintext copy and the archive live on tmpfs in `/run/vaultwarden-backup` and are
removed when the job ends. The job stops if there is less than twice the data free there.
`/run` is about 50 MB on the 512 MB `vaultwarden` VM. The data is well under 1 MB.

The bucket belongs to the S3 user `vaultwarden-backup`, made by `make ceph`. It may own no
other bucket and cannot read any other. Its keys are in
`kv/homelab/apps/vaultwarden-backup`. `make backup` copies the newest object to the Mac.

Not done yet: object versioning or object lock on the bucket. The backup user owns the
bucket, so a compromised `vaultwarden` VM could delete the backups. Today the copies on the Mac are the second
copy.

`make vaultwarden-drill` tests a restore. It takes the newest backup, which must be the
copy `make backup` pulled, and decrypts it on the Mac straight into a one-time key made on
the `vaultwarden` VM, so no plaintext touches the Mac's disk and the identity never leaves it. It
restores into a temporary container `vaultwarden-restore-drill` with no network, no
gateway route and no admin page, and moves any restored `config.json` aside. It checks
that `/alive` answers, that the user count equals the live one and that every restored
user is live, then removes the container and its directory. The real restore is in
[setup.md](setup.md#rebuilding-on-a-new-box).

## Secrets enclave

Vault and Vaultwarden live on their own network, the SDN vnet `secrets` (simple zone
`enclave`, `terraform/sdn.tf`). It is a bridge on the Proxmox host with no physical port, so
none of its frames reach the switch or the home network. The host is its only router
(`site.sdn.enclave.gateway` is the host's address on it) and does no NAT for it, except
the one mail flow below. The vnet isolates its ports: the two VMs reach the gateway, not
each other. `make enclave` (role `pve_enclave`) sets up the host side.

### Firewall: routed segments

The host's nftables table `inet segments` (role `pve_segments`) is built from data: a list
of segments in `inventory/group_vars/proxmox.yml` (`pve_segments_list`) and named sets.
Each segment has:

- a name, its interface, subnet and gateway.
- a `nat` flag (masquerade the whole segment).
- three rule lists: `ingress` (new connections into it), `egress` (out of it) and `host`
  (to the Proxmox host).
- `nat_out`, for single flows of a segment without NAT that leave source-NATed.

A rule is saddr/daddr (an address, a list or `@set`), proto and dport. A rule whose address
is empty (a host not in the site dict yet) is left out.

The forward chain:

1. accepts established traffic.
2. drops a segment's addresses arriving on any other interface.
3. jumps to `<name>_out`, where allowed connections go on.
4. jumps to `<name>_in`, which accepts.

So a connection between two segments passes both. The input chain works the same way with
`<name>_host`, and each gateway address answers only on its own interface. Every segment
chain ends in a counted drop.

Sets are static, CIDR intervals, or fed from DNS by a timer (`segments-set-refresh@<set>`).
A DNS-fed set takes only public unicast A records, keeps each for a while, and a failed,
empty or oversized lookup changes nothing.

The ruleset is checked with `nft -c`, shown with addresses masked, and applied under a
120 s rollback. It loads at boot before the network and the guests
(`segments-firewall.service`). The lab SNAT, the IPTV DNAT and NetBird's rules are separate
and unchanged. The enclave is the first segment. The VLANs are added as more entries.

The enclave's rules (`pve_enclave_segment` in `ansible/roles/pve_enclave/defaults/main.yml`):

| Direction | Allowed |
|---|---|
| Into the enclave | Caddy (the `apps` lab address) to Vault 8200 and Vaultwarden 8080. On `apps` only Caddy's own network may use it, see below. Operators to Vault 8200, and SSH and ping on both VMs. Operators are the operator's own devices only (`inventory/group_vars/all/enclave.yml`): the Mac's LAN /32s (`site.admin_sources`) and the operator's NetBird peers (`site.admin_vpn_sources`), or only the NetBird peers with `site.enclave.vpn_only: true`. Each is a single address (/32). Wider prefixes are refused. Every address of every host in the site dict (VMs, their lab and home addresses, the Proxmox host's) is dropped before those rules, so no VM is an operator, monitoring included (no scrape rules). |
| Out of the enclave | Vaultwarden only: DNS to Pi-hole, and the SMTP port to the set `enclave_smtp_relay`, source-NATed to the host's home address. That is the only translated flow. Vault: nothing. |
| To the host | NTP and the apt cache on the gateway address, and ping. Vaultwarden also reaches the Ceph S3 gateway (backups). |

No VM reaches the enclave apart from that gateway path. The Proxmox host itself is not
filtered on its way in: its own connections (Ansible's SSH through `ProxyJump`, the
operator path) are not forwarded traffic. From the enclave the host offers only NTP, the
apt cache and (Vaultwarden) the Ceph S3 gateway.

On `apps`, Caddy shares its lab address with every other container and the host, so the
Proxmox host cannot tell Caddy's connections apart. `apps` decides it: the nftables table
`inet anvil_gateway_guard` (role `caddy`, `tasks/enclave_guard.yml`, loaded at boot by
`gateway-guard.service` before Docker) lets only Caddy's own network `caddy_gateway` open
connections to Vault's and Vaultwarden's ports. That network is pinned in compose: its
subnet comes from `site.hosts.apps.gateway_subnet` and its bridge is always `br-caddygw`
(`tasks/gateway_net.yml` checks the subnet overlaps nothing and replaces a network that
differs, recreating Caddy once), Caddy is its only member and its default route
(`gw_priority`), and the guard matches both the bridge and the subnet, so no other or
recreated network can inherit the admitted addresses. Replies (Pi-hole's DNS answers to
Vaultwarden) pass as established. The guard drops everything else from that VM to the
enclave (other containers, the host). It is not required by Docker, so a failed guard never
keeps Pi-hole down. In Caddy, the `pass` and `vault` routes (`caddy_admin_only_routes`) answer
only the same operator addresses, matched on the real client address. Any other client
gets 403.

NetBird: both routing peers for the lab's /16, the Proxmox host (which masquerades only
after its forward chain) and the `netbird` VM (which does not masquerade), keep a peer's
own address up to the enclave firewall, so the operator's peers are listed by address and
no VM is admitted. See [NetBird](setup.md#netbird) for the routes and access policy that
make this reliable.

The mail hole: `smtp_host` and `smtp_port` come from `kv/homelab/apps/vaultwarden`. The
timer resolves the host through Pi-hole, the resolver Vaultwarden uses, every 10 minutes,
and keeps each address for 24 h. The set holds at most 64. An answer that would not fit
next to the kept ones replaces the set (never more than 64, nothing but the answer). No
expected-range list (`refresh.expect`) is set for it. The relay answers from a large shared
cloud address pool, so a published range would not narrow anything. Without an SMTP login in Vault the set stays empty. Not done: Vaultwarden may ask Pi-hole
for any name, not only the relay's (a narrow DNS channel out through Pi-hole's own
recursion). Closing it needs a Pi-hole client group for Vaultwarden that allows only the
relay's name, or a resolver of its own. Neither is managed here yet.

The lab SNAT rule on the host also matches lab-to-enclave traffic, so the enclave VMs see
lab clients (Caddy included) as the host's home address. The firewall decides on the real
source, before that translation.

### Turning on VPN-only

`site.enclave.vpn_only: true` admits only the NetBird peers in `site.admin_vpn_sources`, at
the enclave firewall and in Caddy's `pass` and `vault` routes. The Mac's LAN /32s no longer
count. A LAN address proves nothing on this network (the lab and home share one L2 segment:
any VM or home device can take over the Mac's addresses, ARP included). In this order:

1. Do the NetBird dashboard steps ([setup.md](setup.md#netbird)): the `operator` group with
   only your devices, the access policy without the runner peers, the enclave network routed
   through the Proxmox host, and the `apps` home address as a /32 route through the Proxmox
   host with masquerade off.
2. Clear the Mac's static enclave route, so the enclave is reached over NetBird only:
   `sudo networksetup -setadditionalroutes "Wi-Fi"` with no further arguments.
3. At home with Wi-Fi on and NetBird up, check that both addresses go through the NetBird
   interface (a `utun` device), not Wi-Fi:

   ```sh
   route -n get <vault-enclave-address>
   route -n get <apps-home-address>
   ```

   It is unverified whether NetBird installs a /32 inside the Mac's own home subnet. The
   `apps` home address is in that subnet, so the Wi-Fi route may win. Test this at home
   before the switch. If either answer names the Wi-Fi interface, stop here.
4. Over NetBird, check that the Mac reaches `https://pass.<gateway-domain>` (200, not 403)
   and Vault (`vault status` with `vault-ip`, or `HOMELAB_VAULT_ADDR`). Check it at home and
   also away from home or with Wi-Fi off.
5. Set `enclave: {vpn_only: true}` in `kv/homelab/site` with a CAS write, as in
   [Adding a service behind the gateway](usage.md#adding-a-service-behind-the-gateway).
6. `make enclave ARGS="--tags firewall"` and `make vm HOST=apps ARGS="--tags caddy"`.

Rollback. This works while the Mac is locked out:

1. From the Proxmox host's console or SSH, admit the Mac's LAN address again. This lasts
   until the next firewall apply:

   ```sh
   nft add element inet segments admin { <mac-lan-address>/32 }
   ```

   Then put the Mac's static enclave route back
   ([setup.md](setup.md#the-macs-route-to-the-secrets-enclave) has the command).
2. From the Mac, set `vpn_only: false` in `kv/homelab/site` (CAS write).
3. Rerun the two make commands of step 6. The apply replaces the temporary element with the
   full list.

An SSH tunnel through the Proxmox host also reaches Vault, with no route and no change to
the table. The host's own connections never pass the enclave firewall's forward chain:

```sh
ssh -N -L 8200:<vault-enclave-address>:8200 root@<proxmox-home-address> &
export HOMELAB_VAULT_ADDR=https://127.0.0.1:8200 VAULT_TLS_SERVER_NAME=<vault-enclave-address>
source scripts/env.sh && vault status
```

### Guests didn't start at boot (enclave firewall failed to load)

Symptom: after a reboot no VM runs. `systemctl status pve-guests` shows its `ExecStartPre`
(`nft list table inet segments`) failed, and `systemctl status segments-firewall` shows why
(`nft -f /etc/segments/segments.nft`). This is deliberate: without the table the segments
would be open.

1. Fix the table: read the error (`nft -c -f /etc/segments/segments.nft`), repair the file
   (or copy the newest `/var/backups/pve-network/segments.nft.<epoch>.file` back), then
   `nft -f /etc/segments/segments.nft` and check `nft list table inet segments`. Then run
   `systemctl start segments-set-refresh@enclave_smtp_relay`. The table loads with the
   DNS-fed set empty, and without this the mail relay waits up to 10 minutes for the timer.
2. Start the guests. `pve-guests` refuses manual starts (`RefuseManualStart=yes`, see
   `systemctl cat pve-guests`), so use `pvesh create /nodes/localhost/startall` (all, in
   startup order) or `qm start <vmid>` for one.
3. Rerun `make enclave` so the file, the unit and the check match the repo again.

Never start guests by hand while the table is missing: the enclave would be reachable from
every VM and the home network, and its VMs could reach anything routed. If you must (DNS for
the home), start only `apps` with `qm start`, and fix the table before starting `vault` and
`vaultwarden`.

After a manual start, shutdown is not clean. The failed boot leaves `pve-guests` failed,
and a failed unit has nothing to stop. At the next shutdown or reboot Proxmox's stopall does
not run, so the guests started by hand (`startall` or `qm start`) are hard-stopped. That
risks Vault's Raft store and Vaultwarden's sqlite database. So, after fixing the table,
reboot the host. That boot starts `pve-guests` normally, and its stop runs stopall at the
next shutdown. If guests were started by hand and stay up, run
`pvesh create /nodes/localhost/stopall` before any later shutdown or reboot.

Never `systemctl restart` or `stop` a unit that `pve-guests` is ordered against. Never link
one to it with Requires, RequiredBy, Requisite, BindsTo, PartOf, Conflicts or
PropagatesStopTo: a restart of such a unit stops every guest (it happened once).

### Apt cache and time

`apt-cacher-ng` on the host listens on the gateway address only. It serves the Debian and
Ubuntu archives and nothing else: `ForceManaged`, only those remaps, port 80 upstreams, no
CONNECT tunnels, IPv4 only. The enclave VMs use it as their apt proxy, set by the role
`enclave_guest` and by the cloud-init vendor data `local:snippets/enclave-vendor.yaml` from
the first boot. HTTPS repositories are not reachable, so Docker comes from Ubuntu's archive
and Vault's HashiCorp repository is removed.

The host's chrony answers NTP on the gateway address for the enclave subnet. The VMs use
systemd-timesyncd with that server only.

### Vault on the enclave

- **NICs.** The vault VM's enclave NIC (hot-plugged, MAC `site.hosts.vault.enclave_mac`)
  is its only working one. Its first NIC, on the lab network, is retired
  (`site.hosts.vault.lab_nic_retired: true`, 2026-10-22): its link is down in Proxmox
  (`disconnected`) and the netplan keeps it with no address. `site.hosts.vault.ip` is the
  enclave address. `lab_ip` and `mac` record the old NIC.
- **Netplan.** `guest_base` owns it in enclave mode, under a timed rollback: the enclave NIC
  has the default route and no DNS, and cloud-init no longer writes the network.
- **Listener.** Vault listens on the enclave address only. The `api_addr`, `cluster_addr` and
  the certificate's address are the enclave one.
- **Reaching it.** Ansible connects through the Proxmox host (`group_vars/enclave.yml`).
  From the Mac: through the gateway (`https://vault.<gateway-domain>`, operator addresses
  only), or directly once the Mac has the enclave route and the Keychain `vault-ip` is the
  enclave address ([setup.md](setup.md#not-managed-here)). Until then, for the scripts:

  ```sh
  export HOMELAB_VAULT_ADDR=https://vault.<gateway-domain>
  export HOMELAB_VAULT_CACERT="$(python3 -m certifi)"   # the gateway's certificate is public
  ```

  `make vault-unseal`, `make backup`, the Ansible lookups and `make tf-plan` all work that
  way. Caddy's own trust in Vault always uses Vault's CA file, never `$VAULT_CACERT`.

Vault now reaches nothing but the host's NTP and apt cache: no DNS, no lab host, no
internet. Removing the retired NIC from the VM altogether is a later, separate change
(Terraform `network_device` list). It reorders the NICs, so plan it with care.

The Raft configuration still names the node by its first cluster address. On a single node
that is only a label, because the node elects itself by ID. A second node would need it
fixed first, with a `peers.json` recovery.

**Vault upgrades in the enclave.** There is no HashiCorp repository, so the run stops when
`vault_server_version` is not installed. To upgrade:

1. On the Mac, download the `.deb` from `apt.releases.hashicorp.com` and check it against
   the signed repository index.
2. Copy it to the VM and run `sudo apt install ./vault_<version>_amd64.deb`.
3. Run `make vault` with `vault_server_allow_restart=true`, then unseal.

## Ceph

`make ceph` builds a one-disk Ceph cluster on `pve`: a monitor, a manager, one OSD and pool
size 1. It adds a RADOS Gateway on port 7480 of the host's address, the S3 user
`terraform` and the bucket `tfstate` for Terraform state. It also makes the S3 users
`filestash` (read-only) and `vaultwarden-backup`, whose keys go into Vault.

The OSD disk is the `/dev/disk/by-id/` name in `site.pve.ceph_osd_disk_id`, else in
Keychain `ceph-osd-disk-id`. `-e ceph_osd_device=/dev/disk/by-id/...` overrides both.

The first real run wipes that disk. Before it touches anything, the play refuses a disk
that:

- holds `/` or `/boot/efi`, or that the host boots from (EFI BootCurrent,
  `proxmox-boot-uuids`, grub-pc install devices)
- has a mounted partition, kernel holders or open handles
- is named in a guest config or `storage.cfg`
- is a PV in any non-Ceph volume group
- carries a ZFS pool that is imported, or importable in any state other than `UNAVAIL`

A disk that is already an OSD (the Ceph VG, LVM on the disk and `ceph-volume` agree) is
left alone. If those disagree, the play stops. `make ceph ARGS="--check --diff"` runs the
checks and lists what would run.

The `terraform` user's S3 keys are written to `/root/.ceph-rgw-terraform.json` (mode 600)
on the host. [First build](setup.md#first-build) copies them into the Keychain.

### Ceph dashboard

The dashboard is at `https://<proxmox-address>:8443/` with a self-signed certificate. Log
in as `admin` with the password in `/root/.ceph-dashboard-admin` (mode 600) on the host.
To keep a copy in the Keychain:

```sh
source scripts/env.sh && source scripts/keychain-lib.sh
ssh root@"$PVE_IP" cat /root/.ceph-dashboard-admin | kc_store_stdin ceph-dashboard-password
```

The Object Gateway zone and multisite pages return 500 on Proxmox. The manager drops
supplementary groups and cannot read `/etc/ceph/ceph.conf`, which is a link into pmxcfs.
The bucket and user pages work. To browse objects, use Filestash or the aws CLI.
