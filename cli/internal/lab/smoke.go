package lab

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/run"
)

// SmokeCmd runs the smoke tests: read-only checks of the live lab (tests/smoke). It reads
// the site from Vault itself.
var SmokeCmd = run.NewMake("test-smoke")

// smokeAfter runs the smoke tests after a run that changed the lab. It returns 1 when one
// failed: the change went in, but the lab is not healthy.
func smokeAfter(a *app.App, r *run.Runner) int {
	if r.DryRun {
		fmt.Fprintln(a.Stdout, "# after a run that changed the lab: the smoke tests")
		r.Make(SmokeCmd, nil)
		return 0
	}
	fmt.Fprintln(a.Stdout, "\nanvil: smoke tests, read-only checks of the live lab:")
	if code := r.Make(SmokeCmd, nil); code != 0 {
		fmt.Fprintln(a.Stderr, "anvil: the change went in, but a smoke test failed (above). Again: anvil test smoke")
		return 1
	}
	return 0
}

// SmokeFailures runs the smoke tests with their output captured, and returns the names of
// those that failed and make's exit code. A failure with no name means they did not run.
func SmokeFailures(r *run.Runner) ([]string, int) {
	var out bytes.Buffer
	code := r.Make(SmokeCmd, &out)
	var failed []string
	for _, l := range strings.Split(out.String(), "\n") {
		if n, ok := strings.CutPrefix(strings.TrimSpace(l), "failed: smoke/"); ok {
			failed = append(failed, n)
		}
	}
	return failed, code
}
