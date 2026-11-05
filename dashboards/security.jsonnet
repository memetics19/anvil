// Security: Wazuh's alerts in Grafana (read-only, from Wazuh's indexer), next to the metrics.
// Built to ansible/roles/monitoring/files/dashboards/security.json.
local a = import 'lib/anvil.libsonnet';
local g = a.g;
local W = 'grafana-opensearch-datasource';
local on(p) = a.on(p, a.ds.wazuh, W);
local sum = g.panel.stat.options.reduceOptions.withCalcs(['sum']);

a.dashboard('anvil-security', 'Security',
            "Wazuh's alerts: how many, how serious, which rules and hosts, failed logins, changed files and vulnerabilities. Managed by anvil: change dashboards/security.jsonnet.",
            ['security', 'wazuh'])
+ g.dashboard.withPanels(a.rows([
  [
    on(a.stat('Alerts, level 10 and up', [a.wazuh('rule.level:>=10')], 'none', [['green', null], ['orange', 1]])) + sum + { gridPos: { h: 5 } },
    on(a.stat('Critical, level 12 and up', [a.wazuh('rule.level:>=12')], 'none', [['green', null], ['red', 1]])) + sum + { gridPos: { h: 5 } },
    on(a.stat('Hosts reporting', [a.wazuh('*', over='none', metric={ id: '1', type: 'cardinality', field: 'agent.name' })], 'none'))
    + { gridPos: { h: 5 } },
  ],
  [
    on(a.ts('Alerts by level', [a.wazuh('rule.level:>=3', by='rule.level', size=16)], 'none')) + { gridPos: { h: 8 } },
  ],
  [
    on(a.table('Top rules', [a.wazuh('rule.level:>=5', by='rule.description', size=15, over='none')])),
    on(a.table('Top hosts', [a.wazuh('rule.level:>=5', by='agent.name', size=15, over='none')])),
  ],
  [
    on(a.ts('Failed logins', [a.wazuh('rule.groups:(authentication_failed OR authentication_failures)', by='agent.name')], 'none')),
    on(a.table('Changed files', [a.wazuh('rule.groups:syscheck', by='syscheck.path', size=20, over='none')])),
  ],
  [
    on(a.table('Vulnerabilities by severity', [a.wazuh('rule.groups:vulnerability-detector', by='data.vulnerability.severity', over='none')])),
    on(a.table('Vulnerable hosts', [a.wazuh('rule.groups:vulnerability-detector', by='agent.name', size=15, over='none')])),
  ],
]))
