# Cisco switch

The switch is configured by hand. Nothing in this repo logs in to it. This page has the
config for VLANs 10, 20 and 30 ([VLANs](services.md#vlans)).

The switch model is not recorded here. The commands are generic Catalyst IOS (IOS 15 and
IOS XE). Check each one against your model before you paste it. The notes say where models
differ.

Placeholders: `<proxmox-port>` (the port cabled to the Proxmox host's `eno1`),
`<camera-ports>`, `<personal-ports>`, `<ap-port>`, for example `GigabitEthernet1/0/5` or a
range such as `GigabitEthernet1/0/10 - 12`.

## Before you start

- Work from the console port, or over SSH from a device that does not depend on the port
  you are changing. Changing `<proxmox-port>` can cut off the lab and the home network if
  it goes wrong.
- Find the VLAN the lab and home network use on the switch today. On a default switch it
  is VLAN 1. Use it as the native VLAN below. If it is not 1, replace every `1` in
  `native vlan 1` and `allowed vlan 1,...` with it.

  ```
  show vlan brief
  show interfaces <proxmox-port> switchport
  ```

- Check that the native VLAN is sent untagged. This must print nothing:

  ```
  show running-config | include vlan dot1q tag native
  ```

  If it prints the line, the lab would break on the trunk. Stop and ask.

- Save a copy of the current config:

  ```
  copy running-config flash:pre-vlans.cfg
  ```

## The VLANs

```
configure terminal
vlan 10
 name servers
vlan 20
 name cameras
vlan 30
 name personal
end
```

## The Proxmox port: a trunk

The lab and the home network stay untagged (native VLAN). VLANs 10, 20 and 30 are tagged.
The Proxmox host already accepts them (`bridge-vids 10 20 30` on `vmbr0`).

```
configure terminal
interface <proxmox-port>
 description proxmox eno1 (lab untagged, VLANs 10 20 30 tagged)
 switchport trunk encapsulation dot1q
 switchport mode trunk
 switchport trunk native vlan 1
 switchport trunk allowed vlan 1,10,20,30
 switchport nonegotiate
 spanning-tree portfast trunk
end
```

- `switchport trunk encapsulation dot1q`: only models that also support ISL take it (for
  example the 3560 and 3750). A 2960 rejects it, because it only knows 802.1Q. Skip the line
  there.
- `spanning-tree portfast trunk`: on IOS XE it is `spanning-tree portfast edge trunk`. The
  Proxmox bridge runs no spanning tree, so the port can forward at once.

Check from the switch:

```
show interfaces trunk
show interfaces <proxmox-port> switchport
```

`<proxmox-port>` should list native VLAN 1 and VLANs 1,10,20,30 as allowed and active.
Then check from the Mac that the Proxmox host and the home DNS still answer.

## Camera ports: access VLAN 20

```
configure terminal
interface range <camera-ports>
 description camera (VLAN 20)
 switchport mode access
 switchport access vlan 20
 switchport nonegotiate
 spanning-tree portfast
 spanning-tree bpduguard enable
end
```

On IOS XE the portfast line is `spanning-tree portfast edge`.

## Personal ports: access VLAN 30

```
configure terminal
interface range <personal-ports>
 description personal (VLAN 30)
 switchport mode access
 switchport access vlan 30
 switchport nonegotiate
 spanning-tree portfast
 spanning-tree bpduguard enable
end
```

A device on one of these ports gets its address from the Proxmox host's DHCP for VLAN 30.

## Save

```
copy running-config startup-config
```

To undo one port, `default interface <port>` puts it back to the switch's defaults (access
VLAN 1). `flash:pre-vlans.cfg` has the old config of every port.

## Cameras on VLAN 20

The cameras use the home Wi-Fi today, so they are on the home network and VLAN 20 does not
isolate them. To move them:

1. Add a VLAN-capable access point, for example a TP-Link Omada EAP or a UniFi U6 or U7.
   The home router's own Wi-Fi cannot tag VLANs.
2. Cable it to `<ap-port>` as a trunk. Its management stays on the native VLAN:

   ```
   configure terminal
   interface <ap-port>
    description access point (native 1, VLANs 20 30 tagged)
    switchport trunk encapsulation dot1q
    switchport mode trunk
    switchport trunk native vlan 1
    switchport trunk allowed vlan 1,20,30
    switchport nonegotiate
    spanning-tree portfast trunk
   end
   ```

3. On the access point, make a hidden SSID for the cameras, tagged VLAN 20, on 2.4 GHz
   with WPA2-PSK (many Tapo cameras do not join 5 GHz or WPA3-only networks). Turn on
   client isolation for it. Optionally make a personal SSID tagged VLAN 30.
4. Join each camera to the new SSID in the Tapo app. Each one gets an address from the
   VLAN 20 range.
5. Give Frigate a second NIC on vnet `cameras` with a static address outside the DHCP
   range, and point its camera URLs at the new addresses. That is a later task, with a
   planned Frigate restart.
6. If the Tapo app is not needed, set `cameras_internet: false` and run `make vlans`.

Until then, the home router can stop the cameras reaching the internet. Most routers have
a per-device internet block or parental control. That also stops the Tapo app working
away from home.
