# Secrets in Vault

Secret values live only in Vault (KV v2, mount `kv`) at `kv/homelab/<host>/<app>`. This
file lists names, never values. Ansible reads them with the `ansible-read` policy
(`kv/data/homelab/*`). The site dict at `kv/homelab/site` is described in
[`site/site.example.yml`](../site/site.example.yml).

To write or read a value by hand, see [Secrets in Vault](usage.md#secrets-in-vault).

## Imported from the live VMs

`scripts/import-secrets.sh` reads each value on the VM and pipes it over SSH straight into
`vault kv put|patch <path> <key>=-`, then checks it by SHA-256. You can rerun it any time:
matching keys are left alone, a different value is refused unless you pass `--force`, and
`--verify` only compares.

| Vault path | Key | Source on the VM | Used for |
|---|---|---|---|
| `kv/homelab/frigate/cloudflared` | `token` | `/etc/cloudflared/token` (0600 root), read with `--token-file` | Cloudflare tunnel connector |
| `kv/homelab/netbird/cloudflared` | `token` | `/etc/cloudflared/token` (0600 root), read with `--token-file` | Cloudflare tunnel connector |
| `kv/homelab/ragnarok/cloudflared` | `token` | `/etc/cloudflared/token` (0600 root), read with `--token-file` | Cloudflare tunnel connector |
| `kv/homelab/frigate/frigate` | `front_door_rtsp_url` | `/home/config/config.yml`: `cameras.front_door.ffmpeg.inputs[0].path`, same as `go2rtc.streams.front_door` | Camera stream URL, with credentials |
| `kv/homelab/frigate/frigate` | `rtsp_user` | user part of that URL | Camera RTSP login |
| `kv/homelab/frigate/frigate` | `rtsp_password` | password part of that URL | Camera RTSP login |
| `kv/homelab/frigate/frigate` | `jwt_secret` | `/home/config/.jwt_secret` (whole file) | Frigate session signing key |
| `kv/homelab/frigate/frigate` | `admin_password` | generated once by Frigate (`auth.reset_admin_password`, 2026-10-21) and piped from its log into Vault | Frigate login for `admin`, which guards the public hostname |
| `kv/homelab/frigate/frigate` | `compose_rtsp_password` | `/home/docker-compose.yml`: `services.frigate.environment.FRIGATE_RTSP_PASSWORD` | Stale, kept for reference. Not the camera login. |
| `kv/homelab/frigate/frigate-notify` | `gotify_token` | `/home/frigate-notify/config.yml`: `alerts.gotify.token` (was `GOTIFY_TOKEN` in `/home/docker-compose.yml`) | Gotify app token for frigate-notify |
| `kv/homelab/netbird/pulse` | `setup_token` | `make vm HOST=netbird` (pulse role, `openssl rand`), into `/opt/pulse/.env`: `PULSE_SETUP_TOKEN` | Pulse's first-run `/setup` asks for it, so only you can claim a fresh instance. An installed Pulse ignores it. The old `admin_token` key is no longer read. |
| `kv/homelab/apt/signing` | `private_key`, `public_key`, `fingerprint` | `/opt/apt-repo/gnupg` on `netbird` (the private key, imported) | The apt repository's signing key, made once by `scripts/apt-key-init.sh`. No passphrase: the VM signs unattended. |

The three cloudflared units currently run the same tunnel token.

## Created by the roles

Ansible generates these and pipes them straight into Vault, never displaying them or
writing them to a file. Each write is checked by reading the SHA-256 digests back with
`scripts/vault-kv-digests.sh`. Each role passes it the mount it writes to (its
`*_vault_mount`, `kv` by default), so a role whose mount is changed reads and writes the
same place. A generated secret goes to an empty path by `vault kv put` and to a path that
already has keys by `vault kv patch`, which keeps the other keys. Pulse's put also has
`-cas=0`, so Vault refuses it if the path exists after all.

| Vault path | Key | Created by | Used for |
|---|---|---|---|
| `kv/homelab/ragnarok/filestash` | `s3_access_key`, `s3_secret_key` | `make ceph` (S3 user `filestash`) | Read-only S3 user for Filestash |
| `kv/homelab/ragnarok/filestash` | `admin_password` | `make vm HOST=ragnarok` (filestash role, `openssl rand`) | Filestash login for `admin` and its admin console. Filestash stores a bcrypt hash. |
| `kv/homelab/ragnarok/threadfin` | `admin_password` | `make vm HOST=ragnarok` (iptv role, `openssl rand`) | Threadfin login for `admin`. Threadfin stores an HMAC hash in `authentication.json`. |
| `kv/homelab/apps/pihole` | `web_password` | `make vm HOST=apps` (pihole role, `openssl rand`) | Pi-hole web UI and API login, passed in `/opt/pihole/pihole.env` (mode 600) |
| `kv/homelab/apps/pihole` | `app_password` | `make vm HOST=apps` (pihole role, from Pi-hole's `/api/auth/app`, hash set live) | Pi-hole application password for the Homepage widget |
| `kv/homelab/pve/homepage` | `token_secret` | `make host ARGS="--tags homepage"` (pve_host role, `pveum user token add`) | Read-only Proxmox token `homepage@pve!homepage` (PVEAuditor, privilege-separated) for Homepage |
| `kv/homelab/ragnarok/arr` | `sonarr_api_key`, `radarr_api_key`, `prowlarr_api_key` | `make vm HOST=ragnarok ARGS="--tags homepage"` (arr_stack role, read from each app's `config.xml` and compared by SHA-256) | Homepage widgets. The apps keep their own copy. |
| `kv/homelab/apps/vaultwarden` | `admin_token` | `make vm HOST=apps` (vaultwarden role, `openssl rand`) | Vaultwarden admin page (`/admin`) |
| `kv/homelab/apps/vaultwarden` | `admin_token_hash` | `make vm HOST=apps` (vaultwarden role, `argon2` on the VM with the token on stdin) | The Argon2id hash of that token, the only form Vaultwarden gets (`/opt/vaultwarden/vaultwarden.env`, mode 600) |
| `kv/homelab/netbird-srv` | `relay_secret`, `datastore_key`, `idp_session_key` | `make vm HOST=netbird` (netbird_server role, `openssl rand`) | The self-hosted NetBird server: the relay's shared secret, the store's encryption key and the identity provider's session cookie key, rendered into `/opt/netbird-server/config.yaml` (mode 600) |
| `kv/homelab/netbird-srv` | `owner_email`, `owner_password` | `make vm HOST=netbird` (netbird_server role, `site.email` and `openssl rand`) | The self-hosted dashboard's owner login (`https://<netbird_domain>`) |
| `kv/homelab/<box>/install` | `root_password` | `make provision-iso NAME=<box>` (generated once, never printed) | The root password of a server installed with the automated installer. Only its hash goes into the ISO. |
| `kv/homelab/netbird-srv` | `api_token` | `make vm HOST=netbird` (netbird_server role, from the server's setup API, renewed before it expires) | The owner's personal access token, for the role's API calls |
| `kv/homelab/apps/vaultwarden` | `smtp_username`, `smtp_password`. Optional: `smtp_host`, `smtp_port`, `smtp_security`, `smtp_from` | you (`vault kv patch ... <key>=-`) | Vaultwarden mail (a Gmail App Password or a relay's API key), rendered into `/opt/vaultwarden/vaultwarden.env` |
| `kv/homelab/apps/vaultwarden-backup` | `s3_access_key`, `s3_secret_key` | `make ceph` (S3 user `vaultwarden-backup`) | Nightly Vaultwarden backup upload and `make backup`. Owns only the bucket `vaultwarden-backups`. |
| `kv/homelab/frigate/frigate` | `homepage_password` | `make vm HOST=frigate ARGS="--tags homepage"` (frigate_stack role, `openssl rand`, set through Frigate's API) | Frigate viewer login `homepage` for the Homepage widget |

## Added by you

| Vault path | Key | Used for |
|---|---|---|
| `kv/homelab/pve/apt-cacher-ng` | `admin_password` | `make enclave` (pve_enclave role, `openssl rand`) | Login `admin` for the apt cache's report page and maintenance jobs (AdminAuth) |
| `kv/homelab/pve/netbird` | `setup_key` | Enrolling the Proxmox host in NetBird |
| `kv/homelab/pve/idrac` | `username`, `password` | The current server's BMC login. Only read only checks use it. |
| `kv/homelab/<box>/bmc` | `username`, `password` | The BMC login of a server to install ([provisioning.md](provisioning.md)) |
| `kv/homelab/netbird/netbird` | `setup_key` | Enrolling the `netbird` VM. The netbird_peer role reads it only for a client that needs a login. |

Create both as reusable setup keys in the NetBird dashboard. An enrolled client can't give
its key back, so these are new keys. Write each from stdin:
`vault kv put -mount=kv homelab/<path> setup_key=-`.

## Not imported

- Services with no secret in their config. On `frigate`: Mosquitto, Gotify, nginx and Home
  Assistant. On `netbird`: ntfy and Redis. On `ragnarok`: qBittorrent, Jackett,
  FlareSolverr and iptv-epg. The ARR API keys are copied for the dashboard only.
- App data, such as user databases and app config directories, stays with each app.
- NetBird client state. A rebuilt host enrolls again with a setup key.
