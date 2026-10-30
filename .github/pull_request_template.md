## What this changes

<!-- One or two sentences. What does the lab do differently after this is merged? -->

## Why

<!-- The problem it solves. Link the issue if there is one: Fixes #123 -->

## How it was checked

<!-- Tick what you ran. Say what you saw on a real lab if you applied it there. -->

- [ ] `make lint`
- [ ] `make secrets-scan`
- [ ] `for t in tests/test_*.sh; do bash "$t" || echo "FAILED $t"; done`
- [ ] `cd cli && go vet ./... && go test ./...` (when the CLI changed)
- [ ] `anvil check <target>` shows only the expected changes
- [ ] Applied on a lab and checked the result

## Before you ask for a review

- [ ] The title follows [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `docs:` ...)
- [ ] No addresses, MACs, domain names, host names or secrets from a real lab. Site values come from Vault.
- [ ] Docs updated when a command, an option or a service changed
- [ ] A test covers the change, or the description says why it can not
