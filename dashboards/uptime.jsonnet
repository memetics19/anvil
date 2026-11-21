// Uptime calendar: one square per day for the last 90 days, coloured by that day's
// availability, for every gateway service (job service), every host (job node) and the
// internet (job ping), and the minutes down per day. Built to
// ansible/roles/monitoring/files/dashboards/uptime.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;
local sh = g.panel.statusHistory;

// A day's availability in percent, one point per day.
local daily(expr, by) = '100 * avg_over_time(max by (%s) (%s)[1d:5m])' % [by, expr];
local steps = [['red', null], ['orange', 95], ['#EAB839', 99], ['green', 99.9]];

local calendar(title, expr, legend, height) =
  sh.new(title)
  + sh.queryOptions.withDatasource('prometheus', a.ds.metrics)
  + sh.queryOptions.withTargets(a.refs([a.q(expr, legend)]))
  + sh.queryOptions.withInterval('1d')
  + sh.queryOptions.withMaxDataPoints(100)
  + sh.standardOptions.withUnit('percent')
  + sh.standardOptions.withDecimals(2)
  + sh.standardOptions.withMin(0)
  + sh.standardOptions.withMax(100)
  + sh.standardOptions.color.withMode('thresholds')
  + sh.standardOptions.thresholds.withMode('absolute')
  + sh.standardOptions.thresholds.withSteps([{ color: s[0], value: s[1] } for s in steps])
  + sh.options.withShowValue('never')
  + sh.options.withColWidth(0.9)
  + sh.options.withRowHeight(0.85)
  + sh.options.legend.withShowLegend(false)
  + { gridPos: { h: height } };

a.dashboard('anvil-uptime', 'Uptime calendar',
            'The last 90 days, one square per day: every gateway service, every host and the internet, coloured by availability, and the minutes down per day. Managed by anvil: change dashboards/uptime.jsonnet.',
            ['sla', 'uptime', 'availability'])
+ g.dashboard.time.withFrom('now-90d')
+ g.dashboard.withRefresh('1h')
+ g.dashboard.withPanels(a.rows([
  [
    a.note('How to read this', |||
      Each square is one day, the newest on the right. **Green** is 99.9% or more, **yellow** 99% to 99.9% (up to about 15 minutes down), **orange** 95% to 99%, **red** under 95% (more than about an hour). Point at a square for the exact figure. A blank square means nothing was measured that day: the service checks started on 2026-11-18. The full picture for one day is on the **SLA** dashboard.
    |||) + { gridPos: { h: 3 } },
  ],
  [calendar('Services', daily('probe_success{job="service"}', 'service'), '{{service}}', 20)],
  [calendar('Hosts', daily('up{job="node"}', 'host'), '{{host}}', 9)],
  [calendar('Internet and router', |||
    label_replace(100 * avg_over_time(max(probe_success{job="ping",scope="internet"})[1d:1m]), "probe", "internet", "", "")
    or 100 * avg_over_time(max by (probe) (probe_success{job="ping",probe="router"})[1d:1m])
  |||, '{{probe}}', 4)],
  [
    a.bars('Minutes down per day, all services together', [
      a.q('sum(1440 * (1 - avg_over_time(max by (service) (probe_success{job="service"})[1d:5m])))', 'Services'),
      a.q('sum(1440 * (1 - avg_over_time(max by (host) (up{job="node"})[1d:5m])))', 'Hosts'),
    ], 'm', '1d', [['green', null], ['orange', 15], ['red', 60]]) + { gridPos: { h: 8 } },
  ],
]))
