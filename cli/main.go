// Command anvil is a thin wrapper over the repo's make targets (docs/cli.md). The command
// line is in internal/app.
package main

import (
	"os"

	"github.com/memetics19/anvil/cli/internal/app"
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
