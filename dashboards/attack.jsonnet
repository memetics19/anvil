// Attack map: who reaches the lab's only public port (the self-hosted NetBird server on TCP
// 443) and where every security alert with an internet source comes from. Wazuh's alerts
// (OpenSearch): Caddy's access log (rules 100800 to 100802, with Caddy's own GeoIP fields
// from DB-IP City Lite) and the GeoLocation Wazuh's indexer adds from srcip (GeoLite2).
// Built to ansible/roles/monitoring/files/dashboards/attack.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;
local W = 'grafana-opensearch-datasource';
local on(p) = a.on(p, a.ds.wazuh, W);
local sum = g.panel.stat.options.reduceOptions.withCalcs(['sum']);

// Requests from the internet: the port's alerts whose address Caddy found in its database
// (private and NetBird addresses have no country).
local PUBLIC = 'rule.groups:netbird_public AND _exists_:data.geo_country';
local REFUSED = 'rule.id:100801 AND _exists_:data.geo_country';
local count(id='1') = { id: id, type: 'count' };
local distinct(field) = { id: '1', type: 'cardinality', field: field };

// The single requests, newest first, with Caddy's coordinates (for the map's markers).
local raw(query, size=500) = {
  datasource: { type: W, uid: a.ds.wazuh },
  query: query,
  queryType: 'lucene',
  luceneQueryType: 'RawData',
  timeField: 'timestamp',
  metrics: [{ id: '1', type: 'raw_data', settings: { size: std.toString(size), order: 'desc', useTimeRange: true } }],
  bucketAggs: [],
};

// Counts per geohash cell of a geo_point field (Wazuh's GeoLocation).
local cells(query) = {
  datasource: { type: W, uid: a.ds.wazuh },
  query: query,
  queryType: 'lucene',
  luceneQueryType: 'Metric',
  timeField: 'timestamp',
  metrics: [count()],
  bucketAggs: [{ id: '2', type: 'geohash_grid', field: 'GeoLocation.location', settings: { precision: '3' } }],
};

local map(title, target, location, size) = {
  type: 'geomap',
  title: title,
  datasource: { type: W, uid: a.ds.wazuh },
  targets: a.refs([target]),
  transformations: if location.mode == 'coords' then [{
    id: 'convertFieldType',
    options: { conversions: [
      { targetField: location.latitude, destinationType: 'number' },
      { targetField: location.longitude, destinationType: 'number' },
    ] },
  }] else [],
  fieldConfig: { defaults: { color: { mode: 'continuous-YlRd' } }, overrides: [] },
  options: {
    view: { id: 'zero', lat: 20, lon: 10, zoom: 1 },
    controls: { showZoom: true, mouseWheelZoom: true, showAttribution: true },
    basemap: { type: 'default', name: 'Basemap' },
    tooltip: { mode: 'details' },
    layers: [{
      type: 'markers',
      name: 'Requests',
      location: location,
      tooltip: true,
      config: {
        showLegend: true,
        style: {
          size: size,
          color: { fixed: 'dark-red' } + (if std.objectHas(size, 'field') then { field: size.field } else {}),
          opacity: 0.6,
          symbol: { mode: 'fixed', fixed: 'img/icons/marker/circle.svg' },
        },
      },
    }],
  },
};

a.dashboard('anvil-attack', 'Attack map',
            'Who reaches the public NetBird port, from where, and what they ask for, with every security alert that has an internet source. Managed by anvil: change dashboards/attack.jsonnet.',
            ['security', 'wazuh', 'geoip', 'netbird'])
+ g.dashboard.time.withFrom('now-7d')
+ g.dashboard.withPanels(a.rows([
  [
    a.note('How to read this', |||
      The lab has one public port: **TCP 443**, the self-hosted NetBird server. Every request to it is logged by Caddy with the client's **country, city and coordinates** (DB-IP City Lite, "IP Geolocation by DB-IP"). Most requests are your own devices and NetBird clients. **Refused** requests (400 to 405) are usually scanners looking for things that are not there. **50 refusals from one address in 2 minutes** raises a level 10 alert, which pages through Alertmanager. The bottom map shows every Wazuh alert with an internet source address, located by Wazuh (GeoLite2).
    |||) + { gridPos: { h: 3 } },
  ],
  [
    on(a.stat('Requests from the internet', [a.wazuh(PUBLIC)], 'none')) + sum + { gridPos: { h: 5 } },
    on(a.stat('Refused requests', [a.wazuh(REFUSED)], 'none', [['green', null], ['orange', 1], ['red', 100]])) + sum + { gridPos: { h: 5 } },
    on(a.stat('Scan alerts (level 10)', [a.wazuh('rule.id:100802')], 'none', [['green', null], ['red', 1]])) + sum + { gridPos: { h: 5 } },
    on(a.stat('Countries', [a.wazuh(PUBLIC, over='none', metric=distinct('data.geo_country'))], 'none')) + { gridPos: { h: 5 } },
    on(a.stat('Addresses', [a.wazuh(PUBLIC, over='none', metric=distinct('data.srcip'))], 'none')) + { gridPos: { h: 5 } },
  ],
  [
    map('Requests to the public port (Caddy GeoIP), each request a dot', raw(PUBLIC),
        { mode: 'coords', latitude: 'data.geo_lat', longitude: 'data.geo_lon' },
        { fixed: 6, min: 4, max: 12 }) + { gridPos: { h: 14, w: 16 } },
    on(a.table('Countries', [a.wazuh(PUBLIC, by='data.geo_country_name', size=20, over='none')])) + { gridPos: { h: 14, w: 8 } },
  ],
  [
    on(a.table('Cities', [a.wazuh(PUBLIC, by='data.geo_city', size=15, over='none')])),
    on(a.table('Addresses', [a.wazuh(PUBLIC, by='data.srcip', size=15, over='none')])),
    on(a.table('Refused paths (what scanners look for)', [a.wazuh(REFUSED, by='data.request.uri', size=15, over='none')])),
  ],
  [
    on(a.ts('Requests from the internet by answer', [a.wazuh(PUBLIC, by='data.status', size=10)], 'none')) + { gridPos: { h: 8 } },
  ],
  [
    map('Every security alert with an internet source (Wazuh GeoLite2)', cells('_exists_:GeoLocation.location'),
        { mode: 'geohash', geohash: 'GeoLocation.location' },
        { field: 'Count', fixed: 6, min: 4, max: 30 }) + { gridPos: { h: 12, w: 16 } },
    on(a.table('Rules behind them', [a.wazuh('_exists_:GeoLocation.location', by='rule.description', size=15, over='none')])) + { gridPos: { h: 12, w: 8 } },
  ],
]))
