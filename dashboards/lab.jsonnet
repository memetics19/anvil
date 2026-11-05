// Lab: the whole homelab on one page, and Grafana's home page. Is every host up, is the internet
// up, what is firing, are the cameras recording, did Wazuh see anything, and which host is
// busy or full. Each part links on to its own dashboard. Built to
// ansible/roles/monitoring/files/dashboards/lab.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;
local W = 'grafana-opensearch-datasource';
local tb = g.panel.table;

local firing(sev) = 'count(ALERTS{alertstate="firing",severity="%s"}) or vector(0)' % sev;
// One row per host: instant queries, one column each, merged on the host label.
local col(expr, ref) = a.q(expr, '') + g.query.prometheus.withInstant(true) + g.query.prometheus.withFormat('table') + { refId: ref };
local unit(name, u, steps=[]) = {
  matcher: { id: 'byName', options: name },
  properties: [{ id: 'unit', value: u }]
              + (if steps != [] then [
                   { id: 'thresholds', value: { mode: 'absolute', steps: [{ color: s[0], value: s[1] } for s in steps] } },
                   { id: 'custom.cellOptions', value: { type: 'color-background' } },
                 ] else []),
};
local busy = [['green', null], ['orange', 80], ['red', 95]];

local hosts =
  tb.new('Hosts')
  + tb.queryOptions.withDatasource('prometheus', a.ds.metrics)
  + tb.queryOptions.withTargets([
    col('up{job="node"}', 'A'),
    col('time() - node_boot_time_seconds', 'B'),
    col('100 * (1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])))', 'C'),
    col('100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)', 'D'),
    col('max by (host) (100 * (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|devtmpfs|efivarfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|devtmpfs|efivarfs|ramfs"}))', 'E'),
  ])
  + tb.queryOptions.withTransformations([
    { id: 'merge', options: {} },
    { id: 'organize', options: {
      excludeByName: { Time: true, job: true, instance: true, __name__: true },
      indexByName: { host: 0, 'Value #A': 1, 'Value #B': 2, 'Value #C': 3, 'Value #D': 4, 'Value #E': 5 },
      renameByName: { host: 'Host', 'Value #A': 'Up', 'Value #B': 'Uptime', 'Value #C': 'CPU', 'Value #D': 'Memory', 'Value #E': 'Fullest disk' },
    } },
  ])
  + tb.standardOptions.withOverrides([
    unit('Up', 'none', [['red', null], ['green', 1]]) + { properties+: [
      { id: 'mappings', value: [{ type: 'value', options: { '0': { text: 'Down' }, '1': { text: 'Up' } } }] },
    ] },
    unit('Uptime', 's'),
    unit('CPU', 'percent', busy),
    unit('Memory', 'percent', busy),
    unit('Fullest disk', 'percent', busy),
  ])
  + tb.options.withSortBy([{ displayName: 'Host', desc: false }]);

local alerts =
  tb.new('Firing now')
  + tb.queryOptions.withDatasource('prometheus', a.ds.metrics)
  + tb.queryOptions.withTargets([col('ALERTS{alertstate="firing"}', 'A')])
  + tb.queryOptions.withTransformations([
    { id: 'organize', options: {
      excludeByName: { Time: true, Value: true, __name__: true, alertstate: true, alertgroup: true, job: true },
      indexByName: { alertname: 0, severity: 1, host: 2 },
      renameByName: { alertname: 'Alert', severity: 'Level', host: 'Host' },
    } },
  ])
  + tb.standardOptions.withNoValue('Nothing is firing')
  + tb.options.withSortBy([{ displayName: 'Level', desc: false }]);

a.dashboard('anvil-lab', 'Lab',
            'The homelab on one page: hosts up, internet, alerts firing, cameras, security events, and the busiest and fullest hosts. Managed by anvil: change dashboards/lab.jsonnet.',
            ['lab', 'overview'])
+ g.dashboard.withLinks([
  g.dashboard.link.dashboards.new('Dashboards', ['anvil'])
  + g.dashboard.link.dashboards.options.withAsDropdown(true)
  + g.dashboard.link.dashboards.options.withIncludeVars(false),
])
+ g.dashboard.withPanels(a.rows([
  [
    a.stat('Hosts up', [
      a.q('count(up{job="node"} == 1) or vector(0)', 'Up'),
      a.q('count(up{job="node"})', 'Of'),
    ], 'none') + { gridPos: { h: 5 } },
    a.stat('Internet', [a.q('max(probe_success{job="ping",scope="internet"})', 'Internet')], 'none', [['red', null], ['green', 1]])
    + g.panel.stat.standardOptions.withMappings([
      { type: 'value', options: { '0': { text: 'Down' }, '1': { text: 'Up' } } },
    ]) + { gridPos: { h: 5 } },
    a.stat('Critical firing', [a.q(firing('critical'), 'Critical')], 'none', [['green', null], ['red', 1]]) + { gridPos: { h: 5 } },
    a.stat('Warnings firing', [a.q(firing('warning'), 'Warnings')], 'none', [['green', null], ['orange', 1]]) + { gridPos: { h: 5 } },
    a.stat('Cameras recording', [
      a.q('count(frigate_camera_fps > 0) or (count(frigate_camera_fps) * 0)', 'Sending'),
      a.q('count(frigate_camera_fps)', 'Of'),
    ], 'none') + { gridPos: { h: 5 } },
    a.on(a.stat('Security events, level 10 and up', [a.wazuh('rule.level:>=10')], 'none', [['green', null], ['orange', 1]]), a.ds.wazuh, W)
    + g.panel.stat.options.reduceOptions.withCalcs(['sum']) + { gridPos: { h: 5 } },
  ],
  [hosts + { gridPos: { h: 10 } }],
  [
    alerts + { gridPos: { h: 8 } },
    a.ts('Alerts firing over time', [
      a.q('count by (alertname) (ALERTS{alertstate="firing"})', '{{alertname}}'),
    ], 'none', 0) + { gridPos: { h: 8 } },
  ],
  [
    a.ts('CPU busy', [a.q('100 * (1 - avg by (host) (rate(node_cpu_seconds_total{mode="idle"}[5m])))')], 'percent', 0, 100),
    a.ts('Memory used', [a.q('100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)')], 'percent', 0, 100),
  ],
  [
    a.ts('Network traffic, in and out', [
      a.q('sum by (host) (rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*|br-.*|fwbr.*|fwpr.*|fwln.*|tap.*|wt.*"}[5m]) + rate(node_network_transmit_bytes_total{device!~"lo|veth.*|docker.*|br-.*|fwbr.*|fwpr.*|fwln.*|tap.*|wt.*"}[5m]))'),
    ], 'Bps', 0),
    a.ts('Internet ping time', [a.q('probe_icmp_duration_seconds{phase="rtt",scope="internet"}', '{{probe}}')], 's', 0),
  ],
]))
