# The anvil CLI

`anvil` is one binary over the make targets. Make stays the source of truth. Every
command runs `bash -c 'source scripts/env.sh && make <target> ...'` in the repo root, with
your environment, so what the docs do by hand is what `anvil` does.

It never prints a secret, an address or the domain. It never logs the environment and
never adds a force flag. It exits with make's exit code. `--dry-run` prints the exact
commands and runs nothing.

## Install

Build it from the repo. You need Go. An older Go fetches the version that `cli/go.mod`
names on its own.

```sh
git clone https://github.com/memetics19/anvil && cd anvil
make cli                                  # builds build/anvil
sudo install -m 755 build/anvil /usr/local/bin/anvil
anvil version
```

The build is reproducible: the same commit builds the same bytes. Another platform:
`GOOS=linux GOARCH=amd64 make cli ANVIL_OUT=build/anvil-linux-amd64`.

`anvil` finds the repo by walking up from the current directory. From anywhere else, set
`ANVIL_REPO` to the repo's path.

## anvil up

One command builds the whole lab, or converges the running one:

```sh
anvil up
```

It runs the stages of [First build](setup.md#first-build) in their order. Every stage is
idempotent, so the same command works on a fresh box and on the running lab. On a lab that
matches the code, every check shows `changed=0` and nothing is applied.

1. It runs the checks of `anvil init`. A missing tool, SSH key or Keychain `pve-ip`
   stops it. Vault may still be down, because `anvil up` builds it.
2. It prints the plan: every stage, what it touches and its make commands.
3. It asks once. You type `up`. `--yes` skips this, for unattended runs.
4. It runs the stages in order. Each one runs its check first and applies only when the
   check shows changes. The first failure stops the run and prints the command to resume.

| Stage | What it does | Commands |
|---|---|---|
| `bootstrap-ssh-host` | Your SSH key on the Proxmox host | `make bootstrap-ssh ARGS="--limit proxmox"` |
| `host` | The Proxmox host base, without the `homepage` tag | `make host ARGS="--skip-tags homepage"` |
| `host-network` | The host network, with a timed rollback | `make host-network` |
| `ceph` | Ceph, the S3 gateway and the state bucket | `make ceph` |
| `s3-keys` | You copy the bucket's S3 keys into the Keychain | a pause |
| `tf-init` | `terraform init` | `make tf-init` |
| `tf` | The VMs and SDN, through the plan guard | `make tf-plan`, then `make tf-apply` |
| `vault` | The Vault server | `make vault` |
| `vault-init` | You initialize Vault once | a pause |
| `vault-unseal` | Unseals Vault | `make vault-unseal` |
| `vault-policies` | Vault policies | `make vault-policies` |
| `site-to-vault` | The site dict into Vault, unless Vault has it | `make site-to-vault` |
| `backup-key` | You create the backup key pair once | a pause |
| `secrets` | You put the secrets into Vault | a pause |
| `ceph-users` | Ceph again, for the S3 users that need Vault | `make ceph` |
| `host-homepage` | The dashboard's Proxmox token | `make host ARGS="--tags homepage"` |
| `enclave` | The secrets enclave | `make enclave` |
| `vlans` | VLANs 10, 20 and 30 | `make vlans` |
| `switch` | The Cisco switch | `make switch ARGS="-e network_switch_apply=true"` |
| `bootstrap-ssh-guests` | Your SSH key on the guests | `make bootstrap-ssh ARGS="--limit guests"` |
| `vms` | Every guest | `make vms` |
| `handsteps` | You do the hand steps once | a pause |
| `backup` | The backups | `make backup` |
| `status` | The dashboard | `anvil status` |

The check of an Ansible stage adds `--check --diff`. The check of `tf` is `make tf-plan`,
and of `switch` the plain `make switch`, which prints the planned commands.

Terraform is one stage. The plan guard refuses a targeted plan, so the Vault VM cannot be
planned on its own before the others. `provision` is never part of `anvil up`. It is for
new hardware only.

### Steps for you

Some steps need a person: the S3 keys, Vault's unseal keys, the backup key, the secrets,
and the dashboard steps in [Not managed here](setup.md#not-managed-here). Their stage
checks whether the step is done, for example whether the Keychain has `vault-init-json`.
When it is, the stage is skipped. When not, `anvil up` prints the exact commands and waits
for Enter. The `handsteps` stage cannot be checked, so Enter marks it done once.

With `--yes`, `anvil up` never waits. It stops at such a step with exit code 3 and the
command to resume.

### Resume and select

```sh
anvil up --from vault-unseal        # resume at a stage
anvil up --only vms                 # just these stages
anvil up --skip switch,handsteps    # all but these
anvil up --dry-run                  # the plan and the commands, nothing runs
```

`build/anvil-up.state` records the stages this run completed and the hand steps you
acknowledged.

### One service

```sh
anvil up pihole
anvil up pihole homepage
anvil up gateway iptv
```

With names, `anvil up` deploys only those. Each one runs its check, then applies only when
the check shows changes. It asks y/N once, and `--yes` skips that. A risky target, such as
`vlans`, still needs its name typed.

A name is a service, a VM or a lab target. `anvil services` lists them all.

## anvil services

```sh
anvil services
```

The services come from the code, so the list cannot drift. Every role tag in
`ansible/playbooks/vms.yml` is a service, on the hosts of its play, which the inventory
resolves. A service on one VM runs `make vm HOST=<vm> ARGS="--tags <tag>"`. A service on
several runs `make vms ARGS="--tags <tag>"`. A role's name works too, for example
`arr_stack` for `arr`.

A few short names are aliases: `gateway` is `caddy`, `dashboard` is `homepage`, and
`pi-hole` and `unbound` are `pihole`. A VM name, such as `apps`, runs every play for that
VM. The lab targets are the make targets of the table below.

When two meanings share a name, the lab target wins, then the VM. `vault` is the Vault
server (`make vault`). The guest plays on the `vault` VM are `anvil check vm --host vault`.
A name anvil does not know is refused, with the names close to it.

## Setup of a new checkout

You never run make yourself. Before `check`, `apply` and `up` do anything, anvil sets up
the checkout. A fresh clone or worktree has no `.terraform`, so anvil runs `tf-init` once.
When a collection in `ansible/requirements.yml` is missing, anvil installs them. Then it
goes on.

## Reachability

Before Terraform runs (`tf-init`, `tf` and the Terraform stages of `anvil up`), anvil
connects to the state store, Ceph S3 on port 7480 of the Proxmox host. Before a run that
reads the site dict from Vault, it checks that Vault answers. Each gets three tries, three
seconds apart. When one does not answer, anvil stops with a plain message and runs
nothing. Check that you are on the home or lab network, or on the VPN, then rerun. It
never prints the address.

## anvil init

```sh
anvil init
```

It checks, read-only, that this Mac can run the lab:

- the tools at the minimum versions in [setup.md](setup.md#operator-machine), and `hvac`
  in the Python that runs Ansible
- `~/.ssh/id_ed25519` and Vault's CA certificate
- the Keychain items of service `homelab`. It shows their names and whether each is there.
  It never reads a value.
- that Vault answers and is unsealed

Each problem prints its fix. It exits 1 when something is missing.

## anvil status

```sh
anvil status
```

A read-only dashboard. It marks each problem and ends with a count:

```
vault         unsealed
site source   vault, the Keychain copy is current
git           main, 0 ahead and 0 behind origin/main (as of the last fetch)
gateway       HTTPS status per name (000: no connection)
  pve         200
  dns         302
  pass        200
pi-hole       answering
backups       newest in ~/homelab-backups
  tfstate     17h ago
  vault       17h ago
  vaultwarden 17h ago
status: no problems
```

A problem is Vault not unsealed, a gateway name with `000` or a `5xx` code, Pi-hole not
answering, or a backup that is missing or older than 36 hours. A problem line says what is
wrong, for example `000  no connection` or `40h ago, stale (over 36h)`, and is red on a
terminal. The exit code is 0 either way, because the dashboard only reports.

The gateway lines check `https://<name>.<gateway-domain>/` for every enabled entry of
`site.services`. It prints the names and status codes only. It does not fetch from git, so
ahead and behind are as of your last fetch.

## anvil check

```sh
anvil check                          # host, vms and tf
anvil check apps                     # make vm HOST=apps ARGS="--check --diff"
anvil check vm --host apps           # the same
anvil check pihole                   # make vm HOST=apps ARGS="--check --diff --tags pihole"
anvil check tf                       # make tf-plan
anvil check switch                   # make switch, the planned commands
anvil check vms --tags docker
```

A dry run. It changes nothing. `make tf-plan` saves the plan that `make tf-apply` applies
later. `--host`, `--tags` and `--args` add to `HOST` and `ARGS`. `--args` refuses
`--force` and `-target`.

## anvil apply

```sh
anvil apply apps
anvil apply pihole --yes
anvil apply vlans
```

It runs the check first and prints the summary, for example `apps changed=2`. When the
check shows no changes, it stops there. Otherwise it asks y/N, which `--yes` skips, then
runs the real target.

These targets also need their name typed, even with `--yes`: `host-network`, `enclave`,
`vlans`, `switch` and `tf`. `tf` applies the plan its check saved, after the plan guard
runs again. The guards in the scripts still apply, and anvil adds no force flag.

| Target | Check | Apply |
|---|---|---|
| `bootstrap-ssh`, `host`, `ceph`, `vault`, `vms` | `make <target> ARGS="--check --diff"` | `make <target>` |
| `host-network`, `enclave`, `vlans` | `make <target> ARGS="--check --diff"` | `make <target>`, name typed |
| `switch` | `make switch` | `make switch ARGS="-e network_switch_apply=true"`, name typed |
| `tf` (`tf-plan`, `tf-apply`) | `make tf-plan` | `make tf-apply`, name typed |
| a VM, or `vm --host <vm>` | `make vm HOST=<vm> ARGS="--check --diff"` | `make vm HOST=<vm>` |
| a service | `make vm HOST=<vm> ARGS="--check --diff --tags <tag>"` | `make vm HOST=<vm> ARGS="--tags <tag>"` |

## anvil backup and anvil restore

```sh
anvil backup                         # make backup
anvil restore tfstate                # the newest Terraform state backup into the bucket
anvil restore tfstate ~/homelab-backups/tfstate-<YYYYMMDD-HHMM>.json.age
anvil restore drill                  # make vaultwarden-drill
```

`restore tfstate` prints the backup's serial first. Then you type `tfstate`, and it pushes
the state with `terraform state push`. Terraform refuses a different lineage or a lower
serial. Restoring Vault and Vaultwarden is not scripted. `anvil restore vault` and
`anvil restore vaultwarden` point at the steps in
[Rebuilding on a new box](setup.md#rebuilding-on-a-new-box).

## anvil provision-iso and anvil provision

```sh
anvil provision-iso pve2             # make provision-iso NAME=pve2
anvil provision pve2                 # make provision NAME=pve2, a dry run
anvil provision pve2 --install       # the dry run, the name typed, then the install
```

`--install` adds `ARGS="-e provision_confirm=<name>"`, and `--media-ready` adds
`-e provision_media_ready=true` for manual media. The guard in `scripts/provision.py`
still refuses the current server. See [provisioning.md](provisioning.md).

## Colors

On a terminal, anvil colors its own status words: `ok`, `warn` and `FAIL`, the stage
results of `anvil up` and the problems of `anvil status`. Piped output stays plain.
`NO_COLOR=1`, `TERM=dumb` or `--no-color` anywhere on the command line turn colors off.
The output of make and Ansible is passed on as it is.

## Exit codes

| Code | Meaning |
|---|---|
| make's code | The make target failed. anvil passes its code on. |
| 1 | You declined, or `anvil init` found a problem. |
| 2 | A usage error, or an unknown name. |
| 3 | `anvil up` stopped at a step that needs you. |

## Tests

```sh
cd cli && go vet ./... && go test ./...
```

The tests put a fake `make` on `PATH`. They cover the mapping from names to make commands,
the services read from the playbook, the confirmations, finding the repo, the stages of
`anvil up` with their pauses and resume, and that no output holds a value from the
environment. CI runs them and builds the binary for darwin/arm64 and linux/amd64.
