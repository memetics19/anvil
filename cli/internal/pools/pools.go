// Package pools is anvil pools: the ZFS data pools of a provisioned Proxmox host
// (make pools).
package pools

import (
	"flag"
	"fmt"
	"regexp"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

func init() {
	app.Register(app.Command{Name: "pools", Summary: "create the ZFS data pools of a new Proxmox host (make pools)", Usage: poolsUsage, Run: cmdPools, Order: 47})
}

const poolsUsage = `usage: anvil pools <machine> [--wipe POOL[,POOL...]] [--yes] [--dry-run]

Creates the ZFS data pools declared in site.provision.machines.<machine>.pools on that
host, after anvil provision installed it. The boot pool is the installer's.

  1. a check run: it lists the host's disks by their by-id names, and what it would do
  2. after you confirm: zpool create for each missing pool, and the Proxmox storage

An existing pool is never changed. A disk in a pool or mounted is refused. A disk with old
signatures (a filesystem, RAID or ZFS label, an empty partition table) is refused too,
unless --wipe names its pool.

  --wipe POOLS wipe old signatures on those pools' disks first, comma separated
               (--wipe vmdata,tank). Only when nothing on them is needed
  --yes        do not ask
  --dry-run    print the make commands and run nothing

Example: anvil pools pve2
`

var poolNameRE = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,30}$`)

func cmdPools(a *app.App, args []string) int {
	var wipe string
	var yes, dry bool
	fs := flag.NewFlagSet("pools", flag.ContinueOnError)
	fs.StringVar(&wipe, "wipe", "", "")
	fs.BoolVar(&yes, "yes", false, "")
	fs.BoolVar(&dry, "dry-run", false, "")
	pos, code, ok := a.Flags(fs, poolsUsage, app.InterleaveFlags(args, "--wipe", "-wipe"))
	if !ok {
		return code
	}
	if len(pos) != 1 || !poolNameRE.MatchString(pos[0]) {
		fmt.Fprint(a.Stderr, poolsUsage)
		return 2
	}
	for _, w := range strings.Split(wipe, ",") {
		if wipe != "" && !poolNameRE.MatchString(w) {
			fmt.Fprintf(a.Stderr, "anvil: pools: --wipe wants pool names, comma separated, got %q\n", wipe)
			return 2
		}
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	vars := []string{"HOST", pos[0]}
	if wipe != "" {
		vars = append(vars, "WIPE", wipe)
	}
	if code := r.Make(run.NewMake("pools", append(vars, "ARGS", "--check")...), nil); code != 0 {
		return code
	}
	q := fmt.Sprintf("Create the missing pools on %s now?", pos[0])
	if wipe != "" {
		q = fmt.Sprintf("Wipe the disks of %s and create the missing pools on %s now?", strings.ReplaceAll(wipe, ",", ", "), pos[0])
	}
	if !dry && !yes && !app.AskYesNo(a.Stdin, a.Stdout, q) {
		fmt.Fprintln(a.Stdout, "Nothing changed.")
		return 1
	}
	return r.Make(run.NewMake("pools", vars...), nil)
}
