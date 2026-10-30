// Package suite is anvil test: one layer of the test suite (tests/README.md) through make.
package suite

import (
	"flag"
	"fmt"
	"slices"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

func init() {
	app.Register(app.Command{Name: "test", Summary: "run a layer of the test suite (smoke checks the live lab)", Usage: testUsage, Run: cmdTest, Order: 24})
}

const testUsage = `usage: anvil test <layer> [name] [--dry-run]

Runs one layer of the test suite (tests/README.md):

  unit          fast checks with no lab, and the CLI's Go tests when Go is installed
  integration   the same code against real tools (Linux with sudo, Docker)
  smoke         read-only checks of the live lab (needs Vault)
  all           unit, integration and smoke

  name          only the tests whose name has it, for example: anvil test smoke gateway

options:
  --dry-run   print the make command, run nothing
`

var layers = []string{"unit", "integration", "smoke", "all"}

func cmdTest(a *app.App, args []string) int {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	var dry bool
	fs.BoolVar(&dry, "dry-run", false, "")
	pos, code, ok := a.Flags(fs, testUsage, args)
	if !ok {
		return code
	}
	if len(pos) < 1 || len(pos) > 2 || !slices.Contains(layers, pos[0]) {
		fmt.Fprint(a.Stderr, testUsage)
		return 2
	}
	name := ""
	if len(pos) == 2 {
		name = pos[1]
		if !run.ShellSafe(name) {
			fmt.Fprintf(a.Stderr, "anvil: test: a name is letters, digits, - and _ (got %q)\n", name)
			return 2
		}
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	// make sources scripts/env.sh itself for smoke, so the other layers need no lab.
	return r.Shell(run.NewMake("test-"+pos[0], "T", name).String(), nil)
}
