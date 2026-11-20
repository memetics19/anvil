// SLA: is every gateway service answering, and how available was each over 24 hours, 7 and 30
// days against the SLO, its error budget, downtime, response time and certificate, then the
// hosts behind them (blackbox job service, node_exporter). Built to
// ansible/roles/monitoring/files/dashboards/sla.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;
local tb = g.panel.table;

// The SLO: the same in ansible/roles/monitoring/files/rules/services.yml (ServiceBelowSlo).
local SLO = 0.995;
// One check every monitoring_scrape_interval (30s): a failed check is half a minute down.
local CHECK_MINUTES = 0.5;
local P = 'probe_success{job="service"}';
local per(expr) = 'max by (service) (%s)' % expr;
local avail(range) = '100 * %s' % per('avg_over_time(%s[%s])' % [P, range]);
local budget = '100 * (1 - %s / %s)' % [per('1 - avg_over_time(%s[30d])' % P), 1 - SLO];

local col(expr, ref) = a.q(expr, '') + g.query.prometheus.withInstant(true) + g.query.prometheus.withFormat('table') + { refId: ref };
local override(name, props) = { matcher: { id: 'byName', options: name }, properties: props };
local thresholds(steps) = { id: 'thresholds', value: { mode: 'absolute', steps: [{ color: s[0], value: s[1] } for s in steps] } };
local cell = { id: 'custom.cellOptions', value: { type: 'color-background' } };
local availSteps = [['red', null], ['orange', 99], ['green', SLO * 100]];

local services =
  tb.new('Every service')
  + tb.queryOptions.withDatasource('prometheus', a.ds.metrics)
  + tb.queryOptions.withTargets([
    col('max by (service, host, via) (%s)' % P, 'A'),
    col(avail('24h'), 'B'),
    col(avail('7d'), 'C'),
    col(avail('30d'), 'D'),
    col(budget, 'E'),
    col('%s * %s' % [per('count_eq_over_time(%s[30d], 0)' % P), CHECK_MINUTES], 'F'),
    col(per('avg_over_time(probe_duration_seconds{job="service"}[1h])'), 'G'),
    col(per('(probe_ssl_earliest_cert_expiry{job="service"} - time()) / 86400'), 'H'),
  ])
  + tb.queryOptions.withTransformations([
    { id: 'merge', options: {} },
    { id: 'organize', options: {
      excludeByName: { Time: true },
      indexByName: { service: 0, 'Value #A': 1, 'Value #B': 2, 'Value #C': 3, 'Value #D': 4, 'Value #E': 5, 'Value #F': 6, 'Value #G': 7, 'Value #H': 8, host: 9, via: 10 },
      renameByName: {
        service: 'Service', 'Value #A': 'Now', 'Value #B': '24 hours', 'Value #C': '7 days', 'Value #D': '30 days',
        'Value #E': 'Error budget left', 'Value #F': 'Down, 30 days', 'Value #G': 'Response', 'Value #H': 'Certificate',
        host: 'Host', via: 'Checked',
      },
    } },
  ])
  + tb.options.withSortBy([{ displayName: '30 days', desc: false }])
  + tb.standardOptions.withNoValue('-')
  + tb.standardOptions.withOverrides([
    override('Now', [
      { id: 'mappings', value: [{ type: 'value', options: { '0': { text: 'DOWN', color: 'red' }, '1': { text: 'UP', color: 'green' } } }] },
      cell,
    ]),
    override('24 hours', [{ id: 'unit', value: 'percent' }, { id: 'decimals', value: 2 }, thresholds(availSteps), cell]),
    override('7 days', [{ id: 'unit', value: 'percent' }, { id: 'decimals', value: 2 }, thresholds(availSteps), cell]),
    override('30 days', [{ id: 'unit', value: 'percent' }, { id: 'decimals', value: 3 }, thresholds(availSteps), cell]),
    override('Error budget left', [{ id: 'unit', value: 'percent' }, { id: 'decimals', value: 0 }, { id: 'min', value: 0 }, { id: 'max', value: 100 },
                                   thresholds([['red', null], ['orange', 25], ['green', 50]]), { id: 'custom.cellOptions', value: { type: 'gauge', mode: 'basic' } }]),
    override('Down, 30 days', [{ id: 'unit', value: 'm' }, { id: 'decimals', value: 1 }]),
    override('Response', [{ id: 'unit', value: 's' }, thresholds([['green', null], ['orange', 1], ['red', 3]]), cell]),
    override('Certificate', [{ id: 'unit', value: 'suffix: days' }, { id: 'decimals', value: 0 }, thresholds([['red', null], ['orange', 14], ['green', 30]]), cell]),
  ]);

