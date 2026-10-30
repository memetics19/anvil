# Monitoring and alerting (roadmap)

A plan, not built yet. It is the next focus. It gives the lab one place to see how every
host and service is doing, and alerts that are worth reading when they arrive.

## Today

- **Pulse** checks that services answer and runs the public status page.
- **Homepage** shows a few live widgets.
- **The nightly `anvil drift`** pushes a message to ntfy when the lab no longer matches
  the code.
- **node_exporter** runs on some VMs, but nothing collects its metrics. The role pins
  version 1.0.1, from 2020, and it listens on every address.

What is missing:

- No history. When something is slow there is no graph to look at.
- No hardware alerts. A failed power supply on the second server was found by chance on
  the iDRAC page.
- No early warning for slow problems: a disk filling up, a ZFS pool degrading, a backup
  that quietly stopped.

## Goal

- Grafana is the only dashboard for metrics. Every dashboard is a JSON file in this repo.
- An alert means a human should act. A quiet week has no alerts.
- Everything is code. `anvil apply monitoring` builds it, the same as any other service.

## The stack

A `monitoring` VM on the second server, next to the other new workloads.

| Part | Role |
|---|---|
| VictoriaMetrics (single node) | Stores the metrics. Less memory and disk than Prometheus for the same data. 90 days kept |
| vmagent | Scrapes every exporter and writes to VictoriaMetrics |
| vmalert | Evaluates the alert rules |
| Alertmanager | Groups, silences and routes alerts to ntfy |
| Grafana | Dashboards. Behind the gateway, logging in through Authentik (OpenID Connect) |

What is scraped:

| Exporter | What it shows |
|---|---|
| node_exporter, upgraded and bound to the lab address | CPU, memory, disks, network on every VM and both Proxmox hosts |
| pve-exporter, with a read-only Proxmox token | VMs, storage and the cluster as Proxmox sees them |
| Ceph's own exporter (mgr module) | The Terraform state store |
| ZFS and SMART | Pool health and disks that are starting to fail |
| A Redfish exporter for both iDRACs | Power supplies, fans, temperatures, hardware events |
| cAdvisor | Each container's CPU and memory |
| A small backups exporter | The age of the newest Vault, Vaultwarden, Authentik and Terraform state backup |

Pulse stays as it is. It owns "is this service up" and the status page. The new stack
owns metrics and everything else. Each problem has exactly one owner, so it never alerts
twice.

## Alerts that are not noisy

These are the rules, not suggestions. A rule that breaks them is changed or removed.

1. **Alert on symptoms a person must act on.** A disk that will be full in three days,
   not a CPU spike. A failed power supply, a degraded pool, a sealed Vault, a backup older
   than 36 hours, a certificate that expires in 14 days.
2. **Every alert waits before it fires.** It has a `for:` duration, so a short blip never
   wakes anyone.
3. **Two levels only.**
   - Critical: pushed to the phone at once. Something is broken now.
   - Warning: one morning digest. Something needs attention this week.
4. **Grouped and inhibited.** One message per problem, not one per symptom. When a host is
   down, the alerts for the services on it are held back.
5. **Quiet during planned work.** `anvil apply` sets a silence for the hosts it touches
   and lifts it when it ends. The nightly drift check does not alert during an apply.
6. **Every alert links to its fix.** Each rule names a section of the docs that says what
   it means and what to do.
7. **Reviewed monthly.** Any alert that fired and needed no action is tuned or deleted.
   The aim is fewer than one critical alert a week.

## Steps

1. A `monitoring` VM on the second server (Terraform, the same pattern as the others).
2. The node_exporter role upgraded and bound to the lab address, on every host.
3. VictoriaMetrics, vmagent and Grafana. Grafana behind the gateway with Authentik.
4. The exporters above, one at a time, each with its dashboard as a JSON file.
5. vmalert and Alertmanager with the first small rule set: host down, disk fill, ZFS and
   SMART, power supplies, backups, certificates, Vault sealed.
6. `anvil apply` silences, and the drift check routed through Alertmanager.
7. Two weeks of tuning before more rules are added.

## Open questions

- Retention beyond 90 days, and whether old data moves to the Ceph store.
- Whether the warning digest goes to ntfy or to email.
