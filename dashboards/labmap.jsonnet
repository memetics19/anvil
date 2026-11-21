// Lab map: the whole lab drawn as a diagram (Canvas panel). The internet, the router, the two
// Proxmox nodes with their live traffic, every VM and the services on it, each box green when
// it answers and red when it does not (jobs ping, node, service, netbird_server). Built to
// ansible/roles/monitoring/files/dashboards/labmap.json.
//
// The layout below is the lab's shape: which VM runs on which node, and which gateway service
// on which VM. Change it here when a VM or a service moves (names only, no addresses).
local a = import 'lib/anvil.libsonnet';
local g = a.g;

// status: how a box knows it is up. node = node_exporter on that host, svc = the gateway's
// check of that service, nb = the self-hosted NetBird server's metrics.
local vm(name, status, services) = { name: name, status: status, services: services };
local layout = {
  pve: {
    pages: ['pve', 'ceph', 'idrac'],
    vms: [
      vm('apps', 'node', ['dns', 'home', 'docs']),
      vm('frigate', 'node', ['frigate', 'gotify']),
      vm('netbird', 'node', ['ntfy', 'pulse', 'nb:netbird server']),
      vm('ragnarok', 'node', ['sonarr', 'radarr', 'prowlarr', 'jackett', 'bazarr', 'qbit', 'files', 'youtube', 'threadfin', 'tv']),
      vm('vault', 'svc:vault', ['vault']),
      vm('vaultwarden', 'svc:pass', ['pass']),
    ],
  },
  pve2: {
    pages: ['pve2'],
    vms: [
      vm('dispatcharr', 'node', ['dispatcharr']),
      vm('identity', 'node', ['auth']),
      vm('monitoring', 'node', ['grafana']),
      vm('wazuh', 'svc:wazuh', ['wazuh']),
    ],
  },
};

// --- queries: one field per box, named <kind>:<name> ---------------------------------------------
local svcName(s) = if std.startsWith(s, 'nb:') then std.substr(s, 3, std.length(s) - 3) else s;
local svcField(s) = if std.startsWith(s, 'nb:') then 'nb:server' else 'svc:' + s;
local vmField(v) = if v.status == 'node' then 'node:' + v.name else v.status;
local allVms = layout.pve.vms + layout.pve2.vms;
local services = std.uniq(std.sort(std.flattenArrays(
  [[s for s in v.services if !std.startsWith(s, 'nb:')] for v in allVms]
  + [layout.pve.pages, layout.pve2.pages, ['switch']]
)));
// pve2 has no node_exporter yet: its box follows the check of its Proxmox page.
local nodeHosts = ['pve'] + [v.name for v in allVms if v.status == 'node'];
local nodeField(n) = if n == 'pve2' then 'svc:pve2' else 'node:' + n;

local inst(expr, field) = a.q(expr, field) + g.query.prometheus.withInstant(true);
local queries =
  [
    inst('max(probe_success{job="ping",scope="internet"})', 'net:internet'),
    inst('max(probe_success{job="ping",probe="router"})', 'net:router'),
    inst('max(up{job="netbird_server"})', 'nb:server'),
    inst('8 * sum(rate(node_network_receive_bytes_total{host="pve",device="vmbr0"}[5m]))', 'traffic:pve in'),
    inst('8 * sum(rate(node_network_transmit_bytes_total{host="pve",device="vmbr0"}[5m]))', 'traffic:pve out'),
    // One speed test an hour: the last one in the past 2 hours.
    inst('max(last_over_time(speedtest_download_speed_bps[2h]))', 'traffic:speed test'),
  ]
  + [inst('max(up{job="node",host="%s"})' % h, 'node:' + h) for h in nodeHosts]
  + [inst('max(probe_success{job="service",service="%s"})' % s, 'svc:' + s) for s in services];

// --- drawing ---------------------------------------------------------------------------------------
local colW = 160;
local boxW = 146;
local margin = 16;
local vmTop = 300;
local svcTop = vmTop + 62;
local svcH = 28;
local svcGap = 34;

local link(target, field) = {
  source: { x: 0, y: -1 },
  target: { x: 0, y: 1 },
  targetName: target,
  path: 'straight',
  color: { field: field, fixed: '#8e8e8e' },
  size: { fixed: 2, min: 1, max: 10 },
};

local box(name, label, field, left, top, w, h, size, links=[]) = {
  type: 'rectangle',
  name: name,
  config: {
    text: { mode: 'fixed', fixed: label },
    color: { fixed: '#0b0c0e' },
    size: size,
    align: 'center',
    valign: 'middle',
  },
  background: { color: { field: field, fixed: '#8e8e8e' } },
  border: { color: { fixed: 'transparent' }, width: 0, radius: 6 },
  placement: { left: left, top: top, width: w, height: h },
  constraint: { horizontal: 'left', vertical: 'top' },
  connections: links,
};

local value(name, field, left, top, w) = {
  type: 'metric-value',
  name: name,
  config: {
    text: { mode: 'field', field: field, fixed: '' },
    color: { fixed: '#ccccdc' },
    size: 12,
    align: 'center',
    valign: 'middle',
  },
  background: { color: { fixed: 'transparent' } },
  border: { color: { fixed: 'transparent' }, width: 0 },
  placement: { left: left, top: top, width: w, height: 18 },
  constraint: { horizontal: 'left', vertical: 'top' },
};

local label(name, text, left, top, w) = {
  type: 'text',
  name: name,
  config: { text: { mode: 'fixed', fixed: text }, color: { fixed: '#8e8e8e' }, size: 11, align: 'center', valign: 'middle' },
  background: { color: { fixed: 'transparent' } },
  border: { color: { fixed: 'transparent' }, width: 0 },
  placement: { left: left, top: top, width: w, height: 16 },
  constraint: { horizontal: 'left', vertical: 'top' },
};

