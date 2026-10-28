package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

const checkUsage = `usage: anvil check [target] [--host H] [--tags T] [--args A] [--dry-run]

Dry runs a target and prints what the real run would change. It changes nothing.

  Ansible targets   make <target> ARGS="--check --diff"
  tf                make tf-plan (saves the plan for tf-apply, runs the plan guard)
  switch            make switch (prints the planned switch commands)

The target is a lab target (host, host-network, ceph, tf, vault, enclave, vlans, cluster, switch,
vms, vm, bootstrap-ssh), a VM (apps, frigate, ...) or a service (pihole, caddy, ...).
anvil services lists them all. With no target it checks host, vms and tf.

options:
  --host H    one VM, for vm, vms or a service on several VMs
  --tags T    add --tags T to ARGS
  --args A    more ARGS for ansible-playbook or terraform (never --force or -target)
  --dry-run   print the make commands, run nothing
`

const applyUsage = `usage: anvil apply <target> [--host H] [--tags T] [--args A] [--yes] [--dry-run]

Runs the check first (see anvil check) and prints its summary. When the check shows no
changes, it stops there. Otherwise it asks y/N, then runs the real target.

Risky targets need their name typed, and --yes does not skip that: host-network,
enclave, vlans, cluster, switch and tf (make tf-apply applies the plan tf-plan saved). The
guards inside the scripts still apply (plan guard, timed rollbacks). anvil never adds
a force flag.

options:
  --host H    one VM, for vm, vms or a service on several VMs
  --tags T    add --tags T to ARGS
  --args A    more ARGS (never --force or -target)
  --yes       skip the y/N question (not the typed name of a risky target)
  --dry-run   print the check and apply commands, run nothing
`

const servicesUsage = `usage: anvil services

Lists what anvil check, apply and up accept: the services (every role tag in
ansible/playbooks/vms.yml, on the hosts of its play), the VMs and the lab targets, with
the make command each one runs.
`

const backupUsage = `usage: anvil backup [--dry-run]

Runs make backup: Terraform state (age encrypted), a Vault Raft snapshot and the newest
Vaultwarden backup, into ~/homelab-backups.
`

const restoreUsage = `usage: anvil restore <what> [file] [--yes] [--dry-run]

  tfstate [file]   push a Terraform state backup (default: the newest) back into the
                   bucket. It prints the backup's serial first, then needs "tfstate"
                   typed. Terraform refuses a different lineage or a lower serial.
  drill            make vaultwarden-drill: restore the newest Vaultwarden backup into a
                   temporary container, check it, remove it
  vault            not scripted: docs/setup.md, Rebuilding on a new box, step 5
  vaultwarden      not scripted: docs/setup.md, Rebuilding on a new box, step 8
`

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

func init() {
	app.Register(app.Command{Name: "check", Summary: "dry run a target (--check --diff, tf-plan, the switch plan)", Usage: checkUsage, Run: cmdCheck, Order: 20})
	app.Register(app.Command{Name: "apply", Summary: "check a target, then apply it after confirmation", Usage: applyUsage, Run: cmdApply, Order: 21})
	app.Register(app.Command{Name: "services", Summary: "list the deployable services, VMs and lab targets", Usage: servicesUsage, Run: cmdServices, Order: 22})
	app.Register(app.Command{Name: "backup", Summary: "make backup", Usage: backupUsage, Run: cmdBackup, Order: 30})
	app.Register(app.Command{Name: "restore", Summary: "the documented restore commands, with confirmation", Usage: restoreUsage, Run: cmdRestore, Order: 31})
	app.Register(app.Command{Name: "provision-iso", Summary: "make provision-iso NAME=<name>", Usage: provisionISOUsage, Run: cmdProvisionISO, Order: 40})
	app.Register(app.Command{Name: "provision", Summary: "make provision NAME=<name> (a dry run unless --install)", Usage: provisionUsage, Run: cmdProvision, Order: 41})
}

type targetOpts struct {
	host, tags, args string
	yes, dryRun      bool
}

func targetFlags(fs *flag.FlagSet, o *targetOpts, withYes bool) {
	fs.StringVar(&o.host, "host", "", "")
	fs.StringVar(&o.tags, "tags", "", "")
	fs.StringVar(&o.args, "args", "", "")
	fs.BoolVar(&o.dryRun, "dry-run", false, "")
	if withYes {
		fs.BoolVar(&o.yes, "yes", false, "")
	}
}

// setup parses nothing more: it finds the repo and loads the catalog.
func setup(a *app.App, dryRun bool) (*run.Runner, *catalog, bool) {
	r, ok := repo.Runner(a, dryRun)
	if !ok {
		return nil, nil, false
	}
	c, err := loadCatalog(r.Root)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return nil, nil, false
	}
	if !prepare(a, r) {
		return nil, nil, false
	}
	return r, c, true
}

