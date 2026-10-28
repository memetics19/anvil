package main

// anvil increase-disk: make a VM's disk bigger while it runs (make grow-disk).

import (
	"flag"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

func init() {
	app.Register(app.Command{Name: "increase-disk", Summary: "make a VM's disk bigger while it runs (make grow-disk)", Usage: increaseDiskUsage, Run: cmdIncreaseDisk, Order: 45})
}

const increaseDiskUsage = `usage: anvil increase-disk <vm> <size> [--mount PATH] [--yes] [--dry-run]

Adds <size> to the VM's disk while it runs: nothing stops, nothing is unmounted.

  1. a dry run (make grow-disk CHECK=1): the Terraform plan may change nothing but that
     disk's size, and only make it bigger
  2. after you confirm: the new size into the site dict in Vault, the plan applied
     (Proxmox grows the disk), then the partition and filesystem at the end of the disk
     grow inside the VM

<size> is how much to add: 600gb, 600G, 1.5tb, or a plain number of GB.
  --mount PATH  an LVM disk with several volumes: the mount point to grow (frigate: /home)
  --yes         do not ask before growing
  --dry-run     print the make commands and run nothing

Example: anvil increase-disk ragnarok 600gb
`

var sizeRE = regexp.MustCompile(`^(\d+(?:\.\d+)?)\s*(g|gb|gib|t|tb|tib)?$`)

// parseGB reads a size to add and returns whole GB (1 TB is 1024 GB, as Proxmox counts).
func parseGB(s string) (int, error) {
	m := sizeRE.FindStringSubmatch(strings.ToLower(strings.TrimSpace(s)))
	if m == nil {
		return 0, fmt.Errorf("not a size: %q (for example 600gb or 1.5tb)", s)
	}
	n, _ := strconv.ParseFloat(m[1], 64)
	if strings.HasPrefix(m[2], "t") {
		n *= 1024
	}
	if n != math.Trunc(n) {
		return 0, fmt.Errorf("%q is not a whole number of GB", s)
	}
	if n < 1 || n > 64*1024 {
		return 0, fmt.Errorf("%q: add between 1 GB and 64 TB", s)
	}
	return int(n), nil
}

func cmdIncreaseDisk(a *app.App, args []string) int {
	var mount string
	var yes, dry bool
	fs := flag.NewFlagSet("increase-disk", flag.ContinueOnError)
	fs.StringVar(&mount, "mount", "", "")
	fs.BoolVar(&yes, "yes", false, "")
	fs.BoolVar(&dry, "dry-run", false, "")
	pos, code, ok := a.Flags(fs, increaseDiskUsage, app.InterleaveFlags(args, "--mount", "-mount"))
	if !ok {
		return code
	}
	switch {
	case len(pos) == 1 && sizeRE.MatchString(strings.ToLower(pos[0])):
		fmt.Fprintf(a.Stderr, "anvil: increase-disk: which VM? Name it before the size: anvil increase-disk <vm> %s (for example ragnarok)\n", pos[0])
		return 2
	case len(pos) != 2:
		fmt.Fprint(a.Stderr, increaseDiskUsage)
		return 2
	}
	vm := pos[0]
	gb, err := parseGB(pos[1])
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: increase-disk: %v\n", err)
		return 2
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	vars := []string{"HOST", vm, "ADD", strconv.Itoa(gb)}
	if mount != "" {
		vars = append(vars, "MOUNT", mount)
	}
	if code := r.Make(run.NewMake("grow-disk", append(vars, "CHECK", "1")...), nil); code != 0 {
		return code
	}
	if !dry && !yes && !app.AskYesNo(a.Stdin, a.Stdout, fmt.Sprintf("Add %d GB to %s's disk now?", gb, vm)) {
		fmt.Fprintln(a.Stdout, "Nothing changed.")
		return 1
	}
	return r.Make(run.NewMake("grow-disk", vars...), nil)
}
