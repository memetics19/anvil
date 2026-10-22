SHELL := /bin/bash
# lint and secrets-scan need no secrets (CI has no Keychain); only infra targets source env.sh.
ENV := source scripts/env.sh
# Ansible targets: the community.hashi_vault lookup needs hvac in the Python that runs Ansible.
HVAC_CHECK := py=$$(ansible-playbook --version | sed -n 's/^  python version = .*(\(.*\))$$/\1/p'); \
	"$${py:-python3}" -c 'import hvac' 2>/dev/null || { \
	  echo "hvac is missing in the Python that runs Ansible; fix: \"$$py\" -m pip install hvac" >&2; exit 1; }

.PHONY: lint secrets-scan bootstrap-ssh host host-network enclave vlans ceph vms vm test-netplan vault vault-unseal vault-policies site-to-vault backup vaultwarden-drill tf-init tf-plan tf-apply docs docs-publish

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

# One-time: install the operator SSH key on the Proxmox host and guests (Keychain passwords).
bootstrap-ssh:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/bootstrap-ssh.yml $(ARGS)

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

# Single-node Ceph + S3 gateway. The first real run wipes the OSD disk: dry-run first.
ceph:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/ceph.yml $(ARGS)

# Common guest roles (playbooks/vms.yml): base, docker, cloudflared, node_exporter.
vms:
	@set -eu -o pipefail; $(ENV); $(HVAC_CHECK); \
	cd ansible && ansible-playbook playbooks/vms.yml $(ARGS)

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
# Vaultwarden backup from the Ceph S3 bucket (keeps the newest 30 of each).
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

tf-plan:
	@set -eu -o pipefail; $(ENV); umask 077; \
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
