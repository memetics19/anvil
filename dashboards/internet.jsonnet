// Internet: is the line up, how often was it down, and how good is it (blackbox exporter on
// the monitoring VM). Built to ansible/roles/monitoring/files/dashboards/internet.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;

local UP = 'max(probe_success{job="ping",scope="internet"})';
local pct(range, step) = a.q('100 * avg_over_time(%s[%s:%s])' % [UP, range, step], 'Uptime');

a.dashboard('anvil-internet', 'Internet',
            'The ISP line: up now, uptime, outages, ping time, packet loss, DNS through Pi-hole and web pages. Managed by anvil: change dashboards/internet.jsonnet.',
            ['internet', 'blackbox'])
+ g.dashboard.withPanels(a.rows([
  [
    a.stat('Internet now', [a.q(UP, 'Internet')], 'none', [['red', null], ['green', 1]])
    + g.panel.stat.standardOptions.withMappings([
      { type: 'value', options: { '0': { text: 'Down' }, '1': { text: 'Up' } } },
    ]) + { gridPos: { h: 5 } },
    a.stat('Uptime, 24 hours', [pct('24h', '1m')], 'percent', [['red', null], ['orange', 99], ['green', 99.9]]) + { gridPos: { h: 5 } },
    a.stat('Uptime, 7 days', [pct('7d', '5m')], 'percent', [['red', null], ['orange', 99], ['green', 99.9]]) + { gridPos: { h: 5 } },
    a.stat('Uptime, 30 days', [pct('30d', '10m')], 'percent', [['red', null], ['orange', 99], ['green', 99.9]]) + { gridPos: { h: 5 } },
  ],
  [
    a.timeline('Outages', [
      a.q(UP, 'Internet'),
      a.q('probe_success{job="ping",probe="router"}', 'Router'),
      a.q('max(probe_success{job="dns"})', 'DNS (Pi-hole)'),
    ]) + { gridPos: { h: 6 } },
  ],
  [
    a.ts('Ping time', [a.q('probe_icmp_duration_seconds{phase="rtt"}', '{{probe}}')], 's'),
    a.ts('Packet loss', [a.q('100 * (1 - avg_over_time(probe_success{job="ping"}[5m]))', '{{probe}}')], 'percent', 0, 100),
  ],
  [
    a.ts('DNS lookup through Pi-hole', [a.q('probe_dns_lookup_time_seconds', '{{probe}}')], 's'),
    a.ts('Web page time', [a.q('probe_duration_seconds{job="http"}', '{{probe}}')], 's'),
  ],
]))
