// Internet: is the line up right now and how good is it, how often was it down today, on which
// days the ISP was worst, and the details behind it (blackbox exporter on the monitoring VM:
// pings to public resolvers and the router, DNS through Pi-hole, two web pages). Built to
// ansible/roles/monitoring/files/dashboards/internet.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;

// Up when any public address answers a ping.
local UP = 'max(probe_success{job="ping",scope="internet"})';
local pct(range, step) = a.q('100 * avg_over_time(%s[%s:%s])' % [UP, range, step], 'Uptime');
local updown = g.panel.stat.standardOptions.withMappings([
  { type: 'value', options: { '0': { text: 'Down' }, '1': { text: 'Up' } } },
]);
local RTT = 'probe_icmp_duration_seconds{job="ping",scope="internet",phase="rtt"}';
// How long Pi-hole takes to answer a query (the probe's request phase).
local DNS = 'probe_dns_duration_seconds{job="dns",phase="request"}';
local ping = [['green', null], ['orange', 0.06], ['red', 0.15]];
local loss = [['green', null], ['orange', 1], ['red', 5]];
local uptime = [['red', null], ['orange', 99], ['green', 99.9]];

a.dashboard('anvil-internet', 'Internet',
            'The ISP line in plain terms: up now, ping, packet loss and DNS right now, outages and downtime today, the worst days, and the details. Managed by anvil: change dashboards/internet.jsonnet.',
            ['internet', 'blackbox'])
+ g.dashboard.withPanels(a.rows([
  [
    a.note('How to read this', |||
      **Up** means at least one public address (Cloudflare, Google, Quad9) answers a ping. **Ping** is the round trip in milliseconds: under 60 ms is good, over 150 ms feels slow. **Packet loss** above 1% makes calls and games stutter. **Jitter** is how much the ping wobbles. When the router is down too, the problem is at home, not at the ISP. While the lab itself has no power, nothing is measured, so that time is not counted as an outage.
    |||) + { gridPos: { h: 3 } },
  ],
  [
    a.stat('Internet now', [a.q(UP, 'Internet')], 'none', [['red', null], ['green', 1]]) + updown + { gridPos: { h: 6 } },
    a.stat('Ping now', [a.q('avg(%s)' % RTT, 'Ping')], 's', ping) + { gridPos: { h: 6 } },
    a.stat('Packet loss, last 5 minutes',
           [a.q('100 * (1 - avg(avg_over_time(probe_success{job="ping",scope="internet"}[5m])))', 'Loss')],
           'percent', loss) + { gridPos: { h: 6 } },
    a.stat('DNS answer now', [a.q('avg(%s)' % DNS, 'DNS')], 's',
           [['green', null], ['orange', 0.1], ['red', 0.5]]) + { gridPos: { h: 6 } },
    a.stat('Router now', [a.q('max(probe_success{job="ping",probe="router"})', 'Router')], 'none',
           [['red', null], ['green', 1]]) + updown + { gridPos: { h: 6 } },
  ],
  [
    a.stat('Outages, last 24 hours', [a.q('ceil(changes(%s[24h:1m]) / 2)' % UP, 'Outages')], 'none',
           [['green', null], ['orange', 1], ['red', 3]]) + { gridPos: { h: 6 } },
    a.stat('Downtime, last 24 hours', [a.q('60 * 24 * (1 - avg_over_time(%s[24h:1m]))' % UP, 'Down')], 'm',
           [['green', null], ['orange', 1], ['red', 15]]) + { gridPos: { h: 6 } },
    a.gauge('Uptime, 24 hours', [pct('24h', '1m')], 'percent', uptime, 95, 100) + { gridPos: { h: 6 } },
    a.gauge('Uptime, 7 days', [pct('7d', '5m')], 'percent', uptime, 95, 100) + { gridPos: { h: 6 } },
    a.gauge('Uptime, 30 days', [pct('30d', '10m')], 'percent', uptime, 95, 100) + { gridPos: { h: 6 } },
  ],
  [
    a.timeline('Up and down', [
      a.q(UP, 'Internet'),
      a.q('probe_success{job="ping",probe="router"}', 'Router'),
      a.q('max(probe_success{job="dns"})', 'DNS (Pi-hole)'),
      a.q('max(probe_success{job="http"})', 'Web pages'),
    ]) + { gridPos: { h: 6 } },
  ],
  [
    a.bars('Downtime per day, minutes', [
      a.q('60 * 24 * (1 - avg_over_time(%s[1d:1m]))' % UP, 'Down'),
    ], 'm', '1d', [['green', null], ['orange', 1], ['red', 15]]) + { gridPos: { h: 7 } },
  ],
  [
    a.ts('Ping time', [a.q(RTT, '{{probe}}')], 's', 0),
    a.ts('Jitter (how much the ping wobbles)', [a.q('stddev_over_time(%s[5m])' % RTT, '{{probe}}')], 's', 0),
  ],
  [
    a.ts('Packet loss', [a.q('100 * (1 - avg_over_time(probe_success{job="ping"}[5m]))', '{{probe}}')], 'percent', 0, 100),
    a.ts('Web page load time', [a.q('probe_duration_seconds{job="http"}', '{{probe}}')], 's', 0),
  ],
  [
    a.ts('DNS answer time through Pi-hole', [a.q(DNS, '{{probe}}')], 's', 0),
    a.ts('Router ping time', [a.q('probe_icmp_duration_seconds{job="ping",probe="router",phase="rtt"}', 'Router')], 's', 0),
  ],
]))
