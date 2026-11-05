// Shared by every dashboard (Grafonnet). The data sources Grafana provisions (role monitoring,
// templates/datasources.yml.j2), panel helpers with the lab's defaults, and the grid.
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-v13.0.0/main.libsonnet';

{
  g: g,

  // Grafana's data source uids, as provisioned.
  ds: { metrics: 'victoriametrics' },

  // A PromQL query on VictoriaMetrics, with a legend.
  q(expr, legend='{{host}}')::
    g.query.prometheus.new(self.ds.metrics, expr)
    + g.query.prometheus.withLegendFormat(legend),

  // A time series: table legend on the right with the last and highest value.
  ts(title, queries, unit, min=null, max=null)::
    local ts = g.panel.timeSeries;
    ts.new(title)
    + ts.queryOptions.withDatasource('prometheus', self.ds.metrics)
    + ts.queryOptions.withTargets(queries)
    + ts.standardOptions.withUnit(unit)
    + (if min != null then ts.standardOptions.withMin(min) else {})
    + (if max != null then ts.standardOptions.withMax(max) else {})
    + ts.options.legend.withDisplayMode('table')
    + ts.options.legend.withPlacement('right')
    + ts.options.legend.withCalcs(['lastNotNull', 'max'])
    + ts.options.tooltip.withMode('multi')
    + ts.options.tooltip.withSort('desc'),

  // A stat: the last value, coloured by thresholds ([[colour, from], ...]).
  stat(title, queries, unit, steps=[])::
    local st = g.panel.stat;
    st.new(title)
    + st.queryOptions.withDatasource('prometheus', self.ds.metrics)
    + st.queryOptions.withTargets(queries)
    + st.standardOptions.withUnit(unit)
    + st.options.withColorMode('background')
    + st.options.withGraphMode('none')
    + st.options.withTextMode('value_and_name')
    + st.options.reduceOptions.withCalcs(['lastNotNull'])
    + (if steps != [] then st.standardOptions.thresholds.withMode('absolute')
       + st.standardOptions.thresholds.withSteps([{ color: s[0], value: s[1] } for s in steps]) else {}),

  // A dashboard of the lab: uid, title, tags, refreshed every minute, last 24 hours, read-only.
  dashboard(uid, title, description, tags=[])::
    local d = g.dashboard;
    d.new(title)
    + d.withUid(uid)
    + d.withDescription(description)
    + d.withTags(['anvil'] + tags)
    + d.withRefresh('1m')
    + d.time.withFrom('now-24h')
    + d.withTimezone('browser')
    + d.withEditable(false),

  // A multi-select variable over a label's values, All by default.
  labelVar(name, label, metric, title=null)::
    local v = g.dashboard.variable.query;
    v.new(name)
    + v.withDatasource('prometheus', self.ds.metrics)
    + v.queryTypes.withLabelValues(label, metric)
    + v.generalOptions.withLabel(if title == null then name else title)
    + v.selectionOptions.withMulti()
    + v.selectionOptions.withIncludeAll(true, '.*')
    + v.refresh.onTime()
    + v.withSort(1),

  // Rows of panels: each inner list is a row, its panels share the width equally.
  rows(rows, height=8)::
    std.foldl(
      function(acc, row)
        local w = std.floor(24 / std.length(row));
        local h = if std.objectHas(row[0], 'gridPos') && std.objectHas(row[0].gridPos, 'h') then row[0].gridPos.h else height;
        {
          y: acc.y + h,
          panels: acc.panels + [
            row[i] + { gridPos: { x: i * w, y: acc.y, w: w, h: h } }
            for i in std.range(0, std.length(row) - 1)
          ],
        },
      rows,
      { y: 0, panels: [] }
    ).panels,
}
