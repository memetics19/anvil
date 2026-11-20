// NetBird: the self-hosted NetBird server on the netbird VM (job netbird_server, role
// netbird_server): is it up, how many peers are connected to management, signal and the relay,
// logins and peer changes, relay traffic, how fast it answers, its API errors, and the VM it
// runs on. Built to ansible/roles/monitoring/files/dashboards/netbird.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;

local J = '{job="netbird_server"}';
local sum(m) = 'sum(%s%s)' % [m, J];
local rate(m, w='5m') = 'sum(rate(%s%s[%s]))' % [m, J, w];
local p95(h) = 'histogram_quantile(0.95, sum by (le) (rate(%s_bucket%s[5m])))' % [h, J];
local up = [['red', null], ['green', 1]];

a.dashboard('anvil-netbird', 'NetBird',
            'The self-hosted NetBird server: up, peers on management, signal and the relay, logins, peer changes, relay traffic, answer times, API errors and its VM. Managed by anvil: change dashboards/netbird.jsonnet.',
            ['netbird', 'vpn'])
+ g.dashboard.withPanels(a.rows([
  [
    a.note('How to read this', |||
      The **self-hosted** network only (the cloud network has no metrics here). **Connected peers** are the devices holding a session with management right now, including `netbird-home`, the lab's routing peer. **Signal** helps two peers find each other, and the **relay** carries a connection when they cannot reach each other directly: relay traffic that stays high means peers are not connecting directly. Answer times are the slowest 5% (p95).
    |||) + { gridPos: { h: 3 } },
  ],
  [
    a.stat('Server', [a.q('max(up%s)' % J, 'Server')], 'none', up)
    + g.panel.stat.standardOptions.withMappings([{ type: 'value', options: { '0': { text: 'DOWN' }, '1': { text: 'UP' } } }])
    + { gridPos: { h: 5 } },
    a.stat('Connected peers', [a.q(sum('management_grpc_connected_streams_ratio'), 'Peers')], 'none', [['orange', null], ['green', 1]]) + { gridPos: { h: 5 } },
    a.stat('Peers on signal', [a.q(sum('signal_active_peers'), 'Signal')], 'none') + { gridPos: { h: 5 } },
    a.stat('Peers on the relay', [
      a.q(sum('relay_peers'), 'Connected'),
      a.q(sum('relay_peers_active'), 'Carrying traffic'),
    ], 'none') + { gridPos: { h: 5 } },
    a.stat('Logins, 24 hours', [a.q('round(sum(increase(management_grpc_login_request_counter_total%s[24h])))' % J, 'Logins')], 'none') + { gridPos: { h: 5 } },
    a.stat('API errors (5xx), 24 hours', [
      a.q('round(sum(increase(management_http_response_counter_code_total{job="netbird_server",code=~"5.."}[24h]))) or vector(0)', 'Errors'),
    ], 'none', [['green', null], ['orange', 1], ['red', 20]]) + { gridPos: { h: 5 } },
  ],
  [
    a.timeline('Server up and down', [a.q('max(up%s)' % J, 'NetBird server')]) + { gridPos: { h: 4 } },
  ],
  [
    a.ts('Peers over time', [
      a.q(sum('management_grpc_connected_streams_ratio'), 'Connected to management'),
      a.q(sum('signal_active_peers'), 'On signal'),
      a.q(sum('relay_peers'), 'On the relay'),
      a.q(sum('relay_peers_active'), 'Relay, carrying traffic'),
    ], 'none', 0),
    a.ts('Peers connecting and disconnecting (a minute)', [
      a.q('sum by (operation) (rate(management_account_peer_status_update_counter_total%s[5m])) * 60' % J, '{{operation}}'),
    ], 'none', 0),
  ],
  [
    a.ts('Logins and syncs (a minute)', [
      a.q(rate('management_grpc_login_request_counter_total') + ' * 60', 'Logins'),
      a.q(rate('management_grpc_sync_request_counter_total') + ' * 60', 'Syncs'),
      a.q(rate('signal_registrations_total') + ' * 60', 'Signal registrations'),
    ], 'none', 0),
    a.ts('Relay traffic', [
      a.q(rate('relay_transfer_sent_bytes_total'), 'Sent'),
      a.q(rate('relay_transfer_received_bytes_total'), 'Received'),
    ], 'Bps', 0),
  ],
  [
    a.ts('Management answer time (p95)', [
      a.q(p95('management_grpc_login_request_duration_ms_milliseconds'), 'Login'),
      a.q(p95('management_grpc_sync_request_duration_ms_milliseconds'), 'Sync'),
      a.q(p95('management_account_get_peer_network_map_duration_ms_milliseconds'), 'Network map'),
      a.q(p95('management_store_transaction_duration_ms_milliseconds'), 'Database transaction'),
    ], 'ms', 0),
    a.ts('Signal (p95) and messages', [
      a.q(p95('signal_message_forward_latency_milliseconds'), 'Message forward time'),
      a.q(p95('signal_registration_delay_milliseconds'), 'Registration time'),
    ], 'ms', 0),
  ],
  [
    a.ts('API answers by code (a minute)', [
      a.q('sum by (code) (rate(management_http_response_counter_code_total%s[5m])) * 60' % J, '{{code}}'),
    ], 'none', 0),
    a.ts('Signal messages forwarded (a minute)', [
      a.q(rate('signal_messages_forwarded_total') + ' * 60', 'Messages'),
    ], 'none', 0),
  ],
  [
    a.ts('netbird VM: CPU busy', [a.q('100 * (1 - avg(rate(node_cpu_seconds_total{host="netbird",mode="idle"}[5m])))', 'CPU')], 'percent', 0, 100),
    a.ts('netbird VM: memory used', [a.q('100 * (1 - node_memory_MemAvailable_bytes{host="netbird"} / node_memory_MemTotal_bytes{host="netbird"})', 'Memory')], 'percent', 0, 100),
  ],
]))
