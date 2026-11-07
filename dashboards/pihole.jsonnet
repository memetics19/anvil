// Pi-hole: is DNS answering, is blocking on, how much is asked and blocked today, how fast,
// from cache or upstream, and which domains and clients are busiest (job pihole, role pihole's
// exporter, and the blackbox DNS probe). Built to ansible/roles/monitoring/files/dashboards/pihole.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;
local tb = g.panel.table;

local P = '{job="pihole"}';
local onoff(on, off) = g.panel.stat.standardOptions.withMappings([
  { type: 'value', options: { '0': { text: off }, '1': { text: on } } },
]);

// A top-N table: one row per label value, biggest first.
local top(title, metric, label, name, valueName) =
  tb.new(title)
  + tb.queryOptions.withDatasource('prometheus', a.ds.metrics)
  + tb.queryOptions.withTargets([
    a.q('sum by (%s) (%s%s)' % [label, metric, P], '')
    + g.query.prometheus.withInstant(true)
    + g.query.prometheus.withFormat('table')
    + { refId: 'A' },
  ])
  + tb.queryOptions.withTransformations([
    { id: 'organize', options: {
      excludeByName: { Time: true },
      renameByName: { [label]: name, Value: valueName },
    } },
  ])
  + tb.options.withSortBy([{ displayName: valueName, desc: true }])
  + tb.standardOptions.withNoValue('No data yet');

a.dashboard('anvil-pihole', 'Pi-hole',
            "The lab's DNS: answering, blocking, queries and blocks today, speed, cache and upstreams, and the busiest domains and clients. Managed by anvil: change dashboards/pihole.jsonnet.",
            ['pihole', 'dns'])
+ g.dashboard.withPanels(a.rows([
  [
    a.stat('DNS', [a.q('max(probe_success{job="dns",probe="pihole"})', 'DNS')], 'none', [['red', null], ['green', 1]])
    + onoff('Answering', 'Down') + { gridPos: { h: 5 } },
    a.stat('Blocking', [a.q('max(pihole_status%s)' % P, 'Blocking')], 'none', [['orange', null], ['green', 1]])
    + onoff('On', 'Off') + { gridPos: { h: 5 } },
    a.stat('Queries today', [a.q('sum(pihole_dns_queries_today%s)' % P, 'Queries')], 'short') + { gridPos: { h: 5 } },
    a.stat('Blocked today', [a.q('sum(pihole_ads_blocked_today%s)' % P, 'Blocked')], 'short') + { gridPos: { h: 5 } },
    a.stat('Blocked share', [a.q('max(pihole_ads_percentage_today%s)' % P, 'Blocked')], 'percent') + { gridPos: { h: 5 } },
    a.stat('Clients', [a.q('max(pihole_unique_clients%s)' % P, 'Clients')], 'short') + { gridPos: { h: 5 } },
  ],
  [
    a.ts('Queries per second', [a.q('sum(pihole_request_rate%s)' % P, 'Queries')], 'reqps', 0),
    a.ts('DNS answer time', [a.q('probe_dns_lookup_time_seconds{probe="pihole"}', 'Pi-hole')], 's', 0),
  ],
  [
    a.ts('Today so far', [
      a.q('sum(pihole_ads_blocked_today%s)' % P, 'Blocked'),
      a.q('sum(pihole_queries_cached%s)' % P, 'From cache'),
      a.q('sum(pihole_queries_forwarded%s)' % P, 'Asked upstream'),
    ], 'short', 0),
    a.ts('Upstream answer time', [
      a.q('pihole_forward_destinations_responsetime%s' % P, '{{destination_name}}'),
    ], 's', 0),
  ],
  [
    top('Top domains', 'pihole_top_queries', 'domain', 'Domain', 'Queries'),
    top('Top blocked domains', 'pihole_top_ads', 'domain', 'Domain', 'Blocked'),
  ],
  [
    top('Busiest clients', 'pihole_top_sources', 'source_name', 'Client', 'Queries'),
    top('Clients blocked most', 'pihole_top_sources_blocked', 'source_name', 'Client', 'Blocked'),
    top('Query types', 'pihole_querytypes', 'type', 'Type', 'Share'),
  ],
  [
    a.stat('Domains on the blocklists', [a.q('max(pihole_domains_being_blocked%s)' % P, 'Domains')], 'short') + { gridPos: { h: 4 } },
    a.stat('Clients ever seen', [a.q('max(pihole_clients_ever_seen%s)' % P, 'Clients')], 'short') + { gridPos: { h: 4 } },
    a.stat('Unique domains', [a.q('max(pihole_unique_domains%s)' % P, 'Domains')], 'short') + { gridPos: { h: 4 } },
  ],
]))
