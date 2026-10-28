# Cisco switch

The switch is a Cisco SG300-52 on firmware 1.3. `make switch` (role `network_switch`)
manages part of its config from site data. The rest is set by hand, and the role never
touches it.

Placeholders: `<proxmox-port>` (the port cabled to the Proxmox host's `eno1`),
`<office-port>`, `<router-port>`, `<ap-port>`, each a name such as `gi10`.

## What is code

The desired state is `site.network.switch` in `kv/homelab/site`. The structure is in
`site/site.example.yml`:

```yaml
network:
  switch:
    ports:
      <proxmox-port>: [trunk, protected]
      <office-port>: [protected]
    keep_ports: [<router-port>, <ap-port>]
    dhcp_snooping: {trusted: [<router-port>, <proxmox-port>], vlans: [1]}
```

A port has one or both roles:

| Role | Effect |
|---|---|
| `trunk` | VLAN 1 stays native and untagged. The VLANs of the `vlans` list in `ansible/inventory/group_vars/proxmox.yml` (10 servers, 20 cameras, 30 personal) are created with their names and added tagged. The port's other VLANs are left alone. |
| `protected` | `switchport protected-port`. Two protected ports cannot reach each other. Both still reach every unprotected port, such as the router uplink and the access point. The role does not change the port's mode for this. |

Rules:

- Ports that are not listed are never touched.
- The plan may not name a port in `keep_ports`. The run stops if one of them is protected.
- The VLANs are created only when some port is a trunk.
- `dhcp_snooping` is the one exception to `keep_ports`: its trusted ports are trusted even
  when they are keep ports, because trust only lets DHCP replies through.

### DHCP snooping

With `dhcp_snooping`, only the trusted ports may send DHCP replies on the listed VLANs
(default VLAN 1). The switch drops a DHCP offer from any other port. A second router or an
access point with its own DHCP server left on can then no longer hand out addresses. Its
Wi-Fi keeps working, and its clients get their address from the router.

Trust exactly these ports:

| Port | Why |
|---|---|
| The router uplink | The home's DHCP server. Untrusted, no device on the switch gets an address |
| The Proxmox port | `anvil provision`'s netboot answers PXE requests from there (proxy DHCP) |

The plan trusts the ports first, then enables snooping on the VLANs, then switches it on,
so the router uplink is never untrusted while snooping is on. It refuses an empty trusted
list. It never removes a trust or turns snooping off: do that by hand
(`no ip dhcp snooping`) when you need to.

Two DHCP servers on one network break a network boot: the target gets two offers from
different servers and accepts neither. `anvil provision` then times out waiting for the
installer to be served. Snooping is the fix when the other server cannot be switched off.

Current state:

- The Proxmox port is a trunk and protected. It was already a trunk with VLAN 1 native, so
  it only gains VLANs 10, 20 and 30.
- The office port is protected. It was a trunk with only VLAN 1, the firmware's default,
  and stays so.

## How it runs

Every task runs on the Mac, through `scripts/switch-cli.sh`.

- The firmware's SSH speaks only SHA1 key exchange, `ssh-rsa` host keys and CBC ciphers.
  The script allows them for that one connection with `ssh -o` flags, and reads no ssh
  config file.
- The password comes from Vault `kv/homelab/network/switch` into the environment of one
  task, through `sshpass -e`. It is never on a command line and never logged.
- The script sends one line at a time and waits for the prompt after each. It stops at the
  first error and leaves config mode before it logs out.
- The switch drops typed characters while it is busy, for example right after it creates
  VLANs. So the script types each line one character at a time, and presses Enter only
  when the switch has echoed the whole line back. Otherwise it clears the line with Ctrl-U
  and types it again.
- The switch can also refuse new SSH sessions for a while. A failed login is tried again,
  three times, 20 s apart.
- When a session fails, the run prints the exit code's meaning and the session's
  transcript: the commands and the switch's answers, with the address masked. The
  transcript of the running config is never printed.

A plain run is a dry run:

1. It reads the state with `show vlan`, `show interfaces protected-ports` and
   `show interfaces switchport <port>` for each listed port.
2. It works out the commands that are missing and prints them. Nothing else is sent.

```sh
make switch
```

To apply:

```sh
make switch ARGS="-e network_switch_apply=true"
```

The apply goes in this order:

1. Save the running config to `build/switch/running-config-<time>.cfg` (mode 600,
   gitignored).
2. Send the plan.
3. Read the state again. The plan must now be empty.
4. Check for 60 s from the Mac that the Proxmox host, Pi-hole DNS and the internet answer.
5. Only then `copy running-config startup-config`. It must print `Copy succeeded`. This
   firmware asks no (Y/N) question. If another one does, the script answers Y.

A second run prints nothing to change. An apply with nothing to change sends nothing and
does not save.

The host key is pinned in `build/switch/known_hosts` on first use. After a reset of the
switch, `make forget-host HOST=switch` drops the old key. `switch-cli.sh` refuses a
`SWITCH_KNOWN_HOSTS` of `/dev/null`, `none` or a file it cannot write, since that would
turn pinning off.

`tests/test_switch.sh` renders the plan from example output and checks that it names only
the listed ports. It also runs the script against a fake switch.

## Rollback

Before step 5, the startup config is still the old one. If the apply or the check fails,
the run stops without saving. To roll back, reload the switch (`reload` at its console or
over SSH) or power cycle it. It boots the old startup config. The whole home network is
down for about two minutes. To put back a single line by hand, the running config from
before is in `build/switch/`.

After step 5, undo by hand:

1. Take the role off the port in the site data, or the next `make switch` puts it back.
2. Run `no switchport protected-port` on the port, or
   `switchport trunk allowed vlan remove 10,20,30`.
3. Run `copy running-config startup-config`.

## VLANs 20 and 30 wait for an access point

The trunk carries VLANs 20 and 30, but nothing uses them yet. The cameras and the personal
devices are on Wi-Fi, and the home router's Wi-Fi cannot tag VLANs. They move once there is
a VLAN-capable access point. See below.

## Cameras on VLAN 20

The cameras use the home Wi-Fi, so they are on the home network and VLAN 20 does not
isolate them. To move them:

1. Add a VLAN-capable access point, for example a TP-Link Omada EAP or a UniFi U6 or U7.
   The home router's own Wi-Fi cannot tag VLANs.
2. Cable it to `<ap-port>`. Take that port out of `keep_ports`, give it the role `trunk`
   (CAS write to `kv/homelab/site`) and run `make switch`. Its management stays on the
   native VLAN. The trunk role adds all three VLANs, VLAN 10 too.
3. On the access point, make a hidden SSID for the cameras, tagged VLAN 20, on 2.4 GHz
   with WPA2-PSK (many Tapo cameras do not join 5 GHz or WPA3-only networks). Turn on
   client isolation for it. Optionally make a personal SSID tagged VLAN 30.
4. Join each camera to the new SSID in the Tapo app. Each one gets an address from the
   VLAN 20 range.
5. Give Frigate a second NIC on vnet `cameras` with a static address outside the DHCP
   range, and point its camera URLs at the new addresses. This is a later task, with a
   planned Frigate restart.
6. If the Tapo app is not needed, set `cameras_internet: false` and run `make vlans`.

Until then, the home router can block the cameras from the internet, with a per-device
internet block or parental control. That also stops the Tapo app working away from home.

## Web UI through the gateway

The switch's web UI is on the gateway as `https://switch.<gateway-domain>`.

- It is the `switch` entry of `site.services`. Its address is `site.network.switch_ip`.
- The home router hands out that address by DHCP, with a static entry for the switch's MAC,
  so it does not change.
- The gateway only proxies. It never logs in to the switch.
- It is an infrastructure page (`caddy_infra_routes`). Only the operator's devices get it.
  Every other client gets 403.
- Homepage shows it as Switch in the Infrastructure group.

Known limits of the old firmware:

- Its HTTPS speaks only TLS 1.0 with legacy renegotiation. Current Go and Chromium refuse
  that, so Caddy talks plain HTTP to port 80. Browsers get HTTPS from the gateway, but the
  hop from `apps` to the switch is plain HTTP on the home network. The login and every
  page cross that hop unencrypted.
- It redirects to absolute URLs, such as `http://<switch-address>/<session-path>/`. The
  entry sets `rewrite_location: true`, so Caddy rewrites any `Location` header that points
  at the switch's address, or at the gateway name over plain HTTP, to
  `https://switch.<gateway-domain>` with the same path. The login page and its scripts use
  relative links.
- The login page has a button that reloads the page over HTTPS. It shows only on plain
  HTTP, so it stays hidden behind the gateway.
