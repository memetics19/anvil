SHELL := /bin/bash
# lint and secrets-scan need no secrets (CI has no Keychain); only infra targets source env.sh.
ENV := source scripts/env.sh

.PHONY: lint secrets-scan bootstrap-ssh host

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
	cd ansible && ansible-playbook playbooks/bootstrap-ssh.yml --limit '!vault_servers' $(ARGS)

host:
	@set -eu -o pipefail; $(ENV); \
	cd ansible && ansible-playbook playbooks/host.yml --limit '!vault_servers' $(ARGS)
