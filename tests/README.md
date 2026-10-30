# Tests

The tests are split into four layers. Each layer is a folder, and `tests/run.sh` finds every
`test_*.sh` in it. A new test runs in CI as soon as it is in the right folder.

| Layer | What it checks | Needs | Runs |
|---|---|---|---|
| `unit/` | Templates and roles rendered with a fixture site, scripts against local stubs, guard rules. A few seconds each. | Python, Ansible. macOS or Linux. | Every pull request |
| `integration/` | The same code against real tools: loop devices, ZFS, LVM, nftables, apt, age and SQLite. | Linux with passwordless sudo. | Every pull request |
| `smoke/` | Read-only checks against the live lab after a change. | The lab and Vault. | After an apply, and nightly |
| `e2e/` | A throwaway VM goes from blank to running, gets the smoke checks, and is deleted. | The lab and Vault. | Before a release |

The CLI's Go tests are unit tests too. They live next to the code in `cli/`.

Smoke and end to end tests run from inside the lab or the operator's machine, never from
GitHub. GitHub holds no keys to the lab.

## Running them

```sh
make test                        # lint, secrets scan, Go tests, unit and integration
make test-unit                   # Go tests and the unit layer
make test-integration            # the integration layer (Linux, sudo)
make test-unit T=gateway         # only the tests whose name has "gateway"
tests/run.sh unit                # the same without make
```

The runner prints one line per test and the full output of any test that fails.

A test that cannot run on this machine, for example an integration test on macOS, prints
`SKIP` and passes. In CI the same test fails instead, so nothing is skipped there by accident.

## Writing a test

- Put it in the folder of its layer and name it `test_<what>.sh`.
- Start from the repository root: `cd "$(dirname "$0")/../.." || exit 1`.
- Print `ok` or `FAIL` per check and exit 1 if any check failed.
- Use documentation addresses only (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and
  `example.com`. No real address, name or secret goes in a test or a fixture.
- Shared stubs and fixtures live in `tests/fixtures/`.
