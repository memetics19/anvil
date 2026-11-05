// Hosts: every host's CPU, memory, disks and network (node_exporter). Built to
// ansible/roles/monitoring/files/dashboards/hosts.json by make dashboards.
local a = import 'lib/anvil.libsonnet';
local g = a.g;

local H = 'host=~"$host"';
local FS = 'fstype!~"tmpfs|overlay|squashfs|devtmpfs|efivarfs|ramfs"';
local NET = 'device!~"lo|veth.*|docker.*|br-.*|fwbr.*|fwpr.*|fwln.*|tap.*|wt.*"';

a.dashboard('anvil-hosts', 'Hosts',
            "Every host's CPU, memory, disks and network (node_exporter). Managed by anvil: change dashboards/hosts.jsonnet.",
            ['node_exporter'])
+ g.dashboard.withVariables([a.labelVar('host', 'host', 'node_uname_info', 'Host')])
+ g.dashboard.withPanels(a.rows([
  [
    a.stat('Up', [a.q('up{job="node",%s}' % H)], 'none', [['red', null], ['green', 1]]) + { gridPos: { h: 4 } },
    a.stat('Uptime', [a.q('time() - node_boot_time_seconds{%s}' % H)], 's') + { gridPos: { h: 4 } },
  ],
  [
    a.ts('CPU busy', [a.q('100 * (1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle",%s}[5m])))' % H)], 'percent', 0, 100),
    a.ts('Memory used', [a.q('100 * (1 - node_memory_MemAvailable_bytes{%s} / node_memory_MemTotal_bytes{%s})' % [H, H])], 'percent', 0, 100),
  ],
  [
    a.ts('Disk space used', [a.q('100 * (1 - node_filesystem_avail_bytes{%s,%s} / node_filesystem_size_bytes{%s,%s})' % [FS, H, FS, H], '{{host}} {{mountpoint}}')], 'percent', 0, 100)
    + g.panel.timeSeries.standardOptions.thresholds.withSteps([{ color: 'green', value: null }, { color: 'orange', value: 80 }, { color: 'red', value: 90 }]),
    a.ts('Load per core (5 min)', [a.q('node_load5{%s} / count by (host) (node_cpu_seconds_total{mode="idle",%s})' % [H, H])], 'none'),
  ],
  [
    a.ts('Network in', [a.q('sum by (host) (rate(node_network_receive_bytes_total{%s,%s}[5m]))' % [NET, H])], 'Bps'),
    a.ts('Network out', [a.q('sum by (host) (rate(node_network_transmit_bytes_total{%s,%s}[5m]))' % [NET, H])], 'Bps'),
  ],
  [
    a.ts('Disk reads', [a.q('sum by (host) (rate(node_disk_read_bytes_total{%s}[5m]))' % H)], 'Bps'),
    a.ts('Disk writes', [a.q('sum by (host) (rate(node_disk_written_bytes_total{%s}[5m]))' % H)], 'Bps'),
  ],
]))