// runCheck runs one target's dry run and returns its exit code and summary.
func runCheck(a *app.App, r *run.Runner, t target, o targetOpts) (int, summary) {
	m := t.checkCmd(o.tags, o.args)
	if !canReach(a, r, m.Target) {
		return 1, summary{}
	}
	var out bytes.Buffer
	code := r.Make(m, &out)
	if code != 0 || r.DryRun {
		return code, summary{}
	}
	return 0, t.summarize(out.String())
}

// checkThenApply runs the check, prints its summary and, when it shows changes and
// confirm agrees, the real run. A nil confirm applies without asking. It returns the exit
// code and what happened.
func checkThenApply(a *app.App, r *run.Runner, t target, o targetOpts, confirm func(target) bool) (int, outcome) {
	if r.DryRun {
		fmt.Fprintf(a.Stdout, "# %s: check\n", t.name)
		r.Make(t.checkCmd(o.tags, o.args), nil)
		fmt.Fprintf(a.Stdout, "# %s: apply, only when the check shows changes\n", t.name)
		r.Make(t.applyCmd(o.tags, o.args), nil)
		return 0, outSkipped
	}
	code, s := runCheck(a, r, t, o)
	if code != 0 {
		fmt.Fprintf(a.Stderr, "anvil: the check of %s failed (exit %d); nothing applied\n", t.name, code)
		return code, outFailed
	}
	fmt.Fprintf(a.Stdout, "anvil: %s check: %s\n", t.name, s)
	if s.known && !s.changes {
		fmt.Fprintf(a.Stdout, "anvil: %s has nothing to apply\n", t.name)
		return 0, outUnchanged
	}
	if confirm != nil && !confirm(t) {
		fmt.Fprintf(a.Stdout, "anvil: %s not applied\n", t.name)
		return 1, outSkipped
	}
	if code := r.Make(t.applyCmd(o.tags, o.args), nil); code != 0 {
		return code, outFailed
	}
	return 0, outApplied
}

func cmdCheck(a *app.App, args []string) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	var o targetOpts
	targetFlags(fs, &o, false)
	pos, code, ok := a.Flags(fs, checkUsage, args)
	if !ok {
		return code
	}
	if len(pos) > 1 {
		fmt.Fprintf(a.Stderr, "anvil: check takes one target\n\n%s", checkUsage)
		return 2
	}
	if err := checkExtraArgs(o.args); err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return 2
	}
	r, c, ok := setup(a, o.dryRun)
	if !ok {
		return 1
	}
	names := []string{"host", "vms", "tf"}
	if len(pos) == 1 {
		names = pos
	} else if o.host != "" || o.tags != "" || o.args != "" {
		fmt.Fprintf(a.Stderr, "anvil: --host, --tags and --args need a target\n")
		return 2
	}
	first := 0
	for _, n := range names {
		t, err := c.resolve(n, o.host)
		if err != nil {
			fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
			return 2
		}
		code, s := runCheck(a, r, t, o)
		switch {
		case r.DryRun:
		case code != 0:
			fmt.Fprintf(a.Stderr, "anvil: the check of %s failed (exit %d)\n", t.name, code)
		default:
			fmt.Fprintf(a.Stdout, "anvil: %s check: %s\n", t.name, s)
		}
		if code != 0 && first == 0 {
			first = code
		}
	}
	return first
}

func cmdApply(a *app.App, args []string) int {
	fs := flag.NewFlagSet("apply", flag.ContinueOnError)
	var o targetOpts
	targetFlags(fs, &o, true)
	pos, code, ok := a.Flags(fs, applyUsage, args)
	if !ok {
		return code
	}
	if len(pos) != 1 {
		fmt.Fprintf(a.Stderr, "anvil: apply takes one target\n\n%s", applyUsage)
		return 2
	}
	if err := checkExtraArgs(o.args); err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return 2
	}
	r, c, ok := setup(a, o.dryRun)
	if !ok {
		return 1
	}
	t, err := c.resolve(pos[0], o.host)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return 2
	}
	code, _ = checkThenApply(a, r, t, o, func(t target) bool { return confirmApply(a.Stdin, a.Stdout, t, o.yes) })
	return code
}