a.dashboard('anvil-sla', 'SLA',
            'Every gateway service: answering now, availability over 24 hours, 7 and 30 days against the 99.5% SLO, error budget, downtime, response time and certificate, and the hosts behind them. Managed by anvil: change dashboards/sla.jsonnet.',
            ['sla', 'services', 'availability'])
+ g.dashboard.withPanels(a.rows([
  [
    a.note('How to read this', |||
      Each service is checked every 30 seconds where it runs (its own address and port), or **through the gateway** when it has none of its own (Pi-hole's web page, Homepage, the docs) or sits in the secrets enclave (Vault, Vaultwarden). **Up** means it answers, whatever the page says: a sign-in page or an error below 500 still counts. The **SLO is 99.5%** over 30 days, about **3.6 hours** of downtime allowed: the **error budget** is how much of that is left. The history starts when the checks did, so early on the 30-day figures cover less than 30 days.
    |||) + { gridPos: { h: 4 } },
  ],
  [
    a.stat('Answering now', [a.q('sum(%s)' % per(P), 'Up')], 'short', [['green', null]]) + { gridPos: { h: 5 } },
    a.stat('Not answering now', [a.q('count(%s == 0) or vector(0)' % per(P), 'Down')], 'short', [['green', null], ['red', 1]]) + { gridPos: { h: 5 } },
    a.stat('All services, 30 days', [a.q('avg(%s)' % avail('30d'), 'All')], 'percent', availSteps)
    + g.panel.stat.standardOptions.withDecimals(3) + { gridPos: { h: 5 } },
    a.stat('Below the SLA, 30 days', [a.q('count(%s < %s) or vector(0)' % [per('avg_over_time(%s[30d])' % P), SLO], 'Below')], 'short',
           [['green', null], ['red', 1]]) + { gridPos: { h: 5 } },
    a.stat('Worst service, 30 days', [a.q('min(%s)' % avail('30d'), 'Worst')], 'percent', availSteps)
    + g.panel.stat.standardOptions.withDecimals(3) + { gridPos: { h: 5 } },
    a.stat('Internet, 30 days', [a.q('100 * avg_over_time(max(probe_success{job="ping",scope="internet"})[30d:1m])', 'Internet')], 'percent', availSteps)
    + g.panel.stat.standardOptions.withDecimals(3) + { gridPos: { h: 5 } },
  ],
  [services + { gridPos: { h: 14 } }],
  [
    a.timeline('Up and down, every service', [a.q(per(P), '{{service}}')]) + { gridPos: { h: 12 } },
  ],
  [
    a.ts('Error budget left (30-day window)', [a.q(budget, '{{service}}')], 'percent', 0, 100),
    a.ts('Response time', [a.q(per('probe_duration_seconds{job="service"}'), '{{service}}')], 's', 0),
  ],
  [
    a.timeline('Hosts up', [a.q('max by (host) (up{job="node"})', '{{host}}')]) + { gridPos: { h: 8 } },
    a.stat('Hosts, 30 days', [a.q('100 * avg(avg_over_time(up{job="node"}[30d]))', 'Hosts')], 'percent', availSteps)
    + g.panel.stat.standardOptions.withDecimals(3) + { gridPos: { h: 8 } },
  ],
]))
