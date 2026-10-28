// Package provision installs Proxmox VE on new hardware: anvil provision-iso and anvil
// provision. It is never part of anvil up.
package provision

import (
	"flag"
	"fmt"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

func init() {
	app.Register(app.Command{Name: "provision-iso", Summary: "make provision-iso NAME=<name>", Usage: provisionISOUsage, Run: cmdProvisionISO, Order: 40})
	app.Register(app.Command{Name: "provision", Summary: "make provision NAME=<name> (a dry run unless --install)", Usage: provisionUsage, Run: cmdProvision, Order: 41})
}

const provisionISOUsage = `usage: anvil provision-iso <name> [--dry-run]

Runs make provision-iso NAME=<name>: the Proxmox VE automated install ISO for
site.provision.machines.<name>, in build/provision/<name>.iso (docs/provisioning.md).
`

const provisionUsage = `usage: anvil provision <name> [--install] [--power-off] [--media-ready] [--dry-run]

Without --install: make provision NAME=<name>, a dry run (the guard, read-only BMC reads,
the planned Redfish or IPMI calls).

With --install: the dry run first, then the name typed, then
make provision NAME=<name> ARGS="-e provision_confirm=<name>". The guard in
scripts/provision.py still refuses the current server. --media-ready adds
-e provision_media_ready=true, for manual media (docs/provisioning.md).

--power-off adds -e provision_power_off=true: a running target is shut down gracefully
(never forced) before the install, after the serial check proved it is the target. A
machine with a controller step (controller: {vendor: dell, mode: nonraid}) needs it,
because that step reboots the server.
`

func cmdProvisionISO(a *app.App, args []string) int {
	fs := flag.NewFlagSet("provision-iso", flag.ContinueOnError)
	var dry bool
	fs.BoolVar(&dry, "dry-run", false, "")
	pos, code, ok := a.Flags(fs, provisionISOUsage, args)
	if !ok {
		return code
	}
	if len(pos) != 1 {
		fmt.Fprint(a.Stderr, provisionISOUsage)
		return 2
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	return r.Make(run.NewMake("provision-iso", "NAME", pos[0]), nil)
}

func cmdProvision(a *app.App, args []string) int {
	fs := flag.NewFlagSet("provision", flag.ContinueOnError)
	var install, mediaReady, powerOff, dry bool
	fs.BoolVar(&install, "install", false, "")
	fs.BoolVar(&powerOff, "power-off", false, "")
	fs.BoolVar(&mediaReady, "media-ready", false, "")
	fs.BoolVar(&dry, "dry-run", false, "")
	pos, code, ok := a.Flags(fs, provisionUsage, args)
	if !ok {
		return code
	}
	if len(pos) != 1 || (mediaReady && !install) {
		fmt.Fprint(a.Stderr, provisionUsage)
		return 2
	}
	name := pos[0]
	if !run.ShellSafe(name) || strings.ContainsAny(name, "=:,@%+") {
		fmt.Fprintf(a.Stderr, "anvil: %q is not a machine name\n", name)
		return 2
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	check := run.NewMake("provision", "NAME", name)
	if powerOff {
		check = run.NewMake("provision", "NAME", name, "ARGS", "-e provision_power_off=true")
	}
	if code := r.Make(check, nil); code != 0 || !install {
		return code
	}
	if !dry && !app.AskTyped(a.Stdin, a.Stdout, "This installs Proxmox VE on "+name+" and wipes its disks.", name) {
		fmt.Fprintln(a.Stdout, "anvil: not installed")
		return 1
	}
	extra := "-e provision_confirm=" + name
	if mediaReady {
		extra += " -e provision_media_ready=true"
	}
	if powerOff {
		extra += " -e provision_power_off=true"
	}
	return r.Make(run.NewMake("provision", "NAME", name, "ARGS", extra), nil)
}
