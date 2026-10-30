package lab

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

const applyUsage = `usage: anvil apply <target> [--host H] [--tags T] [--args A] [--yes] [--no-smoke] [--dry-run]

Runs the check first (see anvil check) and prints its summary. When the check shows no
changes, it stops there. Otherwise it asks y/N, then runs the real target.

Risky targets need their name typed, and --yes does not skip that: host-network,
enclave, vlans, cluster, switch and tf (make tf-apply applies the plan tf-plan saved). The
guards inside the scripts still apply (plan guard, timed rollbacks). anvil never adds
a force flag.

After an apply that changed something, the smoke tests run (anvil test smoke): read-only
checks of the live lab. A failed one makes the exit code 1.

options:
  --host H    one VM, for vm, vms or a service on several VMs
  --tags T    add --tags T to ARGS
  --args A    more ARGS (never --force or -target)
  --yes       skip the y/N question (not the typed name of a risky target)
  --no-smoke  no smoke tests after the apply
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

func init() {
	app.Register(app.Command{Name: "check", Summary: "dry run a target (--check --diff, tf-plan, the switch plan)", Usage: checkUsage, Run: cmdCheck, Order: 20})
	app.Register(app.Command{Name: "apply", Summary: "check a target, then apply it after confirmation", Usage: applyUsage, Run: cmdApply, Order: 21})
	app.Register(app.Command{Name: "services", Summary: "list the deployable services, VMs and lab targets", Usage: servicesUsage, Run: cmdServices, Order: 22})
	app.Register(app.Command{Name: "backup", Summary: "make backup", Usage: backupUsage, Run: cmdBackup, Order: 30})
	app.Register(app.Command{Name: "restore", Summary: "the documented restore commands, with confirmation", Usage: restoreUsage, Run: cmdRestore, Order: 31})
}

// TargetOpts are the options of check and apply.
type TargetOpts struct {
	host, tags, args     string
	yes, dryRun, noSmoke bool
}

func targetFlags(fs *flag.FlagSet, o *TargetOpts, withYes bool) {
	fs.StringVar(&o.host, "host", "", "")
	fs.StringVar(&o.tags, "tags", "", "")
	fs.StringVar(&o.args, "args", "", "")
	fs.BoolVar(&o.dryRun, "dry-run", false, "")
	if withYes {
		fs.BoolVar(&o.yes, "yes", false, "")
		fs.BoolVar(&o.noSmoke, "no-smoke", false, "")
	}
}

// Setup parses nothing more: it finds the repo and loads the catalog.
func Setup(a *app.App, dryRun bool) (*run.Runner, *Catalog, bool) {
	r, ok := repo.Runner(a, dryRun)
	if !ok {
		return nil, nil, false
	}
	c, err := LoadCatalog(r.Root)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return nil, nil, false
	}
	if !prepare(a, r) {
		return nil, nil, false
	}
	return r, c, true
}

// RunCheck runs one target's dry run and returns its exit code and summary.
func RunCheck(a *app.App, r *run.Runner, t Target, o TargetOpts) (int, Summary) {
	m := t.checkCmd(o.tags, o.args)
	if !canReach(a, r, m.Target) {
		return 1, Summary{}
	}
	var out bytes.Buffer
	code := r.Make(m, &out)
	if code != 0 || r.DryRun {
		return code, Summary{}
	}
	return 0, t.summarize(out.String())
}

// checkThenApply runs the check, prints its summary and, when it shows changes and
// confirm agrees, the real run. A nil confirm applies without asking. It returns the exit
// code and what happened.
func checkThenApply(a *app.App, r *run.Runner, t Target, o TargetOpts, confirm func(Target) bool) (int, outcome) {
	if r.DryRun {
		fmt.Fprintf(a.Stdout, "# %s: check\n", t.Name)
		r.Make(t.checkCmd(o.tags, o.args), nil)
		fmt.Fprintf(a.Stdout, "# %s: apply, only when the check shows changes\n", t.Name)
		r.Make(t.applyCmd(o.tags, o.args), nil)
		return 0, outSkipped
	}
	code, s := RunCheck(a, r, t, o)
	if code != 0 {
		fmt.Fprintf(a.Stderr, "anvil: the check of %s failed (exit %d); nothing applied\n", t.Name, code)
		return code, outFailed
	}
	fmt.Fprintf(a.Stdout, "anvil: %s check: %s\n", t.Name, s)
	if s.Known && !s.Changes {
		fmt.Fprintf(a.Stdout, "anvil: %s has nothing to apply\n", t.Name)
		return 0, outUnchanged
	}
	if confirm != nil && !confirm(t) {
		fmt.Fprintf(a.Stdout, "anvil: %s not applied\n", t.Name)
		return 1, outSkipped
	}
	if code := r.Make(t.applyCmd(o.tags, o.args), nil); code != 0 {
		return code, outFailed
	}
	return 0, outApplied
}

func cmdCheck(a *app.App, args []string) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	var o TargetOpts
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
	r, c, ok := Setup(a, o.dryRun)
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
		t, err := c.Resolve(n, o.host)
		if err != nil {
			fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
			return 2
		}
		code, s := RunCheck(a, r, t, o)
		switch {
		case r.DryRun:
		case code != 0:
			fmt.Fprintf(a.Stderr, "anvil: the check of %s failed (exit %d)\n", t.Name, code)
		default:
			fmt.Fprintf(a.Stdout, "anvil: %s check: %s\n", t.Name, s)
		}
		if code != 0 && first == 0 {
			first = code
		}
	}
	return first
}

func cmdApply(a *app.App, args []string) int {
	fs := flag.NewFlagSet("apply", flag.ContinueOnError)
	var o TargetOpts
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
	r, c, ok := Setup(a, o.dryRun)
	if !ok {
		return 1
	}
	t, err := c.Resolve(pos[0], o.host)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return 2
	}
	code, out := checkThenApply(a, r, t, o, func(t Target) bool { return confirmApply(a.Stdin, a.Stdout, t, o.yes) })
	if code == 0 && (out == outApplied || r.DryRun) && !o.noSmoke {
		code = smokeAfter(a, r)
	}
	return code
}

func cmdServices(a *app.App, args []string) int {
	fs := flag.NewFlagSet("services", flag.ContinueOnError)
	if _, code, ok := a.Flags(fs, servicesUsage, args); !ok {
		return code
	}
	_, c, ok := Setup(a, false)
	if !ok {
		return 1
	}
	w := a.Stdout
	fmt.Fprintf(w, "Services (role tags in %s):\n", playbookPath)
	for _, s := range c.services {
		t, err := c.Resolve(s.name, "")
		if err != nil {
			continue
		}
		note := ""
		if t.tags == "" {
			note = "  (the name means the whole " + t.Name + " target; add --tags " + s.name + " for the tag alone)"
		}
		fmt.Fprintf(w, "  %-15s %-44s %s%s\n", s.name, strings.Join(s.hosts, ","), t.applyCmd("", ""), note)
	}
	fmt.Fprintln(w, "\nVMs (every guest play for one VM):")
	for _, v := range c.vms {
		note := ""
		if t, err := c.Resolve(v, ""); err != nil || t.make != "vm" {
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
		fmt.Fprintf(w, "  %-15s %-6s %s\n", t.Name, risk, t.help)
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

// confirmApply is the confirmation before a real run. Every target needs a yes, which
// --yes gives. A risky target also needs its name typed, which --yes does not skip.
func confirmApply(in *bufio.Reader, out io.Writer, t Target, yes bool) bool {
	if t.risky {
		return app.AskTyped(in, out, fmt.Sprintf("%s is a risky target (%s).", t.Name, t.help), t.Name)
	}
	if yes {
		return true
	}
	return app.AskYesNo(in, out, fmt.Sprintf("Apply %s?", t.Name))
}
