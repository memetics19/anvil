# The anvil CLI

`anvil` is one binary over the make targets. Make stays the source of truth. Every
command runs `bash -c 'source scripts/env.sh && make <target> ...'` in the repo root, with
your environment. What the docs do by hand is what `anvil` does.

- It never prints a secret, an address or the domain.
- It never logs the environment and never adds a force flag.
- It exits with make's exit code.
- `--dry-run` prints the exact commands and runs nothing.

## Install

[install.md](install.md) has every way: Homebrew, the .deb and .rpm packages and the build
from source. The build needs Go. An older Go fetches the version that `cli/go.mod` names
by itself.

```sh
git clone https://github.com/memetics19/anvil && cd anvil
make cli                                  # builds build/anvil
sudo install -m 755 build/anvil /usr/local/bin/anvil
anvil version
```

`anvil version` prints the version, the commit and date it was built from, the Go version
and the platform. `make cli` sets them from git. The date is the commit's, not the
clock's. So the build is reproducible: the same commit builds the same bytes. For another
platform:
`GOOS=linux GOARCH=amd64 make cli ANVIL_OUT=build/anvil-linux-amd64`.

`anvil` looks for the repo in this order:

1. `ANVIL_REPO`, when it is set to the repo's path
2. the current directory and its parents
3. the copy that `anvil fetch` made

When there is no copy yet, a command run at a terminal offers to fetch it, then carries
on. In a script it stops with an error.

## anvil fetch and anvil update

A packaged `anvil` (Homebrew, .deb or .rpm, see [install.md](install.md)) comes without
the repo. Fetch it once:

```sh
anvil fetch     # clones the repo into ~/.local/share/anvil/repo
anvil doctor
```

`anvil fetch` clones `https://github.com/memetics19/anvil` into
`~/.local/share/anvil/repo`, or into `$XDG_DATA_HOME/anvil/repo` when that is set.

- A release binary checks out its own tag, `v0.1.0` for anvil 0.1.0.
- A dev build checks out `main`.
- `ANVIL_REPO_URL` clones a fork instead.

`anvil update` moves that copy to the binary's version: the new tag after an upgrade, or
the newest `main` for a dev build. It refuses when the copy has local changes.

Both work only on that copy, never on a checkout of yours. The copy lives in your home,
not in `/usr/share`, because runs write `build/` and `terraform/.terraform` inside the
repo.

## anvil up

`anvil up` builds the whole lab, or converges the running one:

```sh
anvil up
```

