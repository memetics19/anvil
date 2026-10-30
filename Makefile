SHELL := /bin/bash
# lint and secrets-scan need no secrets (CI has no Keychain); only infra targets source env.sh.
ENV := source scripts/env.sh
# Ansible targets: the community.hashi_vault lookup needs hvac in the Python that runs Ansible.
HVAC_CHECK := py=$$(ansible-playbook --version | sed -n 's/^  python version = .*(\(.*\))$$/\1/p'); \
	"$${py:-python3}" -c 'import hvac' 2>/dev/null || { \
	  echo "hvac is missing in the Python that runs Ansible; fix: \"$$py\" -m pip install hvac" >&2; exit 1; }

.PHONY: lint secrets-scan test test-unit test-integration test-smoke test-all bootstrap-ssh forget-host grow-disk rotate pools cluster host host-network enclave vlans switch ceph vms vm test-netplan vault vault-unseal vault-policies site-to-vault backup vaultwarden-drill tf-init tf-plan tf-apply provision-iso provision provision-clean docs docs-publish cli release-snapshot

lint:
	@set -eu -o pipefail; \
	if [ -d terraform ]; then \
	  terraform fmt -check -recursive terraform; \
	  (cd terraform && tflint --recursive); \
	else echo "skip terraform lint: no terraform/"; fi; \
	yamllint -c .yamllint .; \
	if [ -d ansible ]; then (cd ansible && ansible-lint -c ../.ansible-lint .); \
	else echo "skip ansible-lint: no ansible/"; fi


secrets-scan:
	@set -eu -o pipefail; \
	gitleaks git --no-banner --config .gitleaks.toml . ; \
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf - 2>/dev/null | tar -xf - -C "$$tmp"; \
	gitleaks dir --no-banner --config .gitleaks.toml "$$tmp"

# The test suite by layer (tests/README.md). T=<name> runs only the tests whose name has it.
# make test runs everything that needs no lab: lint, the secrets scan, unit and integration.
test: lint secrets-scan test-unit test-integration

test-unit:
	@set -eu -o pipefail; \
	if command -v go >/dev/null; then (cd cli && go vet ./... && go test ./...); \
	else echo "skip the Go tests: go is not installed"; fi; \
	tests/run.sh unit $(T)

test-integration:
	@tests/run.sh integration $(T)

# Read-only checks against the live lab, from this machine (tests/smoke). Needs Vault.
test-smoke:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); tests/run.sh smoke $(T)

# The complete suite: everything make test runs, then the smoke tests.
test-all: test test-smoke

# One-time: install the operator SSH key on the Proxmox host and guests (Keychain passwords).
bootstrap-ssh:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/bootstrap-ssh.yml $(ARGS)

# After a deliberate rebuild of a host: drop its old SSH host key, so the next run records
# the new one. Ansible refuses a changed key otherwise. One inventory host only. The switch's
# key is in build/switch/known_hosts (scripts/forget-host.sh). make forget-host HOST=frigate
forget-host:
	@set -eu -o pipefail; [ -n "$(HOST)" ] || { echo "usage: make forget-host HOST=<name>" >&2; exit 1; }; \
	$(ENV); $(HVAC_CHECK); \
	scripts/forget-host.sh "$(HOST)"

host:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/host.yml $(ARGS)

# Host network change with timed rollback. Never combine with a netbird VM change.
host-network:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/host-network.yml $(ARGS)

# The secrets enclave on the Proxmox host: firewall, SDN apply (both with timed rollback),
# apt cache, NTP, cloud-init vendor data. Dry-run first: make enclave ARGS="--check".
enclave:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/enclave.yml $(ARGS)

# VLANs 10/20/30 on the Proxmox host: first the routed segments firewall (one table for the
# enclave and the VLANs, playbooks/enclave.yml --tags firewall), then the gateway addresses
# on the vnets (timed rollback), DHCP and NTP per VLAN (playbooks/vlans.yml).
# Dry-run first: make vlans ARGS="--check --diff".
vlans:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/enclave.yml --tags firewall $(ARGS) && \
	ansible-playbook playbooks/vlans.yml $(ARGS)

