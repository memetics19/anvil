package main

// anvil rotate: new secrets, as code (make rotate).

import (
	"flag"
	"fmt"
	"slices"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

func init() {
	app.Register(app.Command{Name: "rotate", Summary: "give an app a new API key, and update what uses it (make rotate)", Usage: rotateUsage, Run: cmdRotate, Order: 46})
}

const rotateUsage = `usage: anvil rotate <secret>... [--yes] [--dry-run]

Makes a new secret and updates everything that uses it. Nothing is restarted.

  radarr, sonarr, prowlarr   the app makes itself a new API key (as its reset button
                             does), Prowlarr's links to Radarr and Sonarr follow, the
                             keys go into Vault, then the Homepage dashboard takes them
  arr                        all three

  1. a dry run (make rotate CHECK=1, Ansible's check mode)
  2. after you confirm: the rotation

  --yes      do not ask
  --dry-run  print the make commands and run nothing

Example: anvil rotate radarr sonarr
`

var rotatable = []string{"radarr", "sonarr", "prowlarr", "arr"}

func cmdRotate(a *app.App, args []string) int {
	var yes, dry bool
	fs := flag.NewFlagSet("rotate", flag.ContinueOnError)
	fs.BoolVar(&yes, "yes", false, "")
	fs.BoolVar(&dry, "dry-run", false, "")
	pos, code, ok := a.Flags(fs, rotateUsage, app.InterleaveFlags(args))
	if !ok {
		return code
	}
	if len(pos) == 0 {
		fmt.Fprint(a.Stderr, rotateUsage)
		return 2
	}
	var secrets []string
	for _, p := range pos {
		for _, s := range strings.Split(strings.ToLower(p), ",") {
			if s == "" {
				continue
			}
			if !slices.Contains(rotatable, s) {
				fmt.Fprintf(a.Stderr, "anvil: rotate: no rotation for %q. These can rotate: %s\n", s, strings.Join(rotatable, ", "))
				return 2
			}
			if !slices.Contains(secrets, s) {
				secrets = append(secrets, s)
			}
		}
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	list := strings.Join(secrets, ",")
	if code := r.Make(run.NewMake("rotate", "SECRET", list, "CHECK", "1"), nil); code != 0 {
		return code
	}
	if !dry && !yes && !app.AskYesNo(a.Stdin, a.Stdout, fmt.Sprintf("Rotate %s now? The old keys stop working.", strings.Join(secrets, ", "))) {
		fmt.Fprintln(a.Stdout, "Nothing changed.")
		return 1
	}
	return r.Make(run.NewMake("rotate", "SECRET", list), nil)
}