It runs the stages of [First build](setup.md#first-build) in order. Every stage is
idempotent, so the same command works on a fresh box and on the running lab. On a lab that
matches the code, every check shows `changed=0` and nothing is applied.

1. It runs the checks of `anvil init`. A missing tool, SSH key or Keychain `pve-ip`
   stops it. Vault may still be down, because `anvil up` builds it.
2. It prints the plan: every stage, what it touches and its make commands.
3. It asks once. You type `up`. `--yes` skips this, for unattended runs.
4. It runs the stages in order. Each stage runs its check first and applies only when the
   check shows changes. The first failure stops the run and prints the command to resume.
5. It prints a summary table, also after a failure.

Each stage starts with a header such as `stage 3/24: host-network`. It ends with its
result and time, for example `stage 3/24: host-network unchanged in 41.2s`. The summary
lists every stage with its result and time:

```
anvil up: summary
  host-network  unchanged  41.2s
  ceph          applied    3m12s
  s3-keys       skipped    0.3s
  tf-init       applied    6.1s
  tf            failed     58.0s
  vault         not run
  total                    4m58s  (1 unchanged, 2 applied, 1 skipped, 1 failed, 1 not run)
```

| Result | Meaning |
|---|---|
| `unchanged` | The check showed no changes. |
| `applied` | The stage applied changes. |
| `skipped` | Already done. |
| `failed` | The stage failed. |
| `stopped` | A step that needs you. |
| `not run` | After a stop. |

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

The checks:

- An Ansible stage adds `--check --diff`.
- `tf` runs `make tf-plan`.
- `switch` runs the plain `make switch`, which prints the planned commands.

Terraform is one stage. The plan guard refuses a targeted plan, so the Vault VM cannot be
planned on its own before the others. `provision` is never part of `anvil up`. It is for
new hardware only.

### Steps for you

Some steps need a person: the S3 keys, Vault's unseal keys, the backup key, the secrets,
and the dashboard steps in [Not managed here](setup.md#not-managed-here). Their stage
checks whether the step is done, for example whether the Keychain has `vault-init-json`.

- Done: the stage is skipped.
- Not done: `anvil up` prints the exact commands and waits for Enter.
- The `handsteps` stage cannot be checked, so Enter marks it done once.

With `--yes`, `anvil up` never waits. It stops at such a step with exit code 3 and prints
the command to resume.

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
the check shows changes. The same headers and summary table show each one. It asks y/N
once, and `--yes` skips that. A risky target, such as `vlans`, still needs its name typed.

A name is a service, a VM or a lab target. `anvil services` lists them all.

## anvil services

```sh
anvil services
```

The services come from the code, so the list cannot drift. Every role tag in
`ansible/playbooks/vms.yml` is a service. It runs on the hosts of its play, which the
inventory resolves.

| Name | Runs |
|---|---|
| a service on one VM | `make vm HOST=<vm> ARGS="--tags <tag>"` |
| a service on several VMs | `make vms ARGS="--tags <tag>"` |
| a VM name, such as `apps` | every play for that VM |
| a lab target | the make target, see the table under [anvil apply](#anvil-apply) |

A role's name works too, for example `arr_stack` for `arr`. A few short names are aliases:

| Alias | Service |
|---|---|
| `gateway` | `caddy` |
| `dashboard` | `homepage` |
| `pi-hole`, `unbound` | `pihole` |

When two meanings share a name, the lab target wins, then the VM. `vault` is the Vault
server (`make vault`). The guest plays on the `vault` VM are `anvil check vm --host vault`.
anvil refuses a name it does not know and lists the names close to it.

## Setup of a new checkout

You never run make yourself. Before `check`, `apply` and `up` do anything, anvil sets up
the checkout, then goes on:

- A fresh clone or worktree has no `.terraform`, so anvil runs `tf-init` once.
- When a collection in `ansible/requirements.yml` is missing, anvil installs them.

## Reachability

anvil checks two endpoints before it runs anything that needs them:

- Before Terraform runs (`tf-init`, `tf` and the Terraform stages of `anvil up`): the
  state store, Ceph S3 on port 7480 of the Proxmox host.
- Before a run that reads the site dict from Vault: that Vault answers.

Each gets three tries, three seconds apart. When one does not answer, anvil stops with a
plain message and runs nothing. It never prints the address. Check that you are on the
home or lab network, or on the VPN, then rerun. On macOS the cause can also be the Local
Network permission of your terminal app. See
[No route to host on macOS](#no-route-to-host-on-macos).

## anvil doctor and anvil init

```sh
anvil doctor          # the same as anvil init
anvil doctor --fix    # macOS: first remove lab routes that hide the VPN
```

`anvil doctor` and `anvil init` run the same read-only checks that this Mac can run the
lab:

- the tools at the minimum versions in [setup.md](setup.md#operator-machine), and `hvac`
  in the Python that runs Ansible
- `~/.ssh/id_ed25519` and Vault's CA certificate
- the Keychain items of service `homelab`. It shows their names and whether each is there.
  It never reads a value.
- that Vault answers and is unsealed
- that this binary's version matches the repo checkout. A release binary wants the
  repo at its tag, a dev build wants the commit it was built from. A mismatch is a
  warning, with the fix: `anvil update` for the fetched copy, `make cli` or a
  `git checkout` for your own
- macOS only: that no lab address alias or lab route left on the Wi-Fi or a USB adapter
  hides the VPN's route to the lab. It prints counts and the interface, never an address.

Each problem prints its fix. It exits 1 when something is missing.

`anvil doctor --fix` removes those aliases and routes before the checks. It shows what it
found and asks first. Then it runs `ifconfig -alias` and `route delete` with sudo, which
asks for your password. It acts only when all of these hold:

- a lab address does not answer
- its route uses a non-VPN interface
- a VPN route covers it

At home, with a cable into the lab or a direct route that works, it finds nothing.
Nothing in the lab changes.

## anvil status

```sh
anvil status
```

A read-only dashboard. It marks each problem and ends with a count of them:

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

A problem is one of these:

- Vault is not unsealed
- a gateway name returns `000` or a `5xx` code
- Pi-hole does not answer
- a backup is missing or older than 36 hours

A problem line says what is wrong, for example `000  no connection` or
`40h ago, stale (over 36h)`. It is red on a terminal. The exit code is 0 either way,
because the dashboard only reports.

The gateway lines check `https://<name>.<gateway-domain>/` for every enabled entry of
`site.services`. They print the names and status codes only. `anvil status` does not fetch
from git, so ahead and behind are as of your last fetch.

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
later.

`--host`, `--tags` and `--args` add to `HOST` and `ARGS`. `--args` refuses `--force` and
`-target`.

## anvil apply

```sh
anvil apply apps
anvil apply pihole --yes
anvil apply vlans
```

1. It runs the check and prints the summary, for example `apps changed=2`.
2. When the check shows no changes, it stops there.
3. Otherwise it asks y/N, which `--yes` skips, then runs the real target.

`host-network`, `enclave`, `vlans`, `switch` and `tf` also need their name typed, even
with `--yes`. `tf` applies the plan its check saved, after the plan guard runs again. The
guards in the scripts still apply, and anvil adds no force flag.

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

`restore tfstate` prints the backup's serial first. You type `tfstate`, then it pushes the
state with `terraform state push`. Terraform refuses a different lineage or a lower
serial.

Restoring Vault and Vaultwarden is not scripted. `anvil restore vault` and
`anvil restore vaultwarden` point at the steps in
[Rebuilding on a new box](setup.md#rebuilding-on-a-new-box).

## anvil provision-iso and anvil provision

```sh
anvil provision-iso pve2             # make provision-iso NAME=pve2
anvil provision pve2                 # make provision NAME=pve2, a dry run
anvil provision pve2 --install       # the dry run, the name typed, then the install
```

| Flag | Adds |
|---|---|
| `--install` | `ARGS="-e provision_confirm=<name>"` |
| `--media-ready` | `-e provision_media_ready=true`, for manual media |

The guard in `scripts/provision.py` still refuses the current server. See
[provisioning.md](provisioning.md).

## anvil increase-disk

Makes a VM's disk bigger while it runs. Nothing stops and nothing is unmounted.

```sh
anvil increase-disk ragnarok 600gb            # adds 600 GB (1 TB = 1024 GB)
anvil increase-disk frigate 100 --mount /home # LVM with several volumes: name the one
```

It runs `make grow-disk HOST=<vm> ADD=<GB> CHECK=1` first and shows the result. Then it
asks and runs it for real. `--yes` skips the question. The real run:

1. The current size comes from Proxmox. Terraform plans the new size, held in memory
   only. The plan must pass `scripts/plan-guard.sh` and change nothing but that disk's
   size. The guard refuses a disk that gets smaller.
2. The new size goes into the site dict in Vault (`site.hosts.<vm>.disk_gb`), and the
   saved plan is applied. Proxmox grows the disk of the running VM. The provider never
   reboots a VM (`reboot_after_update = false`).
3. The role `grow_disk` grows the partition that ends last on the disk (`growpart`), then
   its filesystem (`resize2fs`, `xfs_growfs`), or for LVM the physical volume and the
   logical volume with its filesystem (`lvextend -r`). All of it while mounted.

Only the partition at the end of the disk can grow this way. On ragnarok that is `/home`,
which holds the media library. Its root partition (`/`) sits before it and cannot grow
online.

## anvil media

Finds and downloads movies and series through Radarr and Sonarr on the media VM. They
search the indexers through Prowlarr and hand each download to qBittorrent.

```sh
anvil media search interstellar          # what matches, and what is already in the library
anvil media get interstellar             # asks which match, adds it, starts the download
anvil media get "the expanse" --tv       # a series: every season, missing episodes searched
anvil media get dune --pick 1 --quality Ultra-HD
anvil media status                       # downloads in progress, what is still searched for,
anvil media status --watch               # the free space, refreshed every 10 seconds
```

`get` details:

- It uses the quality profile `HD-1080p` unless `--quality` names another.
- It uses the first root folder.
- A movie or series that is already added but has no file gets a new search, not a second
  add.
- Under 15 GB of free space it asks first. `--yes` skips the question.

The addresses are the gateway names (`radarr.<gateway-domain>`, `sonarr.<gateway-domain>`),
so it works at home and over the VPN alike. The API keys come from `kv/homelab/<vm>/arr`
through `scripts/media-env.sh`. anvil reads them from a pipe and never prints them. The
script refuses to write the keys to a terminal.

## Shell completion

```sh
source <(anvil completion bash)          # bash
source <(anvil completion zsh)           # zsh
anvil completion fish | source           # fish
```

It completes:

- the commands and their options
- the targets and services of `check`, `apply` and `up`
- the stages after `--from`, `--only` and `--skip`
- the parts of `restore` and `help`

The names come from the catalog, so a new role tag shows up by itself. The script asks
`anvil completion names` at completion time and falls back to the names it was made with.

The Homebrew, .deb and .rpm packages install the scripts for you. To keep one yourself,
save it where your shell looks, for example as `_anvil` in a directory of `$fpath` for
zsh.

## Colors

On a terminal, anvil colors its own status words: `ok`, `warn` and `FAIL`, the stage
results of `anvil up` and the problems of `anvil status`. Piped output stays plain.
`NO_COLOR=1`, `TERM=dumb` or `--no-color` anywhere on the command line turns colors off.
anvil passes the output of make and Ansible on as it is.

## Troubleshooting

### No route to host on macOS

On macOS 15 and later, a program started from a terminal app needs the Local Network
permission to reach addresses on your network. Without it, `terraform`, `vault` and
`anvil` itself get `no route to host`. Ansible still works, because it connects through
`/usr/bin/ssh`, which macOS lets through. So `anvil check` may fail at `tf-init` while
`anvil check apps` works.

anvil checks the state store and Vault the way the stages reach them, from a program like
`terraform`:

- `no route to host`, but `/sbin/ping` reaches the host: anvil says macOS is blocking
  local network access.
- ping does not answer either: the message has both hints.

The fix:

1. Open System Settings, Privacy & Security, Local Network.
2. Turn it on for your terminal app: Terminal, iTerm, Warp, Ghostty or your editor.
3. Quit and reopen the terminal app if the switch was already on, then rerun.

When the message names the network or the VPN instead, the host did not answer at all.
Check that you are on the home or lab network, or connected to the VPN.

Away from home, a lab address added by hand to the Wi-Fi interface breaks the VPN route.
Such an alias is used at home to reach the lab directly. Its route is more specific than
the VPN's and points into the wrong network. `route -n get <lab address>` then names the
Wi-Fi interface, not the VPN's. `anvil doctor` reports it, and `anvil doctor --fix`
removes the alias and its routes. By hand: `sudo ifconfig en0 -alias <alias address>`,
then `sudo route -n delete` for each lab route that `netstat -rn -f inet` still shows on
en0.

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

The tests put a fake `make` on `PATH`. They cover:

- the mapping from names to make commands
- the services read from the playbook
- the confirmations
- finding the repo
- the stages of `anvil up`, with their pauses and resume
- that no output holds a value from the environment

CI runs them and builds the binary for darwin/arm64 and linux/amd64.
