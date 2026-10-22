# Setup

How to go from a bare Proxmox VE install to a running lab, and how to rebuild it on a new
box from backups. Day-to-day work is in [usage.md](usage.md).

Placeholders: `<proxmox-address>` (the host's lab address, Keychain `pve-ip`),
`<vault-address>`, `<apps-address>`, `<apps-home-address>`, `<domain>` and
`<gateway-domain>` (see [Service gateway](services.md#service-gateway)).

## Operator machine

The operator machine is a Mac. Secrets and bootstrap values live in its Keychain, and the
scripts read them with `security`.

These versions are pinned in the repo:

| Tool | Version | Pinned in |
|---|---|---|
| Terraform | >= 1.10 | `terraform/versions.tf` |
| bpg/proxmox provider | 0.117.0 | `terraform/versions.tf` |
| gitleaks | 8.28.0 | `.github/workflows/ci.yml`, `.pre-commit-config.yaml` |
| ansible-lint | 25.9.2 | `.pre-commit-config.yaml` |
| yamllint | 1.37.1 | `.pre-commit-config.yaml` |
| Vault server | 2.2.0-1 | `vault_server_version` in `ansible/roles/vault_server/defaults/main.yml` |

The rest is unpinned. Install everything with:

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/terraform hashicorp/tap/vault ansible ansible-lint \
  gitleaks tflint yamllint jq pre-commit sshpass awscli age
ansible-galaxy collection install -r ansible/requirements.yml -p ~/.ansible/collections
# hvac for the community.hashi_vault lookup, in the Python that runs Ansible
"$(brew --prefix ansible)/libexec/bin/python" -m pip install hvac
pre-commit install
```

Every Ansible target checks for `hvac` first and prints the `pip install` command if it is
missing. `scripts/env.sh` reads the Keychain copy of the site dict with `python3` and
PyYAML, or with the system Ruby when PyYAML is missing, so nothing else is needed.

You also need an SSH key pair at `~/.ssh/id_ed25519`. `make bootstrap-ssh` installs the
public key on the Proxmox host and the adopted guests. Terraform puts it into cloud-init for
the `vault` and `apps` VMs (`ssh_public_key_path` in `terraform/variables.tf`).

## Keychain items

All items use service `homelab`. `scripts/env.sh` reads them and exports most as
environment variables. It skips missing items, so it works at every stage of the
bootstrap. Only `pve-ip` is required.

| Account | Holds | Created by | Read by |
|---|---|---|---|
| `pve-ip` | Proxmox host lab address | you | `env.sh` (`PVE_IP`, `PROXMOX_VE_ENDPOINT`, the S3 backend) |
| `vault-ip` | Vault VM address, its enclave address `site.hosts.vault.ip`. The Mac needs the enclave route. | you | `env.sh` (`VAULT_ADDR`) |
| `site-bootstrap` | Bootstrap copy of the site dict | you, later `scripts/site-to-keychain.sh` | `env.sh`, the Ansible inventory, `scripts/site-to-vault.sh` |
| `pve-root-password` | Proxmox root password | you | `make bootstrap-ssh` |
| `vm-sudo-password` | Password of the `ubuntu` user on the guests | you | `make bootstrap-ssh`, `env.sh` (`ANSIBLE_BECOME_PASSWORD`) |
| `pve-api-token` | Terraform's Proxmox API token | `make host` | `env.sh` (`PROXMOX_VE_API_TOKEN`) |
| `ceph-osd-disk-id` | `/dev/disk/by-id/` name of the Ceph OSD disk | you | `make ceph`, unless `site.pve.ceph_osd_disk_id` is set |
| `ceph-s3-access-key`, `ceph-s3-secret-key` | S3 keys for the state bucket | you, after `make ceph` | `env.sh` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) |
| `ceph-dashboard-password` | Ceph dashboard `admin` password | you, after `make ceph` (optional) | nothing. A copy is for you |
| `vault-init-json` | Vault unseal keys and root token | `scripts/vault-init.sh` | `env.sh` (`VAULT_TOKEN`), `scripts/vault-unseal.sh` |
| `backup-age-recipient` | age public key for backups | `scripts/backup-key-init.sh` | `scripts/backup.sh`, the `vaultwarden` role |
| `backup-age-identity` | age private key for backups | `scripts/backup-key-init.sh` | `scripts/backup-restore-tfstate.sh`, `make vaultwarden-drill` |

`scripts/vault-init.sh` also creates and deletes a throwaway `vault-init-probe` item to
test the Keychain before it initializes Vault.

Add the plain values yourself:

```sh
security add-generic-password -s homelab -a pve-ip -w <proxmox-address>
security add-generic-password -s homelab -a vault-ip -w <vault-address>
security add-generic-password -s homelab -a ceph-osd-disk-id -w <by-id-name>
security add-generic-password -s homelab -a pve-root-password -w
security add-generic-password -s homelab -a vm-sudo-password -w
```

With `-w` last, `security` prompts for the password, which keeps it off the command line.
Add `-U` to replace an existing item.

## The site dict

Addresses, MACs, VM IDs, the domain and the e-mail address live in one `site` dict.
[`site/site.example.yml`](../site/site.example.yml) shows its structure.

Ansible and Terraform read it from Vault, `kv/homelab/site` (mount `kv`, key `site`),
which is the canonical copy. Before `VAULT_TOKEN` is set, or while that path does not
exist, they read the Keychain item `site-bootstrap` instead. Each run prints which source
it used and warns when the two copies differ.

`scripts/site-source.sh` makes that choice and fails closed. If `VAULT_TOKEN` is set and
Vault is sealed, unreachable or rejects the token, the run stops instead of falling back
to the Keychain. Set `HOMELAB_SITE_SOURCE=keychain` to use the Keychain copy on purpose.
`make vault` falls back on its own, with a warning, so it can repair a broken Vault.

Terraform checks more than the example file shows. The plan stops with a validation error
until the dict has:

- `sdn.subnets.servers`, `sdn.subnets.cameras` and `sdn.subnets.personal`, each with `cidr`
  and `gateway`
- `sdn.enclave` with `subnet` and `gateway`
- a quoted MAC and a numeric `vmid` for every host

### Create the bootstrap copy

Write the dict as YAML with a top-level `site:` key, outside the repo. Store it compressed,
the way `scripts/site-to-keychain.sh` does, because `security -i` only reads lines under
4000 bytes:

```sh
source scripts/keychain-lib.sh
printf 'gz64:%s' "$(gzip -9n < ~/site.yml | base64 | tr -d '\n')" | kc_store_stdin site-bootstrap
rm ~/site.yml
scripts/site-keychain-read.sh | head -n 3   # check that it decodes
```

`kc_store_stdin` never overwrites an item. To replace one, delete it first with
`security delete-generic-password -s homelab -a site-bootstrap`.

### Move it into Vault

Once Vault is initialized and unsealed:

```sh
make site-to-vault    # prints "written" or "unchanged"
```

It refuses to replace a different value in Vault unless you pass `ARGS=--force`. From
then on, change the dict in Vault (see [usage.md](usage.md#adding-a-service-behind-the-gateway)).
When a run warns that the Keychain copy is stale, refresh it:

```sh
scripts/site-to-keychain.sh --yes
```

## First build

Run each step with `ARGS="--check --diff"` first, then without.

1. Install your SSH key on the Proxmox host. The guests come later.

   ```sh
   make bootstrap-ssh ARGS="--limit proxmox"
   ```

2. Set up the Proxmox host: apt repositories, packages, time and `/etc/hosts`. This also
   creates Terraform's API user and token, stores the token in Keychain `pve-api-token`,
   and enables the `import` content type on storage `local` for Terraform. Skip the
   `homepage` tag, which needs Vault.

   ```sh
   make host ARGS="--skip-tags homepage"
   ```

3. Write the host network: `/etc/network/interfaces` with the bridges, the LAN gateway and
   NAT, and the IPTV port forwards. The change has a
   [timed rollback](usage.md#safety-rails). Never run it in the same Ansible run as a
   change to the `netbird` VM.

   ```sh
   make host-network ARGS="--check --diff"
   make host-network
   ```

4. Build Ceph and the state bucket. The first real run wipes the OSD disk, so read
   [Ceph](services.md#ceph) first.

   ```sh
   make ceph ARGS="--check --diff"
   make ceph
   ```

   This run creates the `tfstate` bucket and its S3 user. The `filestash` and
   `vaultwarden-backup` users need Vault, so you rerun `make ceph` in step 7.

   Copy the state bucket's keys into the Keychain:

   ```sh
   source scripts/env.sh && source scripts/keychain-lib.sh
   keys=$(ssh root@"$PVE_IP" cat /root/.ceph-rgw-terraform.json)
   jq -r .access_key <<<"$keys" | kc_store_stdin ceph-s3-access-key
   jq -r .secret_key <<<"$keys" | kc_store_stdin ceph-s3-secret-key
   unset keys
   ```

   Copying the dashboard password is optional. See [Ceph dashboard](services.md#ceph-dashboard).

5. Run Terraform. It creates the `vault` and `apps` VMs and the SDN zone and VNets. It
   adopts `frigate`, `netbird` and `ragnarok` with the `import` blocks in
   `terraform/imports.tf`, so those VMs must already exist with their VM IDs.

   ```sh
   make tf-init
   make tf-plan     # prints the site source and runs the plan guard
   make tf-apply
   ```

6. Set up Vault:

   ```sh
   make vault                    # installs and configures Vault, leaves it sealed
   scripts/vault-init.sh         # once: 5 unseal keys and the root token go to Keychain vault-init-json
   make vault-unseal             # uses 3 of the 5 keys
   make vault-policies
   make site-to-vault
   scripts/backup-key-init.sh    # once: the age key pair for backups
   ```

   `make vault` copies Vault's CA certificate to `~/.config/homelab/vault-ca.pem`.
   `scripts/vault-init.sh` tells you how to print the unseal keys for an offline paper
   copy. Keep an offline copy of `backup-age-identity` too, because without it the backups
   cannot be read.

7. Put the secrets the roles read into Vault. [secrets.md](secrets.md) lists every path
   and key. `scripts/import-secrets.sh` copies some from the old VMs, and the roles generate
   others. You add the rest by hand (see [Secrets in Vault](usage.md#secrets-in-vault)):

   - the Cloudflare tunnel token for each tunnel host
   - `cloudflare_dns_token` in `kv/homelab/apps/caddy`, a Cloudflare API token that may
     only edit DNS in your zone
   - the NetBird setup keys
   - optionally, the Vaultwarden SMTP keys

   Then finish the steps that needed Vault:

   ```sh
   make ceph                          # S3 users for Filestash and the Vaultwarden backups
   make host ARGS="--tags homepage"   # read-only Proxmox token for the dashboard
   ```

8. Set up the secrets enclave on the Proxmox host: its firewall, the SDN apply, the apt
   cache, NTP and the cloud-init vendor data. Terraform must have created the zone and
   VNet first.

   ```sh
   make enclave ARGS="--check"
   make enclave
   ```

   Then the VLANs: their firewall, the gateway addresses on the vnets, DHCP and NTP
   ([VLANs](services.md#vlans)). `site.sdn.subnets` needs a `dhcp_range` for each.

   ```sh
   make vlans ARGS="--check --diff"
   make vlans
   ```

9. Install your key on the guests and configure them:

   ```sh
   make bootstrap-ssh ARGS="--limit guests"
   make vms ARGS="--check --diff"
   ```

   Then run the VMs one at a time. Do `apps` last, because its dashboard reads credentials
   the other roles create.

   ```sh
   make vm HOST=vault
   make vm HOST=frigate
   make vm HOST=netbird
   make vm HOST=ragnarok
   make vm HOST=apps
   ```

10. Take the first backups:

    ```sh
    make backup
    make vaultwarden-drill   # once the first nightly Vaultwarden backup exists
    ```

Then do the hand steps in [Not managed here](#not-managed-here).

## Rebuilding on a new box

This runbook has not been tested on a second server yet. You need:

- the Mac's Keychain (service `homelab`)
- `~/homelab-backups`, with `tfstate-*.json.age`, `vault-*.snap` and `vaultwarden-*.tar.age`
- the offline copies of the unseal keys and the age identity, if the Keychain is lost

The repo does not back up the disks of `frigate`, `netbird` and `ragnarok`, which hold the
media library, app databases and Frigate recordings. Restore those VMs from your own
Proxmox backups, with their old VM IDs, before you plan. Otherwise the plan shows them as
new VMs to create. Do not apply that plan.

1. Install Proxmox VE with the same addresses as before. If they change, update `pve-ip`,
   `vault-ip` and the Keychain copy of the site dict.
2. Set the new OSD disk in `ceph-osd-disk-id` or `site.pve.ceph_osd_disk_id`.
3. Run steps 1 to 4 of [First build](#first-build). The new S3 user has new keys, so
   delete the old `ceph-s3-access-key` and `ceph-s3-secret-key` items before you copy the
   new ones in.
4. Restore the Terraform state into the empty bucket, then plan and apply:

   ```sh
   source scripts/env.sh
   make tf-init
   scripts/backup-restore-tfstate.sh | jq .serial      # check the newest backup decrypts
   scripts/backup-restore-tfstate.sh | terraform -chdir=terraform state push -
   make tf-plan
   make tf-apply
   ```

   `backup-restore-tfstate.sh` takes a file name to restore an older backup. It only
   writes to stdout.

5. Restore Vault from the newest Raft snapshot. `scripts/vault-init.sh` refuses to run,
   because `vault-init-json` still holds the old keys, and the snapshot needs those keys.
   Instead, initialize a throwaway cluster, restore the snapshot over it, and unseal with
   the old keys. This is not scripted:

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

   The site dict, every secret and the old root token are now back.

6. Run `make ceph` again, so the new S3 users' keys replace the old ones in Vault. Then run
   `make host ARGS="--tags homepage"`.
7. Run steps 8 and 9 of [First build](#first-build). `make vm HOST=apps` starts
   Vaultwarden with an empty data directory.
8. Restore Vaultwarden into its live data directory with the container stopped. If the
   bucket already holds a backup, run `make vaultwarden-drill` first. The archive holds one
   directory, `vaultwarden/`, with the database, attachments, sends, the RSA keys and any
   `config.json`. This is not scripted:

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
   [Troubleshooting](usage.md#troubleshooting).

9. Run `make backup` and redo the hand steps below.

## Not managed here

You set these by hand, and redo them after a rebuild.

### Cloudflare

The tunnels and their public hostnames, and the API token Caddy uses for DNS-01.

### Home router

1. Reserve the Proxmox uplink's address in DHCP.
2. Reserve `site.hosts.apps.home_ip` for `site.hosts.apps.home_mac`, the `apps` VM's home
   NIC (Proxmox `net1`, pinned by Terraform).
3. Hand out `<apps-home-address>` as the primary DNS server and the router as the
   secondary. Devices pick it up when they renew their lease or rejoin Wi-Fi. On a Mac,
   `scutil --dns` then lists Pi-hole first.

### NetBird

On the cloud network, routes, groups, ACLs and setup keys live in the NetBird dashboard.
The self-hosted network gets its Pi-hole nameserver from the netbird_server role. On the
cloud one, add it by hand:

1. DNS, Nameservers, Add nameserver: custom, IP `<apps-address>`, port 53, UDP. The lab
   network must be a route the peers use, through the `netbird` routing peer.
2. Distribution groups: the peer groups that should use it, for example All.
3. Match domains: leave them empty to send every query to Pi-hole, so remote devices get
   filtering too, or set `lan.<domain>` and `<gateway-domain>` for local and gateway names
   only. Leave it enabled and save. Peers pick it up within a minute. Check with
   `netbird status -d`.

### Self-hosted NetBird

`make vm HOST=netbird` runs the server and sets it up (groups, policy, networks, DNS). Four
things stay by hand.

**1. The Cloudflare route.** The server's public name goes through the existing tunnel,
whose connectors run on `frigate`, `netbird` and `ragnarok`. In the Cloudflare dashboard:

1. Zero Trust, Networks, Tunnels: open that tunnel, Public hostnames, Add a public
   hostname.
2. Subdomain `netbird`, domain `<domain>`, no path (the name is `site.netbird_domain`).
3. Service type `HTTPS`, URL `<netbird-lab-address>:8443` (Caddy on the `netbird` VM).
4. Additional application settings, TLS: turn on No TLS Verify and HTTP2 connection, and
   set Origin Server Name to `netbird.<domain>`. Save. Cloudflare adds the DNS record.
5. In the `<domain>` zone, Network: turn gRPC on. Leave WebSockets on.

Then check `https://netbird.<domain>` shows the login page, and run
`make vm HOST=netbird ARGS="--tags netbird_home"`. It enrolls `netbird-home`, the routing
peer. Native NetBird clients need gRPC through the tunnel. Cloudflare documents gRPC on
public tunnel names as unsupported, so if `netbird-home` does not connect, see
[docs/usage.md](usage.md#self-hosted-netbird).

**2. The Proxmox host's return route.** The `home-gateway` route keeps the peer's own
address (masquerade off). `apps` answers such a peer through the Proxmox host, which needs a
route for `site.netbird_server.network_range` to the `netbird` VM. Dry run, then apply it
on its own, never with a `netbird` VM change:
`make host-network ARGS="--check --diff"`, then `make host-network`.

**3. Your devices, with two NetBird profiles.** `home` is the self-hosted network (day to
day), `cloud` is NetBird's service (emergency). The login is `owner_email` and
`owner_password` in `kv/homelab/netbird-srv`. On the Mac:

```sh
netbird profile add home
netbird profile select home
netbird up --management-url https://netbird.<domain>
netbird profile add cloud
netbird profile select cloud
netbird up --management-url https://api.netbird.io
netbird profile select home
```

Each `up` opens a browser login. On the phone, add the self-hosted server as a second
profile in the NetBird app (or Settings, Change server, on an app without profiles).
Every device you log in to the self-hosted server joins group `operator`.

**4. Your new peer addresses.** The self-hosted network gives your devices other 100.x
addresses than the cloud one. Add each device's self-hosted address as a /32 to
`site.admin_vpn_sources` (find it with `netbird status` on the Mac, and in the app on the
phone), then run `make enclave` and `make vm HOST=apps ARGS="--tags caddy"`. Until then the
enclave and the `pass` and `vault` names refuse them.

Failure drills, with the user at hand:

1. Stop the self-hosted stack (`sudo docker stop netbird-server` on `netbird`), select the
   `cloud` profile on the Mac, and reach the lab.
2. Start it again. Stop the cloud client on `netbird` (`sudo systemctl stop netbird`),
   select `home`, and reach the lab. The Proxmox host still routes the lab on the cloud
   network meanwhile.
3. Start both again (`sudo systemctl start netbird`, `sudo docker start netbird-server`).

### The Mac's route to the secrets enclave

Vault and Vaultwarden are on the enclave network, which only the Proxmox host routes. The
Mac reaches it through the host's home address, on the Wi-Fi service (this replaces the
service's additional routes. It had none, so add any you use to the same command):

```sh
networksetup -getadditionalroutes "Wi-Fi"        # note the existing ones first
sudo networksetup -setadditionalroutes "Wi-Fi" <enclave-network> <enclave-netmask> <proxmox-home-address>
netstat -rn -f inet | grep <enclave-network-prefix>
```

The enclave firewall and the gateway's `pass` and `vault` routes let in only the operator's
devices: the Mac's LAN addresses in `site.admin_sources` (its home Wi-Fi address, reserved
in the router's DHCP, its USB LAN and Wi-Fi alias lab addresses) and its NetBird peers in
`site.admin_vpn_sources`. `site.enclave.vpn_only: true` keeps only the NetBird ones (a
LAN address is no proof of the device: the lab and home networks share one L2 segment, so any
VM or home device can take over the Mac's LAN addresses, ARP included, and finish a TCP
connection as the Mac. A NetBird address arrives only through the operator's WireGuard
tunnel). See [Turning on VPN-only](services.md#turning-on-vpn-only). Then point the Keychain at Vault's
enclave address and check:

```sh
security add-generic-password -U -s homelab -a vault-ip -w <vault-enclave-address>
source scripts/env.sh && vault status && make tf-plan
```

Without the route, Ansible still works (it goes through the Proxmox host), and
`HOMELAB_VAULT_ADDR=https://vault.<gateway-domain>` with `HOMELAB_VAULT_CACERT` set to a
public CA bundle reaches Vault through the gateway.

**Current risk, close it first:** the NetBird access policy for the lab's /16 route admits
the GitHub-hosted runner peers (`runnervm…`, CI jobs that joined the network). While it
does, any of those jobs can reach the whole lab /16: the Proxmox host's web UI (8006) and
SSH (22), and every VM. The enclave firewall keeps them out of Vault and Vaultwarden (they
are not in `site.admin_vpn_sources`), but nothing else in the lab is closed to them. Step 2
below removes them.

NetBird reaches the lab through two routing peers for the lab's /16: the Proxmox host
(masquerade on, applied after its firewall) and the `netbird` VM (no masquerade). Either way
the enclave firewall sees the peer's own NetBird address, so only the peers listed in
`site.admin_vpn_sources` get in. To make that path reliable and keep other peers out, in the
NetBird dashboard:

1. Groups: make a group (for example `operator`) with only your own devices (today the
   Mac's peers). Remove the stale duplicates of it. List their NetBird addresses in
   `site.admin_vpn_sources`.
2. Access control: the policy that opens the lab's /16 route today also admits the GitHub
   Actions runner peers. Limit it to the `operator` group, or add a policy for the enclave
   route below that only `operator` gets.
3. Network routes: add the enclave network (`site.sdn.enclave.subnet`) with the Proxmox host
   (`pve`) as its only routing peer, masquerade off, distribution group `operator` (the
   enclave VMs answer through their gateway, the Proxmox host, which sends it back through
   NetBird). Through the
   `netbird` VM the answers would come back over the Proxmox host's tunnel instead, which the
   client drops.
4. For the gateway names (`pass`, `vault`) over NetBird, Caddy must see the peer's address:
   add the `apps` home address as a /32 route with the Proxmox host as routing peer,
   masquerade off, distribution group `operator`. (`apps` answers through its default
   gateway, the Proxmox host, which sends it back through NetBird.) With masquerade, Caddy
   sees the routing peer's address, which is not an operator, and answers 403.

### Switch

The Cisco switch's ports and VLANs, from `site.network.switch` with `make switch`. The
Proxmox port is a trunk (the lab untagged, VLANs 10, 20 and 30 tagged). See
[cisco-switch.md](cisco-switch.md).

### Wi-Fi access point

The cameras are on the home Wi-Fi, so VLAN 20 cannot isolate them yet. A VLAN-capable
access point on the switch trunk fixes that, with a hidden camera SSID tagged VLAN 20. See
[Cameras on VLAN 20](cisco-switch.md#cameras-on-vlan-20). Until it exists, the home
router's per-device internet block can keep the cameras off the internet, at the cost of
the Tapo app away from home.

### App settings

Settings kept in app databases: indexers and download clients in the ARR apps,
Threadfin mappings, ntfy users and access rules, Frigate recordings, Pi-hole block lists
added in its UI, and Vaultwarden accounts.
