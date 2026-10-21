SHELL := /bin/bash
# lint and secrets-scan need no secrets (CI has no Keychain); only infra targets source env.sh.
ENV := source scripts/env.sh

.PHONY: lint secrets-scan bootstrap-ssh host host-network ceph tf-init tf-plan tf-apply

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
	@set -eu -o pipefail; $(ENV); \
	cd ansible && ansible-playbook playbooks/bootstrap-ssh.yml $(ARGS)

host:
	@set -eu -o pipefail; $(ENV); \
	cd ansible && ansible-playbook playbooks/host.yml $(ARGS)

# Host network change with timed rollback. Never combine with a netbird VM change.
host-network:
	@set -eu -o pipefail; $(ENV); \
	cd ansible && ansible-playbook playbooks/host-network.yml $(ARGS)

# Single-node Ceph + S3 gateway. The first real run wipes the OSD disk: dry-run first.
ceph:
	@set -eu -o pipefail; $(ENV); \
	cd ansible && ansible-playbook playbooks/ceph.yml $(ARGS)

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
