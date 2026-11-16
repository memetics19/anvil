// Disks: SMART health of every disk on the Proxmox nodes, their age, heat and the early signs
// of failure (job smart, role smartctl_exporter). Built to
// ansible/roles/monitoring/files/dashboards/smart.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;
local tb = g.panel.table;

local S = '{job="smart"}';
// One value per disk, whatever extra labels the metric carries.
local per(expr) = 'max by (host, device) (%s)' % expr;
local attr(name) = per('smartctl_device_attribute{job="smart",attribute_name="%s",attribute_value_type="raw"}' % name);
// Remapped bad sectors: the grown defect list on SAS, Reallocated_Sector_Ct on SATA.
local remapped = '(%s or %s)' % [per('smartctl_scsi_grown_defect_list' + S), attr('Reallocated_Sector_Ct')];
local uncorrected = per('smartctl_read_total_uncorrected_errors%s + smartctl_write_total_uncorrected_errors%s' % [S, S]);

local col(expr, ref) = a.q(expr, '') + g.query.prometheus.withInstant(true) + g.query.prometheus.withFormat('table') + { refId: ref };
local override(name, props) = { matcher: { id: 'byName', options: name }, properties: props };
local thresholds(steps) = { id: 'thresholds', value: { mode: 'absolute', steps: [{ color: s[0], value: s[1] } for s in steps] } };
local cell = { id: 'custom.cellOptions', value: { type: 'color-background' } };

// Every disk in one row: where it is, what it is, its health and its warning signs.
local disks =
  tb.new('Every disk')
  + tb.queryOptions.withDatasource('prometheus', a.ds.metrics)
  + tb.queryOptions.withTargets([
    col('max by (host, device, model_name) (smartctl_device%s)' % S, 'A'),
    col(per('smartctl_device_smart_status' + S), 'B'),
    col(per('smartctl_device_power_on_seconds' + S) + ' / 31557600', 'C'),
    col(per('smartctl_device_temperature{job="smart",temperature_type="current"}'), 'D'),
    col(remapped, 'E'),
    col(attr('Current_Pending_Sector'), 'F'),
    col(uncorrected, 'G'),
    col(per('smartctl_device_capacity_bytes' + S), 'H'),
  ])
  + tb.queryOptions.withTransformations([
    { id: 'merge', options: {} },
    { id: 'organize', options: {
      excludeByName: { Time: true, 'Value #A': true },
      indexByName: { host: 0, device: 1, model_name: 2, 'Value #H': 3, 'Value #B': 4, 'Value #C': 5, 'Value #D': 6, 'Value #E': 7, 'Value #F': 8, 'Value #G': 9 },
      renameByName: {
        host: 'Node', device: 'Disk', model_name: 'Model', 'Value #H': 'Size', 'Value #B': 'Health',
        'Value #C': 'Age', 'Value #D': 'Temp', 'Value #E': 'Remapped sectors', 'Value #F': 'Unreadable sectors',
        'Value #G': 'Uncorrected errors',
      },
    } },
  ])
  + tb.options.withSortBy([{ displayName: 'Remapped sectors', desc: true }])
  + tb.standardOptions.withNoValue('-')
  + tb.standardOptions.withOverrides([
    override('Size', [{ id: 'unit', value: 'bytes' }, { id: 'decimals', value: 1 }]),
    override('Health', [
      { id: 'mappings', value: [{ type: 'value', options: { '0': { text: 'FAILING', color: 'red' }, '1': { text: 'OK', color: 'green' } } }] },
      cell,
    ]),
    override('Age', [{ id: 'unit', value: 'suffix: years' }, { id: 'decimals', value: 1 }, thresholds([['green', null], ['orange', 5], ['red', 7]]), cell]),
    override('Temp', [{ id: 'unit', value: 'celsius' }, thresholds([['green', null], ['orange', 45], ['red', 55]]), cell]),
    override('Remapped sectors', [thresholds([['green', null], ['orange', 1], ['red', 100]]), cell]),
    override('Unreadable sectors', [thresholds([['green', null], ['red', 1]]), cell]),
    override('Uncorrected errors', [thresholds([['green', null], ['red', 1]]), cell]),
  ]);

a.dashboard('anvil-smart', 'Disks',
            'SMART health of every disk on the Proxmox nodes: health, age, temperature and the early signs of failure. Managed by anvil: change dashboards/smart.jsonnet.',
            ['smart', 'disks', 'hardware'])
+ g.dashboard.withPanels(a.rows([
  [
    a.stat('Disks reporting', [a.q('count(smartctl_device_smart_status%s)' % S, 'Disks')], 'short') + { gridPos: { h: 5 } },
    a.stat('Failing SMART', [a.q('count(smartctl_device_smart_status%s == 0) or vector(0)' % S, 'Failing')], 'short', [['green', null], ['red', 1]]) + { gridPos: { h: 5 } },
    a.stat('Disks with remapped sectors', [a.q('count(%s > 0) or vector(0)' % remapped, 'Disks')], 'short', [['green', null], ['orange', 1]]) + { gridPos: { h: 5 } },
    a.stat('Unreadable sectors', [a.q('sum(%s) or vector(0)' % attr('Current_Pending_Sector'), 'Sectors')], 'short', [['green', null], ['red', 1]]) + { gridPos: { h: 5 } },
    a.stat('Hottest disk', [a.q('max(smartctl_device_temperature{job="smart",temperature_type="current"})', 'Hottest')], 'celsius', [['green', null], ['orange', 45], ['red', 55]]) + { gridPos: { h: 5 } },
    a.stat('Oldest disk', [a.q('max(smartctl_device_power_on_seconds%s) / 31557600' % S, 'Oldest')], 'none', [['green', null], ['orange', 5], ['red', 7]])
    + g.panel.stat.standardOptions.withUnit('suffix: years') + g.panel.stat.standardOptions.withDecimals(1) + { gridPos: { h: 5 } },
  ],
  [disks + { gridPos: { h: 12 } }],
  [
    a.ts('Remapped sectors (a rising line is a disk going bad)', [a.q(remapped, '{{host}} {{device}}')], 'short', 0),
    a.ts('Temperature', [a.q(per('smartctl_device_temperature{job="smart",temperature_type="current"}'), '{{host}} {{device}}')], 'celsius'),
  ],
  [
    a.note('How disks wear out', |||
      **Hard disks** do not wear out by writing. They fail mechanically: heads, motor, surface. The early signs are
      **remapped sectors** (the disk replaced a bad spot with a spare) and **unreadable sectors** (a spot it could not read,
      waiting to be remapped). A few remapped sectors over years is normal. A count that **keeps rising** means the surface
      is going: replace the disk. Most enterprise disks are rated for about 5 years of running, which is why Age turns
      orange at 5 and red at 7.

      **SSDs and NVMe** wear out by writing: each flash cell takes a limited number of writes. Their **percentage used**
      (SsdWornOut fires at 80%) is the wear gauge.

      **Health OK** only means the disk has not given up yet. Watch the trend, not the word.
    |||) + { gridPos: { h: 9 } },
  ],
]))
