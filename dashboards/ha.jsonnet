// Home Assistant: the home automation hub on the assistant VM. Is it up, how many entities,
// what is on, automation activity, sensor readings, battery levels, and the VM's own health
// (job homeassistant, role homeassistant's prometheus endpoint; node metrics for the VM).
// Built to ansible/roles/monitoring/files/dashboards/ha.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;

local H = '{job="homeassistant"}';
local N = '{job="node",host="assistant"}';
local onoff(on, off) = g.panel.stat.standardOptions.withMappings([
  { type: 'value', options: { '0': { text: off }, '1': { text: on } } },
]);

a.dashboard('anvil-homeassistant', 'Home Assistant',
            "The home automation hub on the assistant VM: up, entities, what is on, automation activity, sensors, batteries, and the VM's own health. Managed by anvil: change dashboards/ha.jsonnet.",
            ['homeassistant', 'smart-home'])
+ g.dashboard.withPanels(a.rows([
  [
    a.stat('Home Assistant', [a.q('max(up%s)' % H, 'HA')], 'none', [['red', null], ['green', 1]]) + onoff('Up', 'Down') + { gridPos: { h: 5 } },
    a.stat('Entities', [a.q('count(homeassistant_entity_available%s)' % H, 'Entities')], 'short') + { gridPos: { h: 5 } },
    a.stat('Switches on', [a.q('sum(homeassistant_switch_state%s)' % H, 'On')], 'short') + { gridPos: { h: 5 } },
    a.stat('Lights on', [a.q('sum(homeassistant_light_state%s)' % H, 'On')], 'short') + { gridPos: { h: 5 } },
    a.stat('Automations fired (24h)', [a.q('round(sum(increase(homeassistant_automation_triggered_count%s[24h])))' % H, 'Fired')], 'short') + { gridPos: { h: 5 } },
    a.stat('Assistant VM', [a.q('max(up%s)' % N, 'VM')], 'none', [['red', null], ['green', 1]]) + onoff('Up', 'Down') + { gridPos: { h: 5 } },
  ],
  [
    a.ts('State changes per second', [a.q('sum(rate(homeassistant_state_change_total%s[5m]))' % H, 'Changes')], 'short', 0),
    a.ts('Entities available', [a.q('sum(homeassistant_entity_available%s)' % H, 'Available')], 'short', 0),
  ],
  [
    a.ts('Temperatures', [a.q('homeassistant_sensor_temperature_celsius%s' % H, '{{friendly_name}}')], 'celsius'),
    a.ts('Humidity', [a.q('homeassistant_sensor_humidity_percent%s' % H, '{{friendly_name}}')], 'percent', 0, 100),
  ],
  [
    a.ts('Battery levels', [a.q('homeassistant_battery_level_percent%s' % H, '{{friendly_name}}')], 'percent', 0, 100),
    a.ts('Power', [a.q('homeassistant_sensor_power_w%s' % H, '{{friendly_name}}')], 'watt', 0),
  ],
  [
    a.ts('Assistant VM CPU', [a.q('100 - (avg(rate(node_cpu_seconds_total%s[5m])) * 100)' % '{job="node",host="assistant",mode="idle"}', 'CPU')], 'percent', 0, 100),
    a.ts('Assistant VM memory', [a.q('100 * (1 - node_memory_MemAvailable_bytes%s / node_memory_MemTotal_bytes%s)' % [N, N], 'Memory')], 'percent', 0, 100),
    a.ts('Assistant VM disk /', [a.q('100 * (1 - node_filesystem_avail_bytes%s / node_filesystem_size_bytes%s)' % ['{job="node",host="assistant",mountpoint="/"}', '{job="node",host="assistant",mountpoint="/"}'], 'Disk')], 'percent', 0, 100),
  ],
]))