// Columns: the pve VMs, then the pve2 VMs, left to right.
local nPve = std.length(layout.pve.vms);
local colLeft(i) = margin + i * colW;
local width = margin * 2 + std.length(allVms) * colW;
local center(l, r) = (colLeft(l) + colLeft(r) + boxW) / 2;

local vmElements(vms, offset) = std.flattenArrays([
  local v = vms[i];
  local left = colLeft(offset + i);
  [box('vm ' + v.name, v.name, vmField(v), left, vmTop, boxW, 44, 15)]
  + [
    box('svc ' + v.name + ' ' + svcName(v.services[j]), svcName(v.services[j]), svcField(v.services[j]),
        left + 8, svcTop + j * svcGap, boxW - 16, svcH, 12)
    for j in std.range(0, std.length(v.services) - 1)
  ]
  for i in std.range(0, std.length(vms) - 1)
]);

local nodeBox(n, vms, first, last) =
  local cx = center(first, last);
  box('node ' + n, n, nodeField(n), cx - 110, 180, 220, 50, 18,
      [link('vm ' + v.name, vmField(v)) for v in vms]);

local pveCx = center(0, nPve - 1);
local pve2Cx = center(nPve, std.length(allVms) - 1);
local midX = width / 2;

local elements =
  [
    box('internet', 'internet', 'net:internet', midX - 90, 8, 180, 44, 16, [link('router', 'net:router')]),
    value('speed', 'traffic:speed test', midX + 100, 22, 200),
    box('router', 'router', 'net:router', midX - 90, 92, 180, 44, 16,
        [link('node pve', 'node:pve'), link('node pve2', 'svc:pve2'), link('switch', 'svc:switch')]),
    box('switch', 'switch', 'svc:switch', midX + 160, 98, 120, 32, 13),
    nodeBox('pve', layout.pve.vms, 0, nPve - 1),
    value('pve in', 'traffic:pve in', pveCx - 110, 232, 110),
    value('pve out', 'traffic:pve out', pveCx, 232, 110),
    nodeBox('pve2', layout.pve2.vms, nPve, std.length(allVms) - 1),
  ]
  + [
    box('page ' + layout.pve.pages[k], layout.pve.pages[k], 'svc:' + layout.pve.pages[k],
        pveCx + 120 + k * 78, 190, 72, 28, 11)
    for k in std.range(0, std.length(layout.pve.pages) - 1)
  ]
  + [box('page pve2', 'pve2 ui', 'svc:pve2', pve2Cx + 120, 190, 72, 28, 11)]
  + [
    label('legend in', 'numbers under pve: its traffic in and out', margin, 8, 300),
    label('legend speed', 'last speed test, download', midX + 100, 6, 200),
  ]
  + vmElements(layout.pve.vms, 0)
  + vmElements(layout.pve2.vms, nPve);

local maxServices = std.foldl(std.max, [std.length(v.services) for v in allVms], 0);
local heightPx = svcTop + maxServices * svcGap + 20;

local map = {
  type: 'canvas',
  title: 'The lab',
  datasource: { type: 'prometheus', uid: a.ds.metrics },
  targets: a.refs(queries),
  gridPos: { h: std.ceil(heightPx / 30) + 2, w: 24, x: 0, y: 0 },
  fieldConfig: {
    defaults: {
      color: { mode: 'thresholds' },
      thresholds: { mode: 'absolute', steps: [{ color: 'red', value: null }, { color: 'green', value: 1 }] },
      mappings: [{ type: 'value', options: { '0': { text: 'DOWN', color: 'red' }, '1': { text: 'UP', color: 'green' } } }],
    },
    overrides: [
      {
        matcher: { id: 'byRegexp', options: '^traffic:.*' },
        properties: [
          { id: 'unit', value: 'bps' },
          { id: 'decimals', value: 1 },
          { id: 'mappings', value: [] },
          { id: 'color', value: { mode: 'fixed', fixedColor: 'text' } },
        ],
      },
    ],
  },
  options: {
    inlineEditing: false,
    showAdvancedTypes: true,
    panZoom: true,
    infinitePan: false,
    root: {
      type: 'frame',
      name: 'Element root',
      background: { color: { fixed: 'transparent' } },
      border: { color: { fixed: 'transparent' } },
      constraint: { horizontal: 'left', vertical: 'top' },
      elements: elements,
    },
  },
};

local downNow =
  a.table('Not answering right now', [
    a.q('max by (service) (probe_success{job="service"}) == 0', '{{service}}') + g.query.prometheus.withInstant(true) + g.query.prometheus.withFormat('table'),
  ]);

a.dashboard('anvil-labmap', 'Lab map',
            'The whole lab as a diagram: the internet, the router, both Proxmox nodes with live traffic, every VM and the services on it, green when it answers and red when it does not. Managed by anvil: change dashboards/labmap.jsonnet.',
            ['lab', 'map', 'overview'])
+ g.dashboard.withPanels([
  map,
  a.note('How to read this', |||
    Every box is checked live: **green** answers, **red** does not, **grey** has no data. Hosts are checked by node_exporter, services by the gateway's checks (the **SLA** dashboard has the detail), the NetBird server by its own metrics. The lines carry the colour of what they lead to, so a red line shows where the break is. The numbers by each node are its network traffic in and out. Scroll to zoom, drag to move.
  |||) + { gridPos: { h: 3, w: 16, x: 0, y: 100 } },
  downNow + { gridPos: { h: 6, w: 8, x: 16, y: 100 } },
])
