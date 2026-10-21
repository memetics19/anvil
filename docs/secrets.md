# Secrets in Vault

Secret values live only in Vault (KV v2, mount `kv`), at `kv/homelab/<host>/<app>`.
This file lists names, never values. `scripts/import-secrets.sh` copies the values from
the live VMs (piped over SSH straight into `vault kv put|patch <path> <key>=-`) and checks
each one by SHA-256. Rerun it any time: matching keys are left alone, a different value is
refused unless `--force`, and `--verify` only compares.

Ansible reads these paths with the `ansible-read` policy (`kv/data/homelab/*`).
`kv/homelab/site` (site addresses, domain, MACs) is described in `site/site.example.yml`.

## Imported from the live VMs

| Vault path | Key | Source on the VM | What it is for |
|---|---|---|---|
| `kv/homelab/frigate/cloudflared` | `token` | `--token` in the `cloudflared` systemd unit | Cloudflare tunnel connector |
| `kv/homelab/netbird/cloudflared` | `token` | `--token` in the `cloudflared` systemd unit | Cloudflare tunnel connector |
| `kv/homelab/ragnarok/cloudflared` | `token` | `--token` in the `cloudflared` systemd unit | Cloudflare tunnel connector |
| `kv/homelab/frigate/frigate` | `front_door_rtsp_url` | `/home/config/config.yml`: `cameras.front_door.ffmpeg.inputs[0].path` (also `go2rtc.streams.front_door`, same value) | Camera stream URL, credentials included |
| `kv/homelab/frigate/frigate` | `rtsp_user` | user part of that URL | Camera RTSP login |
| `kv/homelab/frigate/frigate` | `rtsp_password` | password part of that URL | Camera RTSP login |
| `kv/homelab/frigate/frigate` | `jwt_secret` | `/home/config/.jwt_secret` (whole file) | Frigate auth session signing key |
| `kv/homelab/frigate/frigate` | `compose_rtsp_password` | `/home/docker-compose.yml`: `services.frigate.environment.FRIGATE_RTSP_PASSWORD` | Set in compose; the running container has it empty and `config.yml` does not use it |
| `kv/homelab/frigate/frigate-notify` | `gotify_token` | `/home/docker-compose.yml`: `services.frigate-notify.environment.GOTIFY_TOKEN` (same value as `token` in `/home/notify-config.yaml` and `/home/frigate-notify/notify-config.yml`) | Gotify app token frigate-notify pushes with |
| `kv/homelab/netbird/pulse` | `admin_token` | `/home/ubuntu/pulse/.env`: `PULSE_ADMIN_TOKEN` | Pulse admin token (not passed to the running container by the prod compose file) |

The three cloudflared units currently run the same tunnel token.

## Pending (user)

| Vault path | Key | What it is for | Who creates it |
|---|---|---|---|
| `kv/homelab/pve/netbird` | `setup_key` | NetBird enrolment of the Proxmox host | operator: reusable setup key from the NetBird dashboard |
| `kv/homelab/netbird/netbird` | `setup_key` | NetBird enrolment of the netbird VM | operator: reusable setup key from the NetBird dashboard |

Setup keys cannot be read back from an enrolled client, so these are new keys, written with
`vault kv put -mount=kv homelab/<path> setup_key=-` (value on stdin).

## Looked at, nothing to import

| Host | Where | Why there is no Vault path |
|---|---|---|
| frigate | mosquitto (`/home/mosquitto/config/mosquitto.conf`) | Anonymous listener, no password file |
| frigate | gotify | No secret in config or env; the admin login and app tokens are in the gotify database |
| frigate | nginx | No basic auth, no TLS key |
| frigate | homeassistant | Not running; `configuration.yaml` uses no `!secret` |
| frigate | Frigate users | Password hashes are in `frigate.db` (app data) |
| netbird | ntfy | Users and tokens are in its `auth.db` (app data); compose env holds no secret |
| netbird | pulse `RESEND_API_KEY`, `SLACK_WEBHOOK_URL` | Empty in `.env` and in the running container |
| netbird | redis | No `requirepass`, no ACL file |
| netbird | NetBird client state (`/var/lib/netbird/default.json`) | Peer identity keys; a rebuilt host enrols again with a setup key |
| ragnarok | ARR compose (`/home/ubuntu/docker-compose.yaml`) | Env holds only ids, ports, timezone, log settings |
| ragnarok | qbittorrent, privoxy, jackett, dispatcharr, flaresolverr | No secret in compose env; app logins and API keys sit in each app's config dir (app data) |
| ragnarok | iptv-epg | No env file or secret |