# The Cisco switch (playbooks/switch.yml, role network_switch), from the controller over SSH.
# A dry run: it prints the planned commands. Apply: make switch ARGS="-e network_switch_apply=true".
switch:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/switch.yml $(ARGS)

# Single-node Ceph + S3 gateway. The first real run wipes the OSD disk: dry-run first.
ceph:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/ceph.yml $(ARGS)

# Common guest roles (playbooks/vms.yml): base, docker, cloudflared, node_exporter.
vms:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/vms.yml $(ARGS)

# A VM's disk ADD GB bigger while it runs: plan (only that disk may change, and only grow),
# site dict, apply, then the partition and filesystem inside it. CHECK=1 plans only.
# make grow-disk HOST=ragnarok ADD=600 [MOUNT=/home] [CHECK=1]
grow-disk:
	@set -eu -o pipefail; [ -n "$(HOST)" ] && [ -n "$(ADD)" ] || \
	  { echo "usage: make grow-disk HOST=<vm> ADD=<GB> [MOUNT=<path>] [CHECK=1]" >&2; exit 1; }; \
	$(ENV); $(HVAC_CHECK); \
	scripts/grow-disk.sh $(if $(CHECK),--check) "$(HOST)" "$(ADD)" "$(MOUNT)"

# New secrets (anvil rotate): the app makes a new key, the apps that use it follow, then
# Vault and the dashboard. CHECK=1 is Ansible's check mode.
# make rotate SECRET=radarr[,sonarr] [CHECK=1]
rotate:
	@set -eu -o pipefail; [ -n "$(SECRET)" ] || \
	  { echo "usage: make rotate SECRET=<name>[,<name>] [CHECK=1]" >&2; exit 1; }; \
	$(ENV); $(HVAC_CHECK); \
	scripts/rotate.sh $(if $(CHECK),--check) "$(SECRET)"

# The Proxmox cluster: the main host creates it, site.cluster.members join (role pve_cluster).
# make cluster ARGS="--check --diff" first.
cluster:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/cluster.yml $(ARGS)

