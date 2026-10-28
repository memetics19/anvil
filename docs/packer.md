# Packer images (roadmap)

A plan, not built yet. It turns the base of every VM into a versioned, scanned image that
Packer builds from code, so a new VM starts ready instead of being set up after it boots.

## Today

1. Terraform imports a pinned Ubuntu 24.04 cloud image (`noble_cloudimg`, fixed by
   SHA-256) into each new VM's disk.
2. cloud-init sets the user, the SSH key and the network.
3. Ansible then runs the guest roles on the running VM: `guest_base` (time, guest agent,
   fstrim, netplan), Docker, node_exporter and the rest.

What that costs:

- Every new VM downloads and installs the same packages again. A rebuild takes longer
  than it needs to.
- Two VMs built a month apart differ: each got the packages of its own day.
- The base layer is never scanned as one thing. Trivy scans the container images, not
  the VM underneath them.
- A VM in the secrets enclave has no internet, so its first setup depends on the apt cache.

## Goal

- `anvil image build base` builds a Proxmox template from code, on demand or monthly.
- The template holds the generic layers only. No secrets, no site values, no hostname: the
  repository is public, and so is anything that could leak from an image.
- New VMs are cloned from the newest template. Ansible still configures each host, but
  finds the base already in place and changes nothing there.
- Every image is scanned and boot-tested before any VM uses it.

## Not the goal

- Replacing Ansible. Workloads, site values and secrets stay in Ansible and Vault.
- Changing the VMs that exist today. They keep their disks. An image only reaches a VM
  when that VM is rebuilt, one at a time.
- Images for the Proxmox hosts. They come from `anvil provision`.

## Design

| Part | Choice |
|---|---|
| Builder | Packer's Proxmox plugin, `proxmox-clone`: it clones a VM from the pinned cloud image, runs the provisioners, and turns the result into a template |
| Base | The same pinned Ubuntu 24.04 cloud image Terraform uses today, by URL and SHA-256 |
| Provisioner | Ansible, with the existing roles. Each role gets an `image` tag for the tasks that are safe to bake (packages, services, settings) and leaves out the per-host ones (netplan, hostname, keys) |
| Images | `base`: updates, guest agent, fstrim, time sync, hardened sshd, node_exporter. `docker`: `base` plus pinned Docker |
| Names | `anvil-<image>-<date>`, for example `anvil-base-20261101`, on VMIDs 9900 to 9999 |
| Where | Built on `pve2`. Templates live on node-local ZFS, so a clone works only on the node that holds the template. Each image is built once per node that clones from it |
| Credentials | The Proxmox API token comes from Vault at build time, as for Terraform. The build's SSH key exists only for the build |
| Cleanup before sealing | `cloud-init clean`, an empty `/etc/machine-id`, no SSH host keys, no shell history, no build key, apt lists removed |

## Checks before an image is used

1. **No leftovers.** A script mounts the template's disk read-only and fails on any SSH host
   key, `authorized_keys`, a non-empty `machine-id`, shell history, or a file matching the
   gitleaks rules.
2. **Trivy.** The image's root filesystem is scanned. A fixable HIGH or CRITICAL finding
   blocks it, the same rule as the repository and the release binary.
3. **Boot test.** A throwaway VM is cloned with a test cloud-init. It must boot, answer SSH,
   report through the guest agent, and, for `docker`, run a container. Then it is deleted.
4. **No drift.** `anvil check` against the throwaway VM must show no changes for the baked
   roles. That proves the image matches the roles it came from.

## Phases

Each phase is a pull request or a short series, with its own checks, and leaves the lab
working.

### Phase 0: spike (1 to 2 days)

- Run the Proxmox plugin against Proxmox VE 8.4 on `pve2` by hand. Confirm `proxmox-clone`
  from the cloud image, cloud-init on the clone, and conversion to a template.
- Decide the VMID range, the storage (`local-zfs` or `vmdata`) and the build node.
- Write down what the plugin cannot do and how anvil works around it.

Done when: a template built by hand boots a clone with cloud-init.

### Phase 1: the base image as code

- `packer/` with `base.pkr.hcl`, the pinned source, and the Ansible provisioner.
- `image` tags in `guest_base` and node_exporter. Each task that touches a per-host value
  stays out of the tag.
- `make image IMAGE=base` and the leftover check.
- Docs: a page like this one, rewritten as how it works.

Done when: `make image IMAGE=base` builds `anvil-base-<date>` on `pve2` and passes the
leftover check.

### Phase 2: tests and the docker image

- The boot test and the no-drift test, as a script anvil runs after each build.
- Trivy on the image, with the blocking rule.
- `docker.pkr.hcl`, built from `base` with the Docker role's `image` tasks.
- CI checks the Packer files (`packer fmt -check`, `packer validate`) on every pull
  request. The build itself runs in the lab, never on GitHub, which holds no lab keys.

Done when: both images build, scan clean of fixable HIGH and CRITICAL findings, and pass
the boot and no-drift tests.

### Phase 3: Terraform clones new VMs

- A variable per VM picks the image. A new VM is cloned from that template instead of
  importing the cloud image.
- Existing VMs keep `ignore_changes` on their disk, so no plan ever replaces them.
- The plan guard refuses a plan that replaces a VM because its image changed.
- One new test VM is built from the image end to end: Terraform, then `anvil up`.

Done when: a new VM comes up from the template, and `anvil up` changes nothing in its
baked layers.

### Phase 4: the CLI and the schedule

- `anvil image build <image>`, `anvil image list`, `anvil image prune`.
- `prune` keeps the newest three of each image and never deletes a template a VM was
  cloned from.
- A monthly rebuild from the operator machine, like `anvil drift`, with the result sent to
  ntfy.

Done when: images rebuild every month without a hand step, and old ones are pruned safely.

### Phase 5: rebuilds and the enclave

- `anvil rebuild <vm>` for the stateless VMs: snapshot, new VM from the newest image,
  `anvil up` for that VM, then a check that its services answer. The old VM stays until
  the new one passes.
- An enclave image built without internet, through the apt cache.
- The rebuild runbook (already planned) moves to images.

Done when: a stateless VM is rebuilt from an image with one command and no data loss.

## Risks

| Risk | How it is handled |
|---|---|
| A template on node-local storage clones only on its own node | Build per node, or keep templates on shared storage once there is any |
| Something secret or site-specific is baked in | No secrets reach the build. The leftover check and gitleaks run on the image before use |
| The image and the roles drift apart | The no-drift test on every build |
| The plugin lags behind a Proxmox release | Pinned plugin version, and the boot test catches a broken build before use |
| A bad image reaches a VM | Images are never used by existing VMs automatically. A VM moves to a new image only by a rebuild, one at a time, with the old VM kept until the new one passes |

## Open questions

- Build on `pve2` only, or on both nodes?
- Monthly, or right after each Ubuntu security release?
- Should `ragnarok` and `frigate` ever be rebuilt from an image, or stay as they are? They
  hold the most state.
