// Frigate: is it up, which cameras send video, how fast is detection, and how much room is
// left for recordings (job frigate, Frigate's /api/metrics). Built to
// ansible/roles/monitoring/files/dashboards/frigate.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;

local REC = 'storage="/media/frigate/recordings"';
local cam(metric) = a.q('%s{job="frigate"}' % metric, '{{camera_name}}');

a.dashboard('anvil-frigate', 'Frigate',
            'The camera recorder: up now, cameras sending video, frames per second per camera, detector speed, detections, CPU and memory, and recording space. Managed by anvil: change dashboards/frigate.jsonnet.',
            ['frigate', 'cameras'])
+ g.dashboard.withPanels(a.rows([
  [
    a.stat('Frigate now', [a.q('max(up{job="frigate"})', 'Frigate')], 'none', [['red', null], ['green', 1]])
    + g.panel.stat.standardOptions.withMappings([
      { type: 'value', options: { '0': { text: 'Down' }, '1': { text: 'Up' } } },
    ]) + { gridPos: { h: 5 } },
    a.stat('Cameras sending video', [
      a.q('count(frigate_camera_fps{job="frigate"} > 0) or vector(0)', 'Sending'),
      a.q('count(frigate_camera_fps{job="frigate"})', 'Of'),
    ], 'none') + { gridPos: { h: 5 } },
    a.stat('Detector speed', [a.q('max(frigate_detector_inference_speed_seconds{job="frigate"})', '{{name}}')],
           's', [['green', null], ['orange', 0.1], ['red', 0.2]]) + { gridPos: { h: 5 } },
    a.stat('Recording space free', [
      a.q('100 * frigate_storage_free_bytes{job="frigate",%s} / frigate_storage_total_bytes{job="frigate",%s}' % [REC, REC], 'Free'),
    ], 'percent', [['red', null], ['orange', 10], ['green', 25]]) + { gridPos: { h: 5 } },
  ],
  [
    a.timeline('Cameras', [a.q('frigate_camera_fps{job="frigate"} > bool 0', '{{camera_name}}')]) + { gridPos: { h: 6 } },
  ],
  [
    a.ts('Frames received per second', [cam('frigate_camera_fps')], 'none', 0),
    a.ts('Frames processed per second', [cam('frigate_process_fps')], 'none', 0),
  ],
  [
    a.ts('Detections per second', [cam('frigate_detection_fps')], 'none', 0),
    a.ts('Frames skipped per second', [cam('frigate_skipped_fps')], 'none', 0),
  ],
  [
    a.ts('Detector speed', [a.q('frigate_detector_inference_speed_seconds{job="frigate"}', '{{name}}')], 's', 0),
    a.ts('Detections by camera and object, per hour', [
      a.q('sum by (camera, label) (increase(frigate_camera_events_total{job="frigate"}[1h]))', '{{camera}} {{label}}'),
    ], 'none', 0),
  ],
  [
    a.ts('CPU per camera and detector', [
      a.q('sum by (name) (frigate_cpu_usage_percent{job="frigate",type=~"Camera|detectors"})', '{{name}}'),
      a.q('frigate_cpu_usage_percent{job="frigate",name="full_system"}', 'whole VM'),
    ], 'percent', 0),
    a.ts('Memory per camera and detector', [
      a.q('sum by (name) (frigate_mem_usage_percent{job="frigate",type=~"Camera|detectors"})', '{{name}}'),
    ], 'percent', 0),
  ],
  [
    a.ts('Disk space used', [
      a.q('100 * frigate_storage_used_bytes{job="frigate"} / frigate_storage_total_bytes{job="frigate"}', '{{storage}}'),
    ], 'percent', 0, 100),
  ],
]))
