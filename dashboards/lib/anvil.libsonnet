// Shared by every dashboard (Grafonnet). The data sources Grafana provisions (role monitoring,
// templates/datasources.yml.j2), panel helpers with the lab's defaults, and the grid.
local g = import 'github.com/grafana/grafonnet/gen/grafonnet-v13.0.0/main.libsonnet';

{
  g: g,

  // Grafana's data source uids, as provisioned.
  ds: { metrics: 'victoriametrics', wazuh: 'wazuh' },

  // A query on Wazuh's alerts (OpenSearch, index wazuh-alerts-*): a Lucene filter, what to
  // count, and how to bucket it. by: a field to split by (terms), over: time or none.
  wazuh(query, by=null, size=10, over='time', metric={ id: '1', type: 'count' })::
    {
      datasource: { type: 'grafana-opensearch-datasource', uid: $.ds.wazuh },
      query: query,
      queryType: 'lucene',
      luceneQueryType: 'Metric',
      timeField: 'timestamp',
      metrics: [metric],
      bucketAggs:
        (if by != null then [{ id: '3', type: 'terms', field: by,
                               settings: { size: std.toString(size), order: 'desc', orderBy: '_count', min_doc_count: '1' } }] else [])
        + (if over == 'time' then [{ id: '2', type: 'date_histogram', field: 'timestamp',
                                     settings: { interval: 'auto', min_doc_count: '0' } }] else []),
    },

  // The data source a panel's queries go to: metrics by default.
  on(panel, uid, type)::
    panel + { datasource: { type: type, uid: uid } },

  // refIds A, B, C... for a list of queries.
  refs(qs):: [qs[i] + { refId: std.char(65 + i) } for i in std.range(0, std.length(qs) - 1)],

  // A PromQL query on VictoriaMetrics, with a legend.
  q(expr, legend='{{host}}')::
    g.query.prometheus.new(self.ds.metrics, expr)
    + g.query.prometheus.withLegendFormat(legend),

  // A time series: table legend on the right with the last and highest value.
  ts(title, queries, unit, min=null, max=null)::
    local ts = g.panel.timeSeries;
    ts.new(title)
    + ts.queryOptions.withDatasource('prometheus', self.ds.metrics)
    + ts.queryOptions.withTargets(self.refs(queries))
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
    + st.queryOptions.withTargets(self.refs(queries))
    + st.standardOptions.withUnit(unit)
    + st.options.withColorMode('background')
    + st.options.withGraphMode('none')
    + st.options.withTextMode('value_and_name')
    + st.options.reduceOptions.withCalcs(['lastNotNull'])
    + (if steps != [] then st.standardOptions.thresholds.withMode('absolute')
       + st.standardOptions.thresholds.withSteps([{ color: s[0], value: s[1] } for s in steps]) else {}),

  // A table: a terms breakdown, biggest first.
  table(title, queries)::
    local tb = g.panel.table;
    tb.new(title)
    + tb.queryOptions.withTargets(self.refs(queries))
    + tb.options.withShowHeader(true)
    + tb.options.withSortBy([{ displayName: 'Count', desc: true }]),

  // Up or down over time, one row per series: 1 is up (green), 0 is down (red).
  timeline(title, queries)::
    local st = g.panel.stateTimeline;
    st.new(title)
    + st.queryOptions.withDatasource('prometheus', self.ds.metrics)
    + st.queryOptions.withTargets(self.refs(queries))
    + st.standardOptions.withMappings([
      { type: 'value', options: { '0': { text: 'Down', color: 'red' }, '1': { text: 'Up', color: 'green' } } },
    ])
    + st.options.withShowValue('never'),

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
