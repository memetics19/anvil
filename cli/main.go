// Command anvil is a thin wrapper over the repo's make targets (docs/cli.md). The command
// line is in internal/app.
package main

import (
	"os"

	"github.com/memetics19/anvil/cli/internal/app"

	// The commands, each registered in its package's init.
	_ "github.com/memetics19/anvil/cli/internal/completion"
	_ "github.com/memetics19/anvil/cli/internal/disk"
	_ "github.com/memetics19/anvil/cli/internal/doctor"
	_ "github.com/memetics19/anvil/cli/internal/drift"
	_ "github.com/memetics19/anvil/cli/internal/lab"
	_ "github.com/memetics19/anvil/cli/internal/media"
	_ "github.com/memetics19/anvil/cli/internal/pools"
	_ "github.com/memetics19/anvil/cli/internal/provision"
	_ "github.com/memetics19/anvil/cli/internal/rotate"
)

// version, commit and date are set at build time with -ldflags -X (make cli, GoReleaser).
// version has no leading v. A release is a plain X.Y.Z.
var (
	version = "dev"
	commit  = ""
	date    = ""
)

func main() {
	app.Version, app.Commit, app.Date = version, commit, date
	os.Exit(app.Main(os.Args[1:]))
}