# ZFS data pools on a provisioned Proxmox host (site.provision.machines.<host>.pools).
# make pools HOST=pve2 [ARGS="--check"] [WIPE=<pool>]
pools:
	@set -eu -o pipefail; [ -n "$(HOST)" ] || { echo "usage: make pools HOST=<machine> [WIPE=<pool>]" >&2; exit 1; }; \
	$(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/pools.yml -e pools_host="$(HOST)" $(if $(WIPE),-e zfs_pools_wipe="$(WIPE)") $(ARGS)

# One VM at a time: make vm HOST=frigate
vm:
	@set -eu -o pipefail; [ -n "$(HOST)" ] || { echo "usage: make vm HOST=<name>" >&2; exit 1; }; \
	$(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/vms.yml --limit "$(HOST)" $(ARGS)

# Proves guest_base's netplan checks reject broken input (temp root only, /etc/netplan untouched).
test-netplan:
	@set -eu -o pipefail; [ -n "$(HOST)" ] || { echo "usage: make test-netplan HOST=<name>" >&2; exit 1; }; \
	$(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook tests/netplan-validate.yml --limit "$(HOST)" $(ARGS)

# Vault server role. Leaves Vault sealed; a config change restarts (and so seals) it.
# First time only, the operator runs scripts/vault-init.sh (it writes the Keychain).
vault:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/vault.yml $(ARGS)

# Unseal with 3 of the 5 keys from Keychain item vault-init-json (keys never printed).
vault-unseal:
	@set -eu -o pipefail; $(ENV); \
	scripts/vault-unseal.sh

# Vault policies from vault/policies/<name>.hcl; each is written only when it differs.
vault-policies:
	@set -eu -o pipefail; $(ENV); \
	for f in vault/policies/*.hcl; do \
	  n=$$(basename "$$f" .hcl); \
	  if [ "$$(vault policy read "$$n" 2>/dev/null || true)" = "$$(cat "$$f")" ]; then echo "$$n: unchanged"; \
	  else vault policy write "$$n" "$$f" >/dev/null; echo "$$n: written"; fi; \
	done

# Keychain site-bootstrap -> Vault kv/homelab/site (refuses to replace a different value
# unless ARGS=--force).
site-to-vault:
	@set -eu -o pipefail; $(ENV); \
	scripts/site-to-vault.sh $(ARGS)

# Terraform state + Vault Raft snapshot into ~/homelab-backups, plus a copy of the newest
# Vaultwarden and Authentik backups from their Ceph S3 buckets (keeps the newest 30 of each).
backup:
	@set -eu -o pipefail; $(ENV); \
	scripts/backup.sh

# Restore the newest Vaultwarden backup (as make backup copied it) into a temporary container
# on the apps VM, check it (/alive, users equal to the live database), then remove it.
vaultwarden-drill:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/vaultwarden-restore-drill.yml $(ARGS)

# Terraform. The S3 backend endpoint is not committed: it is built from PVE_IP (Keychain).
tf-init:
	@set -eu -o pipefail; $(ENV); \
	terraform -chdir=terraform init -input=false -backend-config="endpoints={s3=\"http://$${PVE_IP}:7480\"}" $(ARGS)

# Plans are checked by scripts/plan-guard.sh: no destroy/replace, no change to ragnarok's
# disks, and no -target (a targeted plan hides the rest; don't pass -target in ARGS).
# The saved plan holds site values, so it is transient: mode 600, removed at the start of
# tf-plan, when the guard rejects it, and after tf-apply. Its JSON is never written to disk.
TF_PLAN := terraform/homelab.tfplan

# A fresh checkout (or a new worktree) has no .terraform yet: initialise it first, the same
# way tf-init does, so a plan never fails on "Backend initialization required".
tf-plan:
	@set -eu -o pipefail; $(ENV); umask 077; \
	if [ ! -f terraform/.terraform/terraform.tfstate ]; then \
	  echo "terraform: not initialised here, running tf-init first"; \
	  terraform -chdir=terraform init -input=false -backend-config="endpoints={s3=\"http://$${PVE_IP}:7480\"}" >/dev/null; \
	fi; \
	rm -f $(TF_PLAN); trap 'rm -f $(TF_PLAN)' ERR; \
	echo "site source: $${HOMELAB_SITE_USED:-none}"; \
	terraform -chdir=terraform plan -input=false -out=homelab.tfplan $(ARGS); \
	scripts/plan-guard.sh <(terraform -chdir=terraform show -json homelab.tfplan)

# Applies only the saved plan, and only if it passes the guard (checked again here).
tf-apply:
	@set -eu -o pipefail; $(ENV); umask 077; \
	[ -f $(TF_PLAN) ] || { echo "tf-apply: no saved plan; run make tf-plan first" >&2; exit 1; }; \
	trap 'rm -f $(TF_PLAN)' EXIT; \
	scripts/plan-guard.sh <(terraform -chdir=terraform show -json homelab.tfplan); \
	applyable=$$(terraform -chdir=terraform show -json homelab.tfplan | jq -r '.applyable'); \
	[ "$$applyable" = true ] || { echo "tf-apply: the saved plan has nothing to apply"; exit 0; }; \
	terraform -chdir=terraform apply -input=false homelab.tfplan

# Bare-metal provisioning (docs/provisioning.md). The ISO holds the root password hash:
# build/provision/<name>.iso, mode 600, deleted by make provision after the install.
provision-iso:
	@set -eu -o pipefail; [ -n "$(NAME)" ] || { echo "usage: make provision-iso NAME=<name>" >&2; exit 1; }; \
	$(ENV); scripts/provision-iso.sh "$(NAME)"

# A dry run: the guard, read-only BMC reads and the planned Redfish or IPMI calls.
# Install: make provision NAME=<name> ARGS="-e provision_confirm=<name>".
provision:
	@set -eu -o pipefail; [ -n "$(NAME)" ] || { echo "usage: make provision NAME=<name>" >&2; exit 1; }; \
	$(ENV); python3 scripts/provision.py run --name "$(NAME)" $(ARGS)

# Deletes the ISO on the Mac and the netboot payload (media pxe) on the Proxmox host.
provision-clean:
	@set -eu -o pipefail; [ -n "$(NAME)" ] || { echo "usage: make provision-clean NAME=<name>" >&2; exit 1; }; \
	case "$(NAME)" in *[!a-z0-9-]*) echo "provision-clean: bad name" >&2; exit 1 ;; esac; \
	rm -f "build/provision/$(NAME).iso"; echo "removed build/provision/$(NAME).iso"; \
	$(ENV); ssh -o BatchMode=yes "$${PROVISION_NETBOOT_HOST:-root@$$PVE_IP}" \
	  'rm -f /var/tmp/anvil-provision/pxe-$(NAME)/linux26 /var/tmp/anvil-provision/pxe-$(NAME)/initrd; rmdir /var/tmp/anvil-provision/pxe-$(NAME) 2>/dev/null; true'; \
	echo "removed the netboot payload pxe-$(NAME) on the Proxmox host, if any"

# Build the docs site into build/site (pip install -r docs/requirements.txt first).
docs:
	@scripts/docs-build.sh

# Build the same site in a throwaway venv (build/docs-venv, pinned docs/requirements.txt) and
# publish it on the apps VM as https://docs.<gateway domain> (Caddy serves the files). Only
# changed content is copied. The build date is the last commit's, so a rebuild is identical.
DOCS_VENV := build/docs-venv
docs-publish:
	@set -eu -o pipefail; \
	rm -rf $(DOCS_VENV); trap 'rm -rf $(DOCS_VENV)' EXIT; \
	python3 -m venv $(DOCS_VENV); \
	$(DOCS_VENV)/bin/pip install --quiet --disable-pip-version-check -r docs/requirements.txt; \
	SOURCE_DATE_EPOCH=$$(git log -1 --format=%ct) PATH="$$PWD/$(DOCS_VENV)/bin:$$PATH" scripts/docs-build.sh; \
	$(MAKE) --no-print-directory vm HOST=apps ARGS="--tags docs $(ARGS)"

# The anvil CLI (cli/cmd/anvil, docs/cli.md) as one static binary, build/anvil. The same commit
# builds the same bytes: no cgo, no paths, no build ID. The version, commit and date come
# from git (the date is the commit's, not the clock's), as in .goreleaser.yaml.
# Another platform: GOOS=linux GOARCH=amd64 make cli ANVIL_OUT=build/anvil-linux-amd64
ANVIL_OUT ?= build/anvil
ANVIL_VERSION = $(patsubst v%,%,$(shell git describe --tags --always --dirty 2>/dev/null || echo dev))
ANVIL_COMMIT = $(shell git rev-parse HEAD 2>/dev/null)
ANVIL_DATE = $(shell TZ=UTC git log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd 2>/dev/null)
cli:
	@set -eu -o pipefail; mkdir -p "$(dir $(ANVIL_OUT))"; out="$$PWD/$(ANVIL_OUT)"; \
	cd cli && CGO_ENABLED=0 go build -trimpath -buildvcs=false \
	  -ldflags "-s -w -buildid= -X main.version=$(ANVIL_VERSION) -X main.commit=$(ANVIL_COMMIT) -X main.date=$(ANVIL_DATE)" -o "$$out" ./cmd/anvil; \
	echo "built $(ANVIL_OUT) ($(ANVIL_VERSION))"

# The release build without publishing (.goreleaser.yaml): archives, checksums, .deb and
# .rpm in dist/. GoReleaser runs through go run at the pinned version, so nothing is
# installed. Keep GORELEASER_VERSION in step with .github/workflows/release.yml.
GORELEASER_VERSION := v2.18.2
release-snapshot:
	@set -eu -o pipefail; \
	go run github.com/goreleaser/goreleaser/v2@$(GORELEASER_VERSION) release --snapshot --clean --skip=publish
