package main

// anvil pools: the ZFS data pools of a provisioned Proxmox host (make pools).

import (
	"flag"
	"fmt"
	"regexp"
)

func init() {
	register(command{"pools", "create the ZFS data pools of a new Proxmox host (make pools)", poolsUsage, cmdPools, 47})
}

const poolsUsage = `usage: anvil pools <machine> [--wipe POOL] [--yes] [--dry-run]

Creates the ZFS data pools declared in site.provision.machines.<machine>.pools on that
host, after anvil provision installed it. The boot pool is the installer's.

  1. a check run: it lists the host's disks by their by-id names, and what it would do
  2. after you confirm: zpool create for each missing pool, and the Proxmox storage

An existing pool is never changed. A disk in a pool or mounted is refused. A disk with old
signatures (a filesystem, RAID or ZFS label) is refused too, unless --wipe names its pool.

  --wipe POOL  wipe old signatures on that pool's disks first. Only when nothing on them
               is needed
  --yes        do not ask
  --dry-run    print the make commands and run nothing

Example: anvil pools pve2
`

var poolNameRE = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,30}$`)

func cmdPools(a *app, args []string) int {
	var wipe string
	var yes, dry bool
	fs := flag.NewFlagSet("pools", flag.ContinueOnError)
	fs.StringVar(&wipe, "wipe", "", "")
	fs.BoolVar(&yes, "yes", false, "")
	fs.BoolVar(&dry, "dry-run", false, "")
	pos, code, ok := a.flags(fs, poolsUsage, interleaveFlags(args, "--wipe", "-wipe"))
	if !ok {
		return code
	}
	if len(pos) != 1 || !poolNameRE.MatchString(pos[0]) {
		fmt.Fprint(a.stderr, poolsUsage)
		return 2
	}
	if wipe != "" && !poolNameRE.MatchString(wipe) {
		fmt.Fprintf(a.stderr, "anvil: pools: --wipe wants a pool name, got %q\n", wipe)
		return 2
	}
	r, ok := a.runner(dry)
	if !ok {
		return 1
	}
	vars := []string{"HOST", pos[0]}
	if wipe != "" {
		vars = append(vars, "WIPE", wipe)
	}
	if code := r.make(newMake("pools", append(vars, "ARGS", "--check")...), nil); code != 0 {
		return code
	}
	q := fmt.Sprintf("Create the missing pools on %s now?", pos[0])
	if wipe != "" {
		q = fmt.Sprintf("Wipe the disks of %s and create the missing pools on %s now?", wipe, pos[0])
	}
	if !dry && !yes && !askYesNo(a.stdin, a.stdout, q) {
		fmt.Fprintln(a.stdout, "Nothing changed.")
		return 1
	}
	return r.make(newMake("pools", vars...), nil)
}