func cmdServices(a *app.App, args []string) int {
	fs := flag.NewFlagSet("services", flag.ContinueOnError)
	if _, code, ok := a.Flags(fs, servicesUsage, args); !ok {
		return code
	}
	_, c, ok := setup(a, false)
	if !ok {
		return 1
	}
	w := a.Stdout
	fmt.Fprintf(w, "Services (role tags in %s):\n", playbookPath)
	for _, s := range c.services {
		t, err := c.resolve(s.name, "")
		if err != nil {
			continue
		}
		note := ""
		if t.tags == "" {
			note = "  (the name means the whole " + t.name + " target; add --tags " + s.name + " for the tag alone)"
		}
		fmt.Fprintf(w, "  %-15s %-44s %s%s\n", s.name, strings.Join(s.hosts, ","), t.applyCmd("", ""), note)
	}
	fmt.Fprintln(w, "\nVMs (every guest play for one VM):")
	for _, v := range c.vms {
		note := ""
		if t, err := c.resolve(v, ""); err != nil || t.make != "vm" {
			note = "  (as vm --host " + v + "; the name " + v + " is the lab target)"
		}
		fmt.Fprintf(w, "  %-15s %s%s\n", v, c.vmTarget(v).applyCmd("", ""), note)
	}
	fmt.Fprintln(w, "\nLab targets (risky ones need their name typed):")
	for _, t := range labTargets() {
		risk := ""
		if t.risky {
			risk = "risky"
		}
		fmt.Fprintf(w, "  %-15s %-6s %s\n", t.name, risk, t.help)
	}
	fmt.Fprintln(w, "\nAliases:")
	for _, k := range sortedKeys(serviceAliases) {
		fmt.Fprintf(w, "  %-15s %s\n", k, serviceAliases[k])
	}
	for _, k := range sortedKeys(targetAliases) {
		fmt.Fprintf(w, "  %-15s %s\n", k, targetAliases[k])
	}
	return 0
}

func simpleFlags(a *app.App, name, usage string, args []string, withYes bool) (pos []string, yes, dryRun bool, code int, ok bool) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.BoolVar(&dryRun, "dry-run", false, "")
	if withYes {
		fs.BoolVar(&yes, "yes", false, "")
	}
	pos, code, ok = a.Flags(fs, usage, args)
	return
}

func cmdBackup(a *app.App, args []string) int {
	pos, _, dry, code, ok := simpleFlags(a, "backup", backupUsage, args, false)
	if !ok {
		return code
	}
	if len(pos) > 0 {
		fmt.Fprintf(a.Stderr, "anvil: backup takes no arguments\n")
		return 2
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	return r.Make(run.NewMake("backup"), nil)
}

func cmdRestore(a *app.App, args []string) int {
	pos, yes, dry, code, ok := simpleFlags(a, "restore", restoreUsage, args, true)
	if !ok {
		return code
	}
	if len(pos) == 0 {
		fmt.Fprint(a.Stderr, restoreUsage)
		return 2
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	switch pos[0] {
	case "tfstate":
		if len(pos) > 2 {
			fmt.Fprint(a.Stderr, restoreUsage)
			return 2
		}
		file := ""
		if len(pos) == 2 {
			file = " " + run.ShellQuote(pos[1])
		}
		fmt.Fprintln(a.Stdout, "anvil: the backup's serial:")
		if code := r.Shell("scripts/backup-restore-tfstate.sh"+file+" | jq .serial", nil); code != 0 {
			return code
		}
		if !dry && !app.AskTyped(a.Stdin, a.Stdout, "This pushes the backup into the Terraform state bucket.", "tfstate") {
			fmt.Fprintln(a.Stdout, "anvil: not restored")
			return 1
		}
		return r.Shell(run.EnvPrefix+"scripts/backup-restore-tfstate.sh"+file+" | terraform -chdir=terraform state push -", nil)
	case "drill":
		if len(pos) > 1 {
			fmt.Fprint(a.Stderr, restoreUsage)
			return 2
		}
		if !dry && !yes && !app.AskYesNo(a.Stdin, a.Stdout, "Run the Vaultwarden restore drill on the vaultwarden VM?") {
			return 1
		}
		return r.Make(run.NewMake("vaultwarden-drill"), nil)
	case "vault":
		fmt.Fprintln(a.Stderr, "anvil: restoring Vault is not scripted. Follow docs/setup.md, Rebuilding on a new box, step 5.")
		return 2
	case "vaultwarden":
		fmt.Fprintln(a.Stderr, "anvil: restoring Vaultwarden is not scripted. Follow docs/setup.md, Rebuilding on a new box, step 8. anvil restore drill tests a backup.")
		return 2
	}
	fmt.Fprintf(a.Stderr, "anvil: unknown restore %q\n\n%s", pos[0], restoreUsage)
	return 2
}

func cmdProvisionISO(a *app.App, args []string) int {
	pos, _, dry, code, ok := simpleFlags(a, "provision-iso", provisionISOUsage, args, false)
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

// confirmApply is the confirmation before a real run. Every target needs a yes, which
// --yes gives. A risky target also needs its name typed, which --yes does not skip.
func confirmApply(in *bufio.Reader, out io.Writer, t target, yes bool) bool {
	if t.risky {
		return app.AskTyped(in, out, fmt.Sprintf("%s is a risky target (%s).", t.name, t.help), t.name)
	}
	if yes {
		return true
	}
	return app.AskYesNo(in, out, fmt.Sprintf("Apply %s?", t.name))
}
