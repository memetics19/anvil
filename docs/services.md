# Services

What each host runs and how its roles manage it. The commands are in [usage.md](usage.md).
The Vault paths are in [secrets.md](secrets.md).

Placeholders: `<domain>`, `<gateway-domain>`, `<proxmox-address>` (the host's lab address),
`<proxmox-home-address>`, `<ragnarok-address>`.

Every compose project goes through the `compose_project` role. It recreates only the
services whose config changed and never runs `down`. See
[Scoped compose](usage.md#safety-rails).

## frigate

`make vm HOST=frigate ARGS="--tags frigate"` runs the `frigate_stack` role.

The role owns Frigate's `config.yml`. The next run overwrites edits made in the Frigate UI,
so change `ansible/roles/frigate_stack/templates/config.yml.j2` instead. To try settings
in the UI first, run with `-e frigate_stack_manage_frigate_config=false`, then copy the
result into the template.

- A changed compose service is brought up on its own.
- A changed Frigate, Mosquitto or frigate-notify config restarts only that container.
- The public hostname reaches Frigate through nginx on the VM. Frigate's own login on port
  8971 is the access control. The `admin` password is in Vault.
- Frigate's unauthenticated API (5000) listens on the VM's loopback only.
- Mosquitto is not published. Frigate and frigate-notify reach it on the compose network.
- The images are pinned by tag and digest in `frigate_stack/defaults/main.yml`.

### Docmost (wiki)

`make vm HOST=frigate ARGS="--tags docmost"` runs the `docmost` role. It manages the
compose project `/opt/docmost`. Each container is pinned by tag and digest and has a
memory cap:

| Container | Memory cap |
|---|---|
| Docmost | 768 MB |
| Postgres | 256 MB |
| Redis | 96 MB |

Docmost publishes port 3000 on the VM's lab address only. People reach it through the
gateway at `wiki.<gateway-domain>`, on the LAN and the VPN. Nothing about it is public.

- Secrets: `app_secret` and `db_password` in `kv/homelab/frigate/docmost`. The role
  generates them the first time. Each container gets only its own, from a mode 600 env
  file (`docmost.env`, `db.env`). A changed value recreates that container.
- Uploads use Docmost's local storage driver, in the `storage` volume. The database is in
  the `db` volume.
- Docmost migrates its database itself when a new version starts. To upgrade, change
  `docmost_image` and run the role.
- No email is set up. Invite people with the invite link Docmost shows. Reset a password
  from the admin settings.

The first person to open `https://wiki.<gateway-domain>` creates the workspace and becomes
its admin. Open it right after the first run, so that you are that person. The site entry
in `site.services` is
`{name: wiki, host: hosts.frigate.ip, port: 3000, scheme: http, websocket: true}`.
Collaborative editing uses a WebSocket.

## ragnarok

`make vm HOST=ragnarok` runs four compose projects. None of them may live inside the media
library. `tests/test_media_untouched.sh` checks that nothing in `ansible/` or `scripts/`
can reach it.

### ARR stack

The `arr_stack` role manages `/home/ubuntu/docker-compose.yaml`: qBittorrent, Prowlarr,
Jackett, FlareSolverr, Radarr and Sonarr. The apps keep their settings and API keys in
`./<app>/config`, which is not templated. The media library appears in the template only
as bind-mount sources.

One part of the apps' settings is code: the quality policy (tag `arr_quality`, defaults
`arr_stack_quality_*`). Through each app's API it keeps:

| Setting | Value |
|---|---|
| Quality profile `1080p+` in Sonarr and Radarr | Every quality of 1080p and higher, never 720p or SD. No remuxes or disc images (30 to 80 GB each) |
| Its cutoff | The first 1080p quality. A 1080p release is final, it is not replaced by a 4K one |
| Minimum size of WEB 2160p | 10 MB per minute. 4K x265 web releases run 10 to 20 MB/min, under the apps' default of 35 |

`anvil media get` adds with `1080p+`. The policy never deletes a profile and never changes
a series or movie. To move one to the policy, pick `1080p+` in its Edit dialog.

```sh
make vm HOST=ragnarok ARGS="--tags arr_quality --check"   # what would change
make vm HOST=ragnarok ARGS="--tags arr_quality"
```

### Guide server

The `iptv_epg` role runs nginx on port 8899. It serves `/home/ubuntu/iptv-epg/output`,
where the IPTV guide grabber writes `guide.xml`.

### Filestash

A read-only browser for the S3 gateway at `http://<ragnarok-address>:8334/`. It is bound
to the VM's LAN address, with a 256 MB memory cap and no swap.

- It runs as its own host user, uid 10001, because the VM's first user owns the media.
- The container has a read-only root file system, no capabilities and no-new-privileges.
- Only that user can read its state, which holds the S3 keys.
- The role never changes owners recursively. After a uid change it stops. Then chown
  `/opt/filestash/state` by hand once.

Log in as `admin` with `admin_password` from `kv/homelab/ragnarok/filestash`. The same
password opens `/admin`. The role generates it into Vault on the first run.

`make ceph` creates the S3 user `filestash`. It owns no buckets and cannot create any.
Bucket policies let it list and read `tfstate`. Its keys go into the same Vault path.
Filestash keeps them on the server side.

Filestash rewrites its `config.json` at start, so the role manages only its own keys in
it. Changes made in the admin console to the login, connections or sharing are
overwritten.

### IPTV

`make vm HOST=ragnarok ARGS="--tags iptv"` runs the `iptv` role in `/opt/iptv`. The
lineup is [`iptv/channels.yml`](../iptv/channels.yml), checked by
`tests/test_iptv_lineup.sh`.

| Part | Port | What it does | Memory cap |
|---|---|---|---|
| Threadfin | 34400 | Serves the playlist and guide | 64 MB |
| Stream helper | 34401 | Streams a channel on request with streamlink, at most two at once. Serves the web TV page and `/guide.json` (now and next). | 192 MB |
| Guide grabber | | Timer `iptv-epg-grab`, at 03:30 and 15:30. Writes the guide server's `guide.xml`. | 40 MB while it runs |

Threadfin login: `admin`, with `admin_password` from `kv/homelab/ragnarok/threadfin`. The
role owns Threadfin's two sources and its settings. Sources added by hand in the UI are
left alone, and a rebuild does not recreate them.

`make host-network` forwards ports 34400 and 34401, and nothing else, from the Proxmox
host's home address to `ragnarok`. Home devices can use these URLs, and so can NetBird
clients that route the home network. Devices on the lab network cannot.

| What | URL |
|---|---|
| Web TV page | `http://<proxmox-home-address>:34401/` |
| Playlist | `http://<proxmox-home-address>:34400/m3u/threadfin.m3u` |
| Guide (XMLTV) | `http://<proxmox-home-address>:34400/xmltv/threadfin.xml` |

The web TV page shows every channel enabled in Threadfin's Mapping. It refreshes that list
once a minute, so enabling a channel there needs no change to the repo lineup. It opens on
the last channel watched.

| Key | Action |
|---|---|
| Left, Right (or FF, REW) | Change channel |
| OK | Show what is on |
| Up, Down | Open the channel list |
| Back | Close the list |

Fire TV:

- Vega OS: open the web TV page in Silk.
- Fire OS with sideloading: add the playlist URL in TiviMate (Add playlist, Enter URL) or
  in VLC for Fire (Browse, New favorite). VLC shows no guide.

### Media over NFS (Jellyfin in another home)

`make vm HOST=ragnarok ARGS="--tags nfs_media"` does two things:

- It puts ragnarok on NetBird cloud as a plain peer (role `netbird_peer`, no routes).
- It serves `movies` and `tv` from the media library over NFSv4, read-only (role
  `nfs_media`). `downloads` is not shared.

Access rules:

- Only NFSv4 over TCP (port 2049). No NFSv3, no UDP. rpcbind is not reachable over
  NetBird.
- Each client reads as the library's owner (`all_squash`, uid 1000) and can change
  nothing.
- A firewall table, `anvil_nfs_guard`, drops NFS and rpcbind everywhere but the NetBird
  interface. On that interface it drops them from everyone but the clients in
  `site.nfs.clients`. It loads at boot, before the NFS server. The lab network cannot
  mount the library either.

Nothing runs until `site.nfs.clients` lists a client. Before the first run:

1. In the NetBird cloud dashboard, create a setup key for ragnarok and store it in Vault:
   `vault kv put -mount=kv homelab/ragnarok/netbird setup_key=-` (paste it, then Ctrl-D).
2. Put the other home's Jellyfin machine on NetBird cloud. Add its NetBird IP to the site
   dict as `site.nfs.clients: [<ip>]`.
3. In the dashboard, add a policy that lets only that machine reach ragnarok on TCP 2049.

On the Jellyfin machine (Linux), mount it read-only:

```sh
sudo mkdir -p /mnt/media/movies /mnt/media/tv
echo "<ragnarok's NetBird IP>:/home/ubuntu/media/movies /mnt/media/movies nfs4 ro,_netdev,nofail,soft,timeo=150 0 0
<ragnarok's NetBird IP>:/home/ubuntu/media/tv /mnt/media/tv nfs4 ro,_netdev,nofail,soft,timeo=150 0 0" |
  sudo tee -a /etc/fstab
sudo mount -a
```

Then add `/mnt/media/movies` and `/mnt/media/tv` as libraries in Jellyfin.

## netbird

`make vm HOST=netbird` runs the "Netbird workloads" play. This VM is the emergency VPN
path. Never run it in the same Ansible run as `make host-network`.

### NetBird client

The `netbird_peer` role installs the client from NetBird's apt repository, with the
signing key pinned by checksum. It is the routing peer on NetBird's cloud service.

- The package is pinned to `netbird_peer_version` and held. Neither a run nor
  unattended-upgrades moves it.
- Bumping that variable is the upgrade, and it restarts the client. Otherwise the service
  is never restarted.
- A connected client is left alone: no `netbird up`, no `down`, no re-enrollment, and
  Vault is not read.
- Only a client in state `NeedsLogin` is enrolled, with `setup_key` from
  `kv/homelab/netbird/netbird`. The run stops with instructions if that key is missing.
- Any other state is reported and left alone.
- At the end, the run checks that the client is still connected.

Routes, groups and ACLs stay in the NetBird dashboard.

### Self-hosted NetBird server

The `netbird_server` role runs a NetBird server on this VM, next to the cloud client. It
runs only when `site.netbird_domain` is set, for example `sync.<domain>` (a neutral name).
The compose project `/opt/netbird-server` has three containers, each with a memory cap:

| Container | What it does |
|---|---|
| `netbird-server` | NetBird's combined server: management, signal, relay and the built in identity provider. Pinned by tag and digest. Its plain HTTP port is on the VM's loopback only, for the role's API calls. |
| `netbird-dashboard` | The web dashboard |
| `netbird-caddy` | TLS with its own internal CA on the VM's lab address, port 8443. The Cloudflare tunnel's origin for `site.netbird_domain`. Sends gRPC (HTTP/2 cleartext), the relay, the API and the identity provider to the server, and everything else to the dashboard. |

The public name is neutral. Caddy drops the `Server` and `Via` headers. It replaces the
dashboard's Content-Security-Policy, which lists the vendor's domains and trackers, with
one that names only this host. The page titles of the dashboard and the login page still
say NetBird. Neither is configurable.

- STUN uses public servers only (Cloudflare and Google). The server opens no UDP port.
- When hole punching fails, the relay carries the connection, over WebSocket through the
  tunnel. There is no port forward on the home router.
- Secrets come from `kv/homelab/netbird-srv`. The role creates any that are missing.
  `config.yaml` holds them with mode 600.
- A change to `config.yaml` or to the Caddyfile recreates that container, through a hash
  label in the compose file.

The role then sets up the server through its API (`files/netbird_api.py`, run on the VM):

1. On a new server, it creates the owner user (`site.email`, the password from Vault) and
   a personal access token, before the public name is routed. Both go to Vault. The token
   is replaced when it has less than 30 days left.
2. The network range `site.netbird_server.network_range`.
3. Groups `operator` and `routers`. Every device the owner logs in joins `operator`.
4. One access policy, `operator` to `routers`. The All to All policy `Default` is deleted.
5. Networks `lab` (the lab's /16, masquerade on) and `home-gateway` (the `apps` home
   address as a /32, masquerade off), both routed by group `routers`.
6. Pi-hole on the `apps` home address as the nameserver for the gateway domain, for
   `operator`.

Objects are matched by name. Anything else you add in the dashboard is left alone.

### netbird-home client

The self-hosted network's routing peer is a second NetBird client service on this VM,
`netbird-home` (the netbird_peer role, `tasks/home.yml`). It uses the same held package as
the cloud client, with its own:

- state directory, socket and log
- interface `wt1` and WireGuard port 51821
- nftables table

It has no custom routing rules or eBPF proxy. Those are host wide and belong to the cloud
client. It starts after Docker and the cloud client, and only once the `ip filter` table
exists. With that table NetBird picks its nftables backend, so `netbird-home` never
touches the cloud client's iptables chains.

- DNS and client routes are off. It only routes.
- A client that needs a login is enrolled once the public name answers. The role creates
  a new one-off setup key through the API for it and stores the key in Vault.
- A connected client is never brought up, down or re-enrolled.
- Its unit restarts only when the unit file changes. The cloud client is never touched.

Check it on the VM:
`sudo netbird status -d --daemon-addr unix:///var/run/netbird-home.sock`.

### Other services

- `redis`: the Ubuntu package with its default config, localhost only. A hand edit to
  `redis.conf` is reported, not reverted.
- `ntfy`: compose project `~/ntfy` on port 8081. Anonymous access is denied. Users and
  access rules live in its auth database, which is not templated.
- `pulse`: [memetics19/pulse](https://github.com/memetics19/pulse), the status page and its
  docs site, in the compose project `/opt/pulse` (Pulse, and Caddy on port 80). `.env` is
  rendered from Vault with mode 600.

The VM keeps Pulse current by itself. Nothing on GitHub can reach it. `pulse-update` runs
every 10 minutes from `pulse-update.timer`, and once from the role. It does the following.

- Deploys the newest `vX.Y.Z` tag of the major version it follows, as the image the
  release workflow pushed, `ghcr.io/memetics19/pulse:X.Y.Z`.
    - Before the switch, it stops Pulse and copies its data volume to
      `/opt/pulse/backups/`. The newest 5 copies are kept.
    - If the new version does not answer `/healthz` within 90 seconds, the previous image
      and that copy come back, and the run fails.
    - The failed tag goes to `/opt/pulse/state/failed`. Later runs skip it, so a bad
      release does not restart Pulse every 10 minutes. The next newer tag is tried as usual.
      `sudo pulse-update --retry` tries the failed one again.
    - Old data copies are dropped after a failed deploy too.
    - A release that only starts slower than 90 seconds is rolled back the same way, since
      it cannot be told from a broken one. Raise `pulse_health_timeout`, then run
      `sudo pulse-update --retry`.
- A first install has no earlier image to go back to. If it does not answer in time, it
  is left running and written to `/opt/pulse/state/pending`, not marked failed. Later runs
  leave it alone and record it once it answers, so a slow first migration needs no help.
- Follows one major version (`pulse_track: "3"`). A 4.0 release, which may break things,
  is never deployed by itself.
- Checks the pulled image's cosign signature before it stops anything.
    - The digest must be signed by Pulse's release workflow and logged in Rekor
      (`pulse_signer`). Pulse then runs that exact digest: the one listed for
      `ghcr.io/memetics19/pulse`, even when the image has other names too.
    - An unsigned or tampered image, or one without that digest, is not deployed. Pulse
      keeps running.
    - The check runs in a pinned cosign container (`pulse_cosign_image`) and needs internet
      access to Sigstore.
    - `pulse_verify_signature: false` turns it off, for example to pin a release older than
      3.0.0, which is not signed.
- Builds the docs site from the head of `main` with mkdocs into `/opt/pulse/docs/` and
  moves the `current` link to it.

Caddy sends names that start with `docs.` to the docs site and every other name to Pulse.
The Cloudflare tunnel publishes both names.

| Command or setting | What it does |
|---|---|
| `sudo pulse-update --check` | Shows what the next run would do |
| `pulse_track: "4"` in `inventory/host_vars/netbird.yml`, then `make vm HOST=netbird ARGS="--tags pulse"` | Moves to a new major version. Read its release notes first. |
| `pulse_track: v3.1.0` | Pins one release |
| `pulse_track: latest` | Follows every major |
| `sudo pulse-compose ps` (or `logs`) | Runs docker compose for the project |
| `journalctl -u pulse-update` | The deploy history |

If a rollback cannot copy the data back, Pulse stays stopped. The name of the data copy
goes to `/opt/pulse/state/hold`. Until that file is gone, every run stops at once and
changes nothing. No new release lands on the broken data, and the copy is never dropped.
`sudo pulse-update --check` shows the hold. `/opt/pulse/release.env` already names the
previous image. To clear the hold, put the copy back by hand, start Pulse, check it, then
remove the file:

```sh
name=$(cat /opt/pulse/state/hold)
sudo docker run --rm -v pulse_pulse_data:/data -v /opt/pulse/backups:/backup alpine \
  sh -c "find /data -mindepth 1 -delete && cp -a '/backup/$name/.' /data/"
sudo pulse-compose up -d pulse caddy
curl -fsS http://localhost/healthz && sudo rm /opt/pulse/state/hold
```

- `pulse_agent` (every VM in `guests` and `apps_servers`): host metrics for Pulse. Run it
  with `make vms ARGS="--tags pulse_agent"`. The role:
    1. Adds the homelab apt repository from the netbird VM's lab address (port 8082). It
       installs its key only if the fingerprint is
       `E583 2FE9 662C 5F40 21A7 D4A5 2DE3 AD52 8436 9C1D`.
    2. Installs `pulse-agent`.
    3. Registers the VM in Pulse under its inventory name, through `pulse.<gateway-domain>`,
       with the API key in `kv/homelab/netbird/pulse` (`api_key`, scope `agents:write`).
    4. Pulse shows the agent token once. It goes straight into
       `kv/homelab/<vm>/pulse-agent` (`token`) and into `/etc/pulse-agent/token` (mode 640,
       group `pulse-agent`).

    The agent reports every 30 seconds to Pulse over the lab network. The netbird VM uses
    loopback. The enclave VMs get no agent. They have no route to Pulse, and opening one
    would weaken the enclave. To register a VM again, delete its agent in Pulse's admin and
    its token in Vault, then run the role.
- `apt_repo`: the signed apt repository for the .deb packages of anvil and pulse
  (`apt_repo_sources`), in `/opt/apt-repo`. Caddy serves it read-only on port 8082
  (compose project `apt-repo`). The Cloudflare tunnel publishes it as `apt.<domain>`.

`apt-publish` runs every 30 minutes from `apt-publish.timer`, and once from the role:

1. It takes the .deb files of each new `vX.Y.Z` release of every source.
2. It checks them against the release's checksum file (`checksums.txt` for anvil,
   `SHA256SUMS` for pulse) and keeps them in `pool/`.
3. When something is new, it builds a fresh tree with `apt-ftparchive` and signs
   `InRelease` and `Release.gpg`.
4. It checks both signatures with the key it publishes, then moves the `site/current` link
   to the new tree.

A .deb that does not match its checksum stops the run, and the live tree stays as it was.
The signing key is published as `key.gpg` and `key.asc`, and also as `anvil.gpg` and
`anvil.asc` for machines set up with the first instructions. The tree can be rebuilt from
the releases and the key at any time, so it has no backup.

- `sudo apt-publish --check` shows what the next run would do.
- `journalctl -u apt-publish` has the history.
- `scripts/apt-key-init.sh` makes the key once and writes it straight into Vault.
- To rotate the key, delete `kv/homelab/apt/signing` and `/opt/apt-repo/gnupg`, rerun the
  script and the role, and tell users to fetch `key.gpg` again.

PHP is kept off this VM. `php*`, `composer` and `jsonlint` were removed by hand on
2026-10-21 (php2shell, CVE-2026-109618/109619). The role purges them if they come back.
The list is `guest_base_absent_packages` in `inventory/host_vars/netbird.yml`, tag
`packages_absent`. There is no autoremove.

## apps

`apps` is one small VM (1 vCPU, 1.5 GB) for the always-on services: Pi-hole, the service
gateway and Homepage. Vaultwarden ran here first. It now runs on its own VM in the
[secrets enclave](#secrets-enclave).

It has two NICs on `vmbr0`, both set by cloud-init in `terraform/vm_apps.tf`:

| NIC | Address | Route |
|---|---|---|
| Lab | A lab address | The default route |
| Home | A home-network address (`site.hosts.apps.home_ip`) | No gateway. Home devices reach Pi-hole on their own subnet. |

Each NIC answers ARP only for its own address.

### Firewall

The `host_firewall` role sets up ufw. Inbound traffic is denied by default. These are
allowed, each bound to its NIC and address:

- SSH (22)
- DNS (53, TCP and UDP)
- the gateway (80, 443)

A change has a timed rollback. ufw disables itself after 3 minutes unless a fresh SSH
connection and DNS and HTTP checks from the Mac succeed first.

ufw does not filter ports that Docker publishes. Docker forwards them to the container
through its own chains, so they never reach ufw's input rules. For those ports, the
`ip:port` binding in the compose file is the boundary.

- Bind every published port to a specific address, never `0.0.0.0`, as Caddy's 80 and 443
  are.
- Use the host's lab address when the gateway or another host needs the port.
- Use `127.0.0.1` when only the VM itself needs it.
- Do not publish a port that only other containers use. They reach it by service name on
  the compose network.

`tests/test_published_ports.sh` fails on any published port in a compose template that
names no address.

### Pi-hole

The `pihole` role runs compose project `/opt/pihole`.

- Pi-hole publishes DNS on port 53 on the two `apps` addresses only. It is not a DHCP
  server.
- Its web UI is not published. It is at `https://dns.<gateway-domain>/admin/` through the
  gateway, with `web_password` from `kv/homelab/apps/pihole`. Settings the role passes are
  read-only in the UI.
- Its only upstream is Unbound, at a fixed address on the project's own Docker network
  (`site.hosts.apps.dns_subnet` and `dns_unbound_ip`, never published). Unbound resolves
  from the root servers, validates DNSSEC and has a healthcheck.
- Either container can restart on its own, and resolution comes back without a run.

#### Rate limit

Each client may send 5000 queries per 60 seconds (`pihole_rate_limit_count` and
`pihole_rate_limit_interval`). The limit counts per client address.

- Every VLAN client and every NetBird peer routed through the Proxmox host arrives as the
  host's address, because the host masquerades them. They all share one limit. That is
  why it is 5000 and not FTL's 1000.
- NetBird clients behind the `netbird` VM share that VM's address too.
- Hand Pi-hole out to devices directly through the router's DHCP. If the router forwards
  its own DNS to Pi-hole instead, every device shows up as the router and shares one
  limit.

The role applies the rate limit live (`tasks/settings_apply.yml`, `pihole_ftl_live`). It
reads each FTL setting with `pihole-FTL --config`, writes only what differs and reads it
back. Like the local records, it is not in the compose environment, so changing it never
recreates the container. A setting listed in `pihole_ftl_live` must not also be an
`FTLCONF_` variable, because FTL makes those read-only.

#### Local records

Local records come from `site.dns.local_records` in Vault.

| Entry key | Served as |
|---|---|
| `name` | `<name>.lan.<domain>`. The `lan` sub-zone keeps it from shadowing a public name. |
| `fqdn` | Exactly that name, for split horizon: a public hostname answered at home with a home address. |

The address is `ref`, a path into the site dict, or `ip`. The role applies these records,
and the gateway's names, to the running Pi-hole with `pihole-FTL --config dns.hosts`. It
does so only when they differ, so DNS is never interrupted. A record added in the UI is
removed on the next run. `tests/test_pihole_records.sh` covers the rules.

#### Block lists and deny rules

Block lists and deny rules are code: `pihole_blocklists` and `pihole_deny_regex` in the
role's defaults. The role keeps them present and enabled. Lists and rules added in the web
UI are left alone.

- The lists are StevenBlack, AdGuard DNS, EasyPrivacy, Prigent crypto, URLhaus and HaGeZi
  Multi PRO. A new list runs a gravity update.
- The deny rules block, with their subdomains, the ad and tracking networks a free torrent
  client shows ads from: uTorrent's Rainberry service and the ad networks it calls. No
  list blocks those. A new deny rule reloads the lists.

Pointing the home router and NetBird at Pi-hole are hand steps, in
[setup.md](setup.md#not-managed-here).

### Service gateway

Every web UI in the lab is at `https://<name>.<gateway-domain>`, served by Caddy on `apps`
(`caddy` role, compose project `/opt/caddy`) with a publicly trusted certificate.

The gateway domain is `<subdomain>.<domain>`, with the subdomain from
`site.gateway.subdomain` (for example `internal`). When that key is empty, it is just
`<domain>`. `ansible/inventory/group_vars/all/gateway.yml` builds it as `gateway_domain`
for the caddy, pihole and homepage roles. `site.domain` itself, used for the public tunnel
names, does not change.

The gateway is private:

- Its names exist only as Pi-hole records that point at the `apps` home address. They work
  only on the home and lab networks and over NetBird. For NetBird, that address must be on
  a route the peers use.
- Nothing goes into public DNS. No tunnel or port forward points at the gateway.
- Caddy listens only on the two `apps` addresses.
- With a subdomain, no public name is shadowed. `frigate.<domain>` still reaches its
  tunnel, and the local name is `frigate.<gateway-domain>`.

Caddy gets one wildcard certificate, `*.<gateway-domain>`, from Let's Encrypt through the
DNS-01 challenge. It creates the `_acme-challenge` TXT record through the Cloudflare API
and removes it afterwards. Certificate Transparency logs show only the wildcard. The API
token is `cloudflare_dns_token` in `kv/homelab/apps/caddy`. It may only edit DNS in that
zone. It reaches Caddy through a mode 600 env file.

One list drives Caddy, Pi-hole and Homepage: `site.services` in Vault.

- Each entry has a name, an upstream (`host`, a path into the site dict, or `container`), a
  port and a scheme.
- Optional fields cover self-signed upstreams, Vault's CA, websockets, long streams, the
  upstream Host header and absolute redirects to the upstream's own address
  (`rewrite_location`, used by the [switch](cisco-switch.md#web-ui-through-the-gateway)).
  They are documented in `ansible/roles/caddy/defaults/main.yml`. `tests/test_gateway.sh`
  covers the rules. See [Adding a service](usage.md#adding-a-service-behind-the-gateway).
- A `static` entry has no upstream. Caddy serves files from `/opt/caddy/sites/<static>`, a
  read-only mount. This documentation is one, at `docs.<gateway-domain>`
  ([Publishing the docs](usage.md#publishing-the-docs)).

HTTP redirects to HTTPS. Names not in the list get the connection closed. Only HTTP/1.1
and HTTP/2 are served. No UDP port is published.

The image is Caddy with the `caddy-dns/cloudflare` module, built by xcaddy from the pinned
`caddy_*` versions and base-image digests. It is built on `ragnarok`, because a Go build
of Caddy needs more memory than `apps` has free. It is then copied through the Mac and
loaded on `apps`. The tag includes a hash of the Dockerfile, so a version change builds a
new image. The memory cap is 128 MB.

The gateway adds no login of its own. Turn on each app's own login. Every client reaches
the app from the gateway's address. So for qBittorrent, set a password and remove the
"bypass authentication for clients in whitelisted IP subnets" entry.

Some routes answer only the operator's devices. Every other client gets 403, checked on
the real client address before anything else:

- `pass` and `vault` (`caddy_admin_only_routes`): the enclave's operators. See
  [Secrets enclave](#secrets-enclave).
- The infrastructure pages (`caddy_infra_routes`): `pve`, `ceph`, `idrac`, `switch`, `dns`,
  `home`, `qbit`, `frigate` and `threadfin`.
    - The sources are `site.admin_sources` and `site.admin_vpn_sources` together, whatever
      `site.enclave.vpn_only` says, so the Mac keeps LAN access to them.
    - Homepage is one of them because it has no login and its widgets show Proxmox,
      Pi-hole and ARR data.
    - Threadfin is one because it is the TV lineup's admin page.
- `tasks/services.yml` refuses any source that is not a single /32. It also refuses the
  Proxmox host's own addresses. VLAN clients and NetBird peers behind the host's
  masquerade arrive as those addresses, so admitting one would let all of them in.

These stay open on the gateway:

- Authentik (`auth`, its own login, the page everyone signs in on)
- the ARR apps (API key and login)
- Filestash (`files`, a generated 32-character password)
- Gotify (its token)
- the live TV streams (`tv`)
- the docs

ntfy has no web login (its topic access rules decide). Pulse's login was not checked. Add
either to `caddy_infra_routes` to close it to everyone but the operator.

#### Single sign-on on the gateway

When `site.services` has an `auth` entry (Authentik), Caddy asks Authentik's embedded
outpost before it passes a request on. A browser without a valid login goes to
`https://auth.<gateway-domain>`. One login there sets a cookie for every gateway name.
Only members of the Authentik group `lab-admins` get through (see
[Single sign-on as code](#single-sign-on-as-code)).

- Every route is behind it except `caddy_sso_exempt`: `auth`, `pass`, `vault`, `pulse`,
  `ntfy`, `gotify` and `tv`. Vault and Vaultwarden keep their own logins and work when
  Authentik is down. Pulse's API, the push apps and the Fire TV use tokens or no login, so
  a sign-in page would break them.
- `sso: true` or `sso: false` on an entry of `site.services` overrides the list.
- On an operator-only page, the 403 for other clients comes first, then the login check.
- The apps keep their own logins for now. Their ports are still open on the LAN, so
  turning a login off would leave the app open there.
- Homepage widgets, Pulse monitors and the apps talking to each other use the upstream
  addresses, not the gateway names, so the login check does not touch them.
- If Authentik is down, the names behind it answer with an error. Proxmox stays reachable
  on its own address, port 8006.

### Homepage

`https://home.<gateway-domain>` is a [Homepage](https://gethomepage.dev) dashboard (the
`home` entry of `site.services`, `homepage` role, compose project `/opt/homepage`). It has
a link for every enabled gateway service, and a live widget where one exists. It has no
login of its own: single sign-on on the gateway covers it.

The config is generated from `site.services`. `tests/test_homepage.sh` covers the rules.

- Title, group, icon, description and widget for each name come from `homepage_catalog`
  in the role defaults.
- An entry in `site.services` can override any of them. `widget: none` turns a widget off.
- A name not in the catalog goes to group `Other` with no widget.
- Disabled entries are left out.
- The groups are Infrastructure, Media, Home, Security and, later, Monitoring.

The config files hold no secrets. Widget keys are `{{HOMEPAGE_VAR_*}}` placeholders.
Homepage fills them from `/opt/homepage/homepage.env` (mode 600, values from Vault).

The widgets are Proxmox, Ceph, Pi-hole, Sonarr, Radarr, Prowlarr, qBittorrent, Frigate and
the container status of Pi-hole.

- Homepage has no Ceph widget. The Ceph one reads the Proxmox API with the same read-only
  token.
- Pi-hole uses an application password, not the web password.
- qBittorrent needs no login.

Each credential is made by the role that owns the app:

| Command | Credential |
|---|---|
| `make host ARGS="--tags homepage"` | Proxmox user `homepage@pve`, with no password, and its privilege-separated token, both PVEAuditor |
| `make vm HOST=ragnarok ARGS="--tags homepage"` | The ARR API keys, read from the apps' `config.xml` without changing anything on `ragnarok` |
| `make vm HOST=frigate ARGS="--tags homepage"` | Frigate user `homepage`, role viewer |
| `make vm HOST=apps` | The Pi-hole application password |

On a new site, run the first three before `make vm HOST=apps`. Each run checks every
widget through Homepage's API. A widget with an error is a warning, because its app may be
on another VM. `ARGS="-e homepage_strict_widgets=true"` makes it fail the run instead.

Hardening:

- The image is pinned by tag and digest.
- No port is published. Caddy reaches it on the project network `homepage_web`.
- Only `home.<gateway-domain>` is an allowed Host.
- It runs as its own uid, with a read-only config directory and a 192 MB memory cap.
- Container status goes through a pinned Docker socket proxy, on an internal network that
  only Homepage shares. The proxy allows only `GET /containers/json` and
  `GET /containers/<id>/stats`. It allows no inspect (container environments hold
  secrets), logs, exec or writes.
- Containers on other VMs show no status. A socket proxy there would listen on the lab
  network, where Docker-published ports bypass ufw.

Look:

- A dark slate theme, blurred cards, status dots and no version footer.
- Infrastructure and Media use 3 columns, the other groups 2.
- A date and time widget. No search widget, because it would send what you type to a
  search engine.
- Weather (Open-Meteo) shows only when `site.homepage.weather` has `latitude` and
  `longitude`.
- For a background picture, put `~/homelab-assets/homepage-bg.jpg` on the Mac
  (`homepage_background_src`). The run copies it to `/opt/homepage/images`, restarts
  Homepage once and shows it with blur, saturation, brightness and opacity filters.

### Vaultwarden

`https://pass.<gateway-domain>` is
[Vaultwarden](https://github.com/dani-garcia/vaultwarden), a Bitwarden-compatible password
manager (the `pass` entry of `site.services`, `vaultwarden` role, compose project
`/opt/vaultwarden`, data in `/opt/vaultwarden/data`). Bitwarden apps and browser
extensions use it as a self-hosted server URL.

It runs on the `vaultwarden` VM in the [secrets enclave](#secrets-enclave)
(`make vm HOST=vaultwarden`).

- The container is `vaultwarden/server`, pinned by tag and digest.
- The VM has no registry access. The image is pulled by digest on `ragnarok`, exported,
  copied through the Mac and loaded by tag. It is never pulled on the VM. The run checks
  that its layer list equals the pulled image's.
- Docker comes from Ubuntu's archive (`docker.io`, `docker-compose-v2`) through the apt
  cache.
- The port is published on the VM's enclave address only. There the enclave firewall lets
  only Caddy (`apps`) in.
- It runs as uid 10004 on port 8080, with a read-only root file system, no capabilities
  and a 128 MB memory cap.
- Websocket notifications (`/notifications/hub`) go through the gateway on the same name.
- On a VM with no database, the role refuses to start an empty Vaultwarden. The flag
  `-e vaultwarden_allow_empty_start=true` is for a deliberate fresh install.

The Vault paths keep the name of the VM it was first set up on:
`kv/homelab/apps/vaultwarden` and `kv/homelab/apps/vaultwarden-backup`.

#### The move from `apps` (2026-10-21)

1. The `apps` copy's backup job ran one last time and was checked.
2. Its container was stopped. The database was copied with `sqlite3 .backup`, plus
   `rsa_key.pem`.
3. The new VM started on that copy, and the `pass` entry was switched to
   `host: hosts.vaultwarden.ip`.
4. The users and ciphers rows, and digests of both tables, were equal on both sides.
5. After a day on the new VM (a fresh backup decrypted, the drill passed, the counts
   unchanged), the old copy on `apps` was removed: its container, `/opt/vaultwarden`
   (data included), its backup units and `/etc/vaultwarden-backup` (the S3 keys). Caddy
   left the network `vaultwarden_web` (one recreate), which was then removed.

`DOMAIN` is the gateway name. Sign-ups are closed (`SIGNUPS_ALLOWED=false`), invitations
are on, and password hints are never shown.

Don't save settings on the admin page. They go to `data/config.json`, which overrides the
role's environment. Each run lists the keys there that shadow a role setting. The run
stops before it touches the container if one of them weakens it:

- open sign-ups
- email verification or email two-step login off while SMTP is on
- hints shown
- no admin token
- another domain
- fewer iterations
- a pinned `admin_token`

The fix is in [Troubleshooting](usage.md#troubleshooting). The role never deletes or
rewrites that file.

The admin token is generated into `kv/homelab/apps/vaultwarden` as `admin_token`.
Vaultwarden gets only its Argon2id hash, `admin_token_hash`, in
`/opt/vaultwarden/vaultwarden.env` (mode 600). Each run checks that:

- the hash matches the token
- the admin page accepts the token
- `/alive` answers
- an uninvited address cannot sign up

To change the token, write a new `admin_token` to Vault and rerun
`make vm HOST=vaultwarden`.

#### Mail

SMTP is set from `kv/homelab/apps/vaultwarden`. The pair `smtp_username` and
`smtp_password` turns it on. With only one of the two, the run stops. With SMTP,
invitations are mailed and `SIGNUPS_VERIFY` is on.

| Key | Default |
|---|---|
| `smtp_host` | `smtp.gmail.com` |
| `smtp_port` | 587 |
| `smtp_security` (starttls, force_tls or off) | starttls |
| `smtp_from` | the username |

- Gmail: `smtp_username` is the Gmail address. `smtp_password` is a Google App Password,
  which needs 2-step verification on the account.
- Another relay: set `smtp_host`, `smtp_username`, `smtp_password`, and an address on its
  verified domain as `smtp_from`.

Write each value from stdin (see [Secrets in Vault](usage.md#secrets-in-vault)), then run
`make vm HOST=vaultwarden`. When `smtp_host` or `smtp_port` changed, also run
`make enclave ARGS="--tags firewall"`. The enclave firewall's mail hole (the relay set and
its port) is built from them.

#### Two-step login

With SMTP, every account registered from an invitation gets email two-step login
(`EMAIL_2FA_ENFORCE_ON_VERIFIED_INVITE`). Codes last 10 minutes, with 3 tries. That is the
only factor the server enforces.

- Add an authenticator app or a passkey as your main second factor, and save the recovery
  code (Settings, Security, Two-step login).
- If you create an organization, turn on its "Require two-step login" policy.

`REQUIRE_DEVICE_EMAIL=true` sends a mail on every new-device login. It is off on purpose.
With it, every login fails while mail cannot be sent, and you can be locked out of your
passwords. Add it to `vaultwarden_settings` if you want it.

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

The plaintext copy and the archive live on tmpfs in `/run/vaultwarden-backup`. They are
removed when the job ends. The job stops if there is less than twice the data free there.
`/run` is about 50 MB on the 512 MB `vaultwarden` VM. The data is well under 1 MB.

The bucket belongs to the S3 user `vaultwarden-backup`, made by `make ceph`. That user may
own no other bucket and cannot read any other. Its keys are in
`kv/homelab/apps/vaultwarden-backup`. `make backup` copies the newest object to the Mac.

Not done yet: object versioning or object lock on the bucket. The backup user owns the
bucket, so a compromised `vaultwarden` VM could delete the backups. Today the copies on
the Mac are the second copy.

`make vaultwarden-drill` tests a restore:

1. It takes the newest backup, which must be the copy `make backup` pulled.
2. It decrypts it on the Mac straight into a one-time key made on the `vaultwarden` VM.
   No plaintext touches the Mac's disk, and the identity never leaves it.
3. It restores into a temporary container, `vaultwarden-restore-drill`, with no network,
   no gateway route and no admin page. It moves any restored `config.json` aside.
4. It checks that `/alive` answers, that the user count equals the live one and that every
   restored user is live.
5. It removes the container and its directory.

The real restore is in [setup.md](setup.md#rebuilding-on-a-new-box).

## identity

The single sign-on VM, on the second Proxmox node (`terraform/vm_identity.tf`). It is
created only when `site.hosts.identity` exists:

| Field | Meaning |
|---|---|
| `node` | The cluster node it runs on |
| `vmid`, `ip`, `home_ip`, `mac`, `home_mac` | As for the apps VM: a lab NIC with the default route, a home NIC without |
| `datastore` | Its disk. Default `vmdata` |
| `cores`, `memory_mb`, `disk_gb` | Defaults 2, 3072 and 32 |

It gets the base guest roles (guest base, Docker, Pulse agent). The LDAP directory comes
next (planned in the README roadmap).

### Authentik (single sign-on)

`make vm HOST=identity ARGS="--tags authentik"` runs the `authentik` role. It manages the
compose project `/opt/authentik`. Each container is pinned by tag and digest and has a
memory cap. Together they use 2 GB of the VM's 3 GB:

| Container | Memory cap |
|---|---|
| Authentik server | 1024 MB |
| Authentik worker | 768 MB |
| Postgres | 256 MB |

Authentik needs no Redis since version 2025.10. Its cache, tasks and websockets use
Postgres.

The server publishes port 9000 on the VM's lab address only. People reach it through the
gateway at `auth.<gateway-domain>`, on the LAN and the VPN. Nothing about it is public. The
site entry in `site.services` is
`{name: auth, host: hosts.identity.ip, port: 9000, scheme: http, websocket: true}`.
It is not an infrastructure route: everyone who signs in with single sign-on needs it.
Port 9443 and the LDAP ports are not published. The LDAP outpost comes later.

- Secrets: `secret_key`, `postgres_password`, `bootstrap_password` and `bootstrap_token` in
  `kv/homelab/identity/authentik`. The role generates each one that is missing and never
  replaces one. Authentik gets them from `authentik.env` and Postgres gets its password
  from `db.env`. Both are mode 600. A changed value recreates that container.
- `bootstrap_password` is the first password of `akadmin`. `bootstrap_token` is an API
  token for `akadmin`, for configuring Authentik from code. Authentik reads both only on
  its first start. The account's email is `site.email`.
- Authentik trusts `X-Forwarded-For` and `X-Forwarded-Proto` only from the gateway VM's lab
  address (`authentik_gateway_host`).
- The worker gets no Docker socket and does not run as root. Authentik cannot start
  outposts by itself.
- Update checks, startup analytics and error reporting are off.
- Authentik migrates its database itself when a new version starts. To upgrade, change
  `authentik_image` and run the role. Read the release notes first. Postgres stays on the
  major version the release documents.
- The run ends when `/-/health/ready/` answers 200. The first start takes a few minutes.
- No email is set up yet.

First login, right after the first run:

1. Read the password: `vault kv get -mount=kv -field=bootstrap_password homelab/identity/authentik`.
2. Open `https://auth.<gateway-domain>` and sign in as `akadmin` with it.
3. Turn on a second factor for `akadmin`. If you change its password, the value in Vault
   stays the first one and no longer works.

Add a Pulse monitor for Authentik's health endpoint, `/-/health/ready/`, by hand. The role
does not create one.

#### Single sign-on as code

The role writes the blueprint `/opt/authentik/blueprints/anvil-sso.yaml`
(`templates/anvil-sso.yaml.j2`) and applies it with `ak apply_blueprint` on every run. The
worker also applies it every hour. A change made in the admin interface to these objects
goes back to what the blueprint says.

| Object | What it does |
|---|---|
| Group `lab-admins` | Its members may open every app below. Code adds nobody to it |
| Proxy provider `anvil-gateway`, app `Lab gateway` | Forward auth for every name under the gateway domain (domain mode). One login sets a cookie for the whole domain |
| Embedded outpost | Serves `anvil-gateway`. Its `authentik_host` is `https://auth.<gateway-domain>` |
| OAuth2 provider `anvil-proxmox`, app `Proxmox` | OpenID Connect for the Proxmox realm. Client id `proxmox`. It accepts redirects only to the gateway names on port 8006 |

The Proxmox client secret is `proxmox_client_secret` in `kv/homelab/identity/authentik`.
The role generates it like the other keys. It reaches Authentik as an environment variable
in `authentik.env` and is never written into the blueprint.

After the first run, make your own user, put a second factor on it and add it to
`lab-admins`. Only members of that group get past the gateway's forward auth and into
Proxmox.

#### Authentik backups

Authentik's Postgres holds the user directory and the whole configuration.
`authentik-backup.timer` runs `/usr/local/sbin/authentik-backup` every night at about
03:45. The job:

1. runs `pg_dump` in the `authentik-db` container, in Postgres' custom format
2. pipes the dump straight into `age`, encrypted to Keychain `backup-age-recipient`, the
   same key as the other backups. The plaintext dump is never written to a file, and the
   VM holds nothing that can decrypt it
3. uploads it to the Ceph bucket `authentik-backups` as
   `authentik-YYYYMMDD-HHMMSS.dump.age` (UTC) and checks the size
4. keeps the newest 14 of its objects and touches nothing else in the bucket

The job runs as root, because it uses `docker exec`. The encrypted file waits in the unit's
private `/var/tmp`, which systemd removes when the job ends. A failed dump, a stopped
database or a wrong upload size fails the job before anything is pruned.

The bucket belongs to the S3 user `authentik-backup`, made by `make ceph`. That user may
own no other bucket. Its keys are in `kv/homelab/identity/authentik-backup`. The role
stops if they are missing, so run `make ceph` before the first run. `make backup` copies
the newest object to the Mac.

The `data` volume (uploaded icons and brand images) is not backed up. The secrets are in
Vault, and Vault has its own backup. A restore needs the same `secret_key`.

To restore into a fresh install (the role has run once, so the database exists):

```sh
age -d -i <(security find-generic-password -s homelab -a backup-age-identity -w) \
    ~/homelab-backups/authentik-<YYYYMMDD-HHMMSS>.dump.age |
  ssh ubuntu@<identity-address> 'sudo docker stop authentik-server authentik-worker &&
    sudo docker exec -i authentik-db pg_restore -U authentik -d authentik --clean --if-exists --no-owner &&
    sudo docker start authentik-server authentik-worker'
make vm HOST=identity ARGS="--tags authentik"   # checks /-/health/ready/
```

## Secrets enclave

Vault and Vaultwarden live on their own network: the SDN vnet `secrets`, in the simple
zone `enclave` (`terraform/sdn.tf`). `make enclave` (role `pve_enclave`) sets up the host
side.

- The vnet is a bridge on the Proxmox host with no physical port. None of its frames reach
  the switch or the home network.
- The host is its only router. `site.sdn.enclave.gateway` is the host's address on it.
- The host does no NAT for it, except the one mail flow below.
- The vnet isolates its ports. The two VMs reach the gateway, not each other.

### Firewall: routed segments

The host's nftables table `inet segments` (role `pve_segments`) is built from data: a list
of segments in `inventory/group_vars/proxmox.yml` (`pve_segments_list`) and named sets.
Each segment has:

- a name, its interface, subnet and gateway
- a `nat` flag (masquerade the whole segment)
- three rule lists: `ingress` (new connections into it), `egress` (out of it) and `host`
  (to the Proxmox host)
- `nat_out`, for single flows of a segment without NAT that leave source-NATed

A rule is saddr/daddr (an address, a list or `@set`), proto and dport. A rule whose address
is empty (a host not in the site dict yet) is left out.

The forward chain:

1. accepts established traffic.
2. drops a segment's addresses arriving on any other interface.
3. jumps to `<name>_out`, where allowed connections go on.
4. jumps to `<name>_in`, which accepts.

So a connection between two segments passes both. The input chain works the same way with
`<name>_host`. Each gateway address answers only on its own interface. Every segment
chain ends in a counted drop.

Sets are static, CIDR intervals, or fed from DNS by a timer (`segments-set-refresh@<set>`).
A DNS-fed set takes only public unicast A records and keeps each for a while. A failed,
empty or oversized lookup changes nothing.

The ruleset is checked with `nft -c`, shown with addresses masked, and applied under a
120 s rollback. It loads at boot before the network and the guests
(`segments-firewall.service`). The lab SNAT, the IPTV DNAT and NetBird's rules are separate
and unchanged. The enclave is the first segment. The VLANs are added as more entries.

The enclave's rules are `pve_enclave_segment` in
`ansible/roles/pve_enclave/defaults/main.yml`:

| Direction | Allowed |
|---|---|
| Into the enclave | Caddy (the `apps` lab address) to Vault 8200 and Vaultwarden 8080. On `apps`, only Caddy's own network may use it (see below). Operators to Vault 8200, and SSH and ping on both VMs. |
| Out of the enclave | Vaultwarden only: DNS to Pi-hole, and the SMTP port to the set `enclave_smtp_relay`, source-NATed to the host's home address. That is the only translated flow. Vault: nothing. |
| To the host | NTP and the apt cache on the gateway address, and ping. Vaultwarden also reaches the Ceph S3 gateway (backups). |

Operators are the operator's own devices only (`inventory/group_vars/all/enclave.yml`):

- the Mac's LAN /32s (`site.admin_sources`) and the operator's NetBird peers
  (`site.admin_vpn_sources`)
- or only the NetBird peers, with `site.enclave.vpn_only: true`

Each operator is a single address (/32). Wider prefixes are refused. Every address of
every host in the site dict is dropped before those rules: the VMs, their lab and home
addresses, and the Proxmox host's. So no VM is an operator, monitoring included (there are
no scrape rules).

No VM reaches the enclave apart from that gateway path. The Proxmox host itself is not
filtered on its way in. Its own connections (Ansible's SSH jump through the host, the
operator path) are not forwarded traffic. From the enclave, the host offers only NTP, the
apt cache and, for Vaultwarden, the Ceph S3 gateway.

On `apps`, Caddy shares its lab address with every other container and the host. The
Proxmox host cannot tell Caddy's connections apart, so `apps` decides:

- The nftables table `inet anvil_gateway_guard` (role `caddy`, `tasks/enclave_guard.yml`)
  lets only Caddy's own network, `caddy_gateway`, open connections to Vault's and
  Vaultwarden's ports. `gateway-guard.service` loads it at boot, before Docker.
- That network is pinned in compose. Its subnet comes from
  `site.hosts.apps.gateway_subnet` and its bridge is always `br-caddygw`.
  `tasks/gateway_net.yml` checks that the subnet overlaps nothing. It replaces a network
  that differs, which recreates Caddy once.
- Caddy is the network's only member and its default route (`gw_priority`).
- The guard matches both the bridge and the subnet, so no other or recreated network can
  inherit the admitted addresses.
- Replies (Pi-hole's DNS answers to Vaultwarden) pass as established. The guard drops
  everything else from that VM to the enclave, other containers and the host included.
- Docker does not require the guard, so a failed guard never keeps Pi-hole down.
- In Caddy, the `pass` and `vault` routes (`caddy_admin_only_routes`) answer only the same
  operator addresses, matched on the real client address. Any other client gets 403.

NetBird has two routing peers for the lab's /16:

| Routing peer | Masquerade |
|---|---|
| The Proxmox host | Only after its forward chain |
| The `netbird` VM | No |

Both keep a peer's own address up to the enclave firewall. So the operator's peers are
listed by address, and no VM is admitted. See [NetBird](setup.md#netbird) for the routes
and access policy that make this reliable.

The mail hole:

- `smtp_host` and `smtp_port` come from `kv/homelab/apps/vaultwarden`. Without an SMTP
  login in Vault, the set stays empty.
- Every 10 minutes, the timer resolves the host through Pi-hole, the resolver Vaultwarden
  uses. It keeps each address for 24 h.
- The set holds at most 64. An answer that would not fit next to the kept ones replaces
  the set (never more than 64, nothing but the answer).
- No expected-range list (`refresh.expect`) is set for it. The relay answers from a large
  shared cloud address pool, so a published range would not narrow anything.

Not done: Vaultwarden may ask Pi-hole for any name, not only the relay's. That is a narrow
DNS channel out through Pi-hole's own recursion. Closing it needs a Pi-hole client group
for Vaultwarden that allows only the relay's name, or a resolver of its own. Neither is
managed here yet.

The lab SNAT rule on the host also matches lab-to-enclave traffic. So the enclave VMs see
lab clients, Caddy included, as the host's home address. The firewall decides on the real
source, before that translation.

### Turning on VPN-only

`site.enclave.vpn_only: true` admits only the NetBird peers in `site.admin_vpn_sources`,
at the enclave firewall and in Caddy's `pass` and `vault` routes. The Mac's LAN /32s no
longer count. A LAN address proves nothing on this network. The lab and home share one L2
segment, so any VM or home device can take over the Mac's addresses, ARP included.

Do these steps in order:

1. Do the NetBird dashboard steps ([setup.md](setup.md#netbird)):
    - the `operator` group with only your devices
    - the access policy without the runner peers
    - the enclave network, routed through the Proxmox host
    - the `apps` home address as a /32 route through the Proxmox host, with masquerade off
2. Clear the Mac's static enclave route, so the enclave is reached over NetBird only:
   `sudo networksetup -setadditionalroutes "Wi-Fi"` with no further arguments.
3. At home, with Wi-Fi on and NetBird up, check that both addresses go through the NetBird
   interface (a `utun` device), not Wi-Fi:

   ```sh
   route -n get <vault-enclave-address>
   route -n get <apps-home-address>
   ```

   It is unverified whether NetBird installs a /32 inside the Mac's own home subnet. The
   `apps` home address is in that subnet, so the Wi-Fi route may win. Test this at home
   before the switch. If either answer names the Wi-Fi interface, stop here.
4. Over NetBird, check that the Mac reaches `https://pass.<gateway-domain>` (200, not 403)
   and Vault (`vault status` with `vault-ip`, or `HOMELAB_VAULT_ADDR`). Check it at home,
   and also away from home or with Wi-Fi off.
5. Set `enclave: {vpn_only: true}` in `kv/homelab/site` with a CAS write, as in
   [Adding a service behind the gateway](usage.md#adding-a-service-behind-the-gateway).
6. Run `make enclave ARGS="--tags firewall"` and `make vm HOST=apps ARGS="--tags caddy"`.

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

Symptom: after a reboot, no VM runs. `systemctl status pve-guests` shows that its
`ExecStartPre` (`nft list table inet segments`) failed. `systemctl status segments-firewall`
shows why (`nft -f /etc/segments/segments.nft`). This is deliberate. Without the table,
the segments would be open.

1. Fix the table.
    - Read the error: `nft -c -f /etc/segments/segments.nft`.
    - Repair the file, or copy the newest
      `/var/backups/pve-network/segments.nft.<epoch>.file` back.
    - Run `nft -f /etc/segments/segments.nft` and check `nft list table inet segments`.
    - Run `systemctl start segments-set-refresh@enclave_smtp_relay`. The table loads with
      the DNS-fed set empty. Without this, the mail relay waits up to 10 minutes for the
      timer.
2. Start the guests. `pve-guests` refuses manual starts (`RefuseManualStart=yes`, see
   `systemctl cat pve-guests`). Use `pvesh create /nodes/localhost/startall` for all, in
   startup order, or `qm start <vmid>` for one.
3. Rerun `make enclave`, so the file, the unit and the check match the repo again.

Never start guests by hand while the table is missing. The enclave would be reachable from
every VM and the home network, and its VMs could reach anything routed. If you must (DNS
for the home), start only `apps` with `qm start`. Fix the table before you start `vault`
and `vaultwarden`.

After a manual start, shutdown is not clean:

- The failed boot leaves `pve-guests` failed, and a failed unit has nothing to stop.
- At the next shutdown or reboot, Proxmox's stopall does not run. The guests started by
  hand (`startall` or `qm start`) are hard-stopped. That risks Vault's Raft store and
  Vaultwarden's sqlite database.
- So after fixing the table, reboot the host. That boot starts `pve-guests` normally, and
  its stop runs stopall at the next shutdown.
- If guests were started by hand and stay up, run `pvesh create /nodes/localhost/stopall`
  before any later shutdown or reboot.

Never `systemctl restart` or `stop` a unit that `pve-guests` is ordered against. Never link
one to it with Requires, RequiredBy, Requisite, BindsTo, PartOf, Conflicts or
PropagatesStopTo. A restart of such a unit stops every guest. It happened once.

### Apt cache and time

`apt-cacher-ng` on the host listens on the gateway address only. It serves the Debian and
Ubuntu archives and nothing else: `ForceManaged`, only those remaps, port 80 upstreams, no
CONNECT tunnels, IPv4 only.

- The enclave VMs use it as their apt proxy. The role `enclave_guest` sets it, and so does
  the cloud-init vendor data `local:snippets/enclave-vendor.yaml` from the first boot.
- HTTPS repositories are not reachable. So Docker comes from Ubuntu's archive, and Vault's
  HashiCorp repository is removed.
- The host's chrony answers NTP on the gateway address for the enclave subnet. The VMs use
  systemd-timesyncd with that server only.

### Vault on the enclave

- **NICs.** The vault VM's enclave NIC (hot-plugged, MAC `site.hosts.vault.enclave_mac`)
  is its only working one. Its first NIC, on the lab network, is retired
  (`site.hosts.vault.lab_nic_retired: true`, 2026-10-22). Its link is down in Proxmox
  (`disconnected`), and the netplan keeps it with no address. `site.hosts.vault.ip` is the
  enclave address. `lab_ip` and `mac` record the old NIC.
- **Netplan.** `guest_base` owns it in enclave mode, under a timed rollback. The enclave
  NIC has the default route and no DNS. cloud-init no longer writes the network.
- **Listener.** Vault listens on the enclave address only. The `api_addr`, `cluster_addr`
  and the certificate's address are the enclave one.
- **Reaching it.** Ansible connects through the Proxmox host (`group_vars/enclave.yml`).
  The Mac reaches it in one of two ways:
    - through the gateway, `https://vault.<gateway-domain>`, from operator addresses only
    - directly, once the Mac has the enclave route and the Keychain `vault-ip` is the
      enclave address ([setup.md](setup.md#not-managed-here))

    When the enclave address does not answer (away from home, on the VPN),
    `scripts/env.sh` switches to the gateway by itself. To pick the gateway by hand:

    ```sh
    export HOMELAB_VAULT_ADDR=https://vault.<gateway-domain>
    export HOMELAB_VAULT_CACERT="$(python3 -m certifi)"   # the gateway's certificate is public
    ```

    `make vault-unseal`, `make backup`, the Ansible lookups and `make tf-plan` all work
    that way. Caddy's own trust in Vault always uses Vault's CA file, never
    `$VAULT_CACERT`.

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

## VLANs

The SDN VLAN zone `vlanzone` on `vmbr0` (`terraform/sdn.tf`) has three vnets. The
Proxmox host routes for them. `make vlans` sets them up (role `pve_vlans`).

| VLAN | Vnet | Reaches | Blocked from |
|---|---|---|---|
| Lab (untagged) | `vmbr0` | everything, as before | nothing |
| 10 | `servers` | the internet, Pi-hole DNS, the host's NTP | the lab, cameras, personal, the home network, the enclave |
| 20 | `cameras` | Pi-hole DNS, the host's NTP, the internet while `cameras_internet` is true | everything else |
| 30 | `personal` | the internet, the service gateway's web ports (80 and 443), Pi-hole DNS | cameras, servers, the lab, the Proxmox UI and SSH, the enclave |

VLAN 30 reaches the gateway's ports, but not every page behind them. The infrastructure
pages and the enclave's pages answer 403 to it, Proxmox included
([Service gateway](#service-gateway)).

Lab hosts open connections into every VLAN. Nothing else does: not the home network, not
the enclave and not another VLAN.

### How it is built

- **Firewall.** Each VLAN is a segment of the routed segments' table `inet segments`
  ([Firewall: routed segments](#firewall-routed-segments)), next to the enclave.
    - The data is in `ansible/inventory/group_vars/proxmox.yml` (`vlans`, `vlan_segments`,
      `vlan_sets`). Each `vlans` entry names its own egress profile (`dns`, `web`,
      `internet`).
    - Each VLAN has `nat: true`, so its traffic leaves with the host's address.
    - "The internet" means any address outside the set `vlan_nonpublic` (private, shared,
      link-local, documentation, multicast and reserved ranges). That set covers the lab,
      the home network, the NetBird range, the enclave and the other VLANs. `make vlans`
      checks that, and that no two of those networks overlap.
    - Each VLAN has `strict_source`. The first rule of its `_out` chain drops any source
      outside its subnet, so a device cannot send with a forged address.
    - The VLANs do not change the enclave's own rules, sets and operator list.
- **Gateways.** The host's address on each vnet (`site.sdn.subnets.<vnet>.gateway`) is in
  `/etc/network/interfaces.d/vlans`. ifupdown2 merges it into SDN's stanza for the vnet.
  A change goes through the same 120 s rollback as `make host-network`.
- **DHCP.** One dnsmasq per VLAN (`vlan-dhcp@<vnet>`), DHCP only, bound to its vnet alone.
    - It hands out `site.sdn.subnets.<vnet>.dhcp_range`, the gateway as router and NTP
      server, and Pi-hole's lab address as DNS.
    - The package is `dnsmasq-base`, which has no service of its own.
    - The home router stays the only DHCP server of the home network.
    - The unit runs only while its vnet exists (bound to the device). It starts only when
      the table `inet segments` is loaded, so no lease is handed out without the firewall.
- **NTP.** One small chronyd per VLAN (`vlan-ntp@<vnet>`) answers on that gateway only.
    - It serves the host clock and never sets it. The host's own chronyd keeps the clock
      and still answers only the enclave.
    - Chrony takes one bind address per process. That is why each VLAN has its own.
    - It also starts only with the table loaded.
    - Neither unit is linked to `pve-guests` in any way.
- **Trunk.** `vmbr0`'s uplink carries VLANs 10, 20 and 30 tagged (`bridge-vids`, from
  `make host-network`). The lab and home networks stay untagged. The switch side is
  `make switch`, see [cisco-switch.md](cisco-switch.md).

### Changing it

- `cameras_internet: false` in `inventory/group_vars/proxmox.yml` leaves VLAN 20 with DNS
  and NTP only. Then run `make vlans`. VLAN 20 stays NATed either way. Its DNS queries
  reach Pi-hole with the host's address, which Pi-hole answers and can reply to.
- To bring VLANs up one at a time, name them:
  `make vlans ARGS="-e '{\"pve_vlans_enabled\": [\"servers\"]}'"`. The ones not named
  lose their gateway, DHCP and NTP. The firewall keeps all three.
- Dry run first: `make vlans ARGS="--check --diff"`.

### Checking it

On the Proxmox host:

```sh
ip -br -4 addr show servers
ss -Hlunp | grep -E 'dnsmasq|chronyd-vlan'
nft list chain inet segments servers_out
cat /var/lib/vlan-dhcp/servers.leases
```

Each dnsmasq socket shows as `0.0.0.0%<vnet>:67`. Each `chronyd-vlan` socket is its gateway
on port 123.

### Limits

- Pi-hole and Caddy see VLAN clients as the host's address, because of the NAT. Pi-hole's
  per-client statistics lump them together.
- Lab clients reach VLAN devices with the host's home address as their source. The lab
  SNAT rule matches that traffic too. The firewall still decides on the real source.
- Pi-hole's rate limit counts every VLAN client and every masqueraded NetBird peer as one
  client, the host. It is 5000 queries per 60 s for that reason ([Pi-hole](#pi-hole)). A
  later improvement: let the VLANs' DNS skip the masquerade, so Pi-hole sees and limits
  each client.
- IPv6 is not routed for the VLANs or the enclave. Each segment bridge still has a
  link-local `fe80::` address, and SSH and the Proxmox UI listen on IPv6 too. So the first
  rule of the segment firewall, in `input` and `forward`, drops every IPv6 packet on a
  segment's interface, before any other rule. A guest in a segment cannot reach the host
  over IPv6, even through a rule that has no address in it.
- Devices on the same VLAN reach each other directly (layer 2). The firewall sees only
  traffic that the host routes. That holds while `net.bridge.bridge-nf-call-iptables` is
  0, as it is today. The Proxmox firewall sets it to 1 when it is turned on. Then bridged
  frames pass the segment chains too, and traffic inside a VLAN would be dropped.
- Frigate's VLAN 20 NIC, when it comes, puts Frigate on the cameras' layer 2 segment. The
  cameras then reach every port Frigate listens on there, without the host's firewall in
  between. Frigate must listen only where it needs to and must not route between its NICs.
  A Proxmox NIC with `firewall=1` sits behind an `fwbr` bridge, which the segment rules do
  not name.
- The cameras are on the home Wi-Fi today, so VLAN 20 isolates nothing yet. The plan for
  them is in [cisco-switch.md](cisco-switch.md#cameras-on-vlan-20). Frigate gets its VLAN 20
  NIC only when the access point exists.

## Ceph

`make ceph` builds a one-disk Ceph cluster on `pve`: a monitor, a manager, one OSD and
pool size 1. It also adds:

- a RADOS Gateway on port 7480 of the host's address
- the S3 user `terraform` and the bucket `tfstate`, for Terraform state
- the S3 users `filestash` (read-only), `vaultwarden-backup` and `authentik-backup`, whose
  keys go into Vault

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

A disk that is already an OSD is left alone: the Ceph VG, LVM on the disk and
`ceph-volume` agree. If those disagree, the play stops. `make ceph ARGS="--check --diff"`
runs the checks and lists what would run.

The `terraform` user's S3 keys are written to `/root/.ceph-rgw-terraform.json` (mode 600)
on the host. [First build](setup.md#first-build) copies them into the Keychain.

### Ceph dashboard

The dashboard is at `https://<proxmox-address>:8443/`, with a self-signed certificate. Log
in as `admin` with the password in `/root/.ceph-dashboard-admin` (mode 600) on the host.
To keep a copy in the Keychain:

```sh
source scripts/env.sh && source scripts/keychain-lib.sh
ssh root@"$PVE_IP" cat /root/.ceph-dashboard-admin | kc_store_stdin ceph-dashboard-password
```

The Object Gateway zone and multisite pages return 500 on Proxmox. The manager drops
supplementary groups and cannot read `/etc/ceph/ceph.conf`, which is a link into pmxcfs.
The bucket and user pages work. To browse objects, use Filestash or the aws CLI.
