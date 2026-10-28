package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

const upUsage = `usage: anvil up [--yes] [--dry-run] [--from S] [--only S,...] [--skip S,...]
       anvil up <service>... [--yes] [--dry-run]

With no service, anvil up builds the whole lab, or converges a running one, in the
order of docs/setup.md (First build). The same command works on a fresh box and on the
running lab, because every stage is idempotent: on a lab that matches the code, every
check shows changed=0 and nothing is applied.

  1. anvil init's checks (tools, SSH key, Keychain pve-ip)
  2. the plan: every stage, what it touches and its make commands
  3. one confirmation: type "up" (--yes skips it, for unattended runs)
  4. the stages in order. Each runs its check first and applies only when the check
     shows changes. The first failure stops the run and prints the resume command.
  5. a summary: every stage with its result (unchanged, applied, skipped, failed,
     stopped or not run) and its time

Stages a person must do (Vault's unseal keys on a fresh box, Keychain writes, the
Cloudflare and NetBird dashboards) pause with the exact steps and wait for Enter. They
are skipped when already done. With --yes, anvil stops there with a resume hint.

build/anvil-up.state records the stages this run completed.

With services (anvil services lists them), anvil up deploys just those: pihole, caddy,
iptv, a VM such as apps, or a lab target such as vlans. Each runs check then apply.
It asks y/N (--yes skips it), and a risky target needs its name typed.

options:
  --yes          no confirmation (a risky service still needs its name typed)
  --dry-run      print the stage plan and the make commands, run nothing
  --from S       resume at stage S
  --only S,...   only these stages
  --skip S,...   leave these stages out

provision is never part of anvil up: it is for new hardware only (anvil provision).
`

func init() {
	app.Register(app.Command{Name: "up", Summary: "build or converge the whole lab, or deploy named services", Usage: upUsage, Run: cmdUp, Order: 1})
}

type stageKind int

const (
	// skCheckApply runs the check, and the real run only when it shows changes.
	skCheckApply stageKind = iota
	// skRun is idempotent by design and has no check mode.
	skRun
	// skHuman is done by a person. anvil pauses until it is done.
	skHuman
	// skStatus prints anvil status.
	skStatus
)

type stage struct {
	name    string
	touches string
	kind    stageKind
	t       target
	cmd     run.MakeCmd
	// done is a read-only bash probe. Exit 0: the stage has nothing to do.
	done     string
	doneText string
	// steps are what a person does (skHuman).
	steps string
	// ack: a human stage that no probe can see. Done once acknowledged with Enter, which
	// the state file keeps.
	ack bool
}

// keychainHas is a probe that every item exists. Without -w, security reads no value.
func keychainHas(items ...string) string {
	var parts []string
	for _, i := range items {
		parts = append(parts, "security find-generic-password -s homelab -a "+i+" >/dev/null 2>&1")
	}
	return strings.Join(parts, " && ")
}

// upStages is docs/setup.md, First build, as stages. Terraform is one stage: the plan
// guard refuses a targeted plan, so the Vault VM cannot go first on its own.
func upStages() []stage {
	ans := func(name, mk, args, touches string) stage {
		return stage{name: name, touches: touches, kind: skCheckApply,
			t: target{name: name, make: mk, args: args, checkArgs: checkDiff, summarize: ansibleSummary}}
	}
	labT := func(name, touches string) stage {
		for _, t := range labTargets() {
			if t.name == name {
				return stage{name: name, touches: touches, kind: skCheckApply, t: t}
			}
		}
		panic("no lab target " + name)
	}
	runOnly := func(name, mk, touches string) stage {
		return stage{name: name, touches: touches, kind: skRun, cmd: run.NewMake(mk)}
	}
	return []stage{
		ans("bootstrap-ssh-host", "bootstrap-ssh", "--limit proxmox", "step 1: the operator SSH key on the Proxmox host"),
		ans("host", "host", "--skip-tags homepage", "step 2: the Proxmox host base (the homepage tag needs Vault, it runs in host-homepage)"),
		labT("host-network", "step 3: the host network, with a timed rollback"),
		labT("ceph", "step 4: Ceph, the S3 gateway and the tfstate bucket (the first real run wipes the OSD disk)"),
		{name: "s3-keys", kind: skHuman, touches: "step 4: you copy the state bucket's S3 keys into the Keychain",
			done: keychainHas("ceph-s3-access-key", "ceph-s3-secret-key"), doneText: "the Keychain has ceph-s3-access-key and ceph-s3-secret-key",
			steps: `source scripts/env.sh && source scripts/keychain-lib.sh
keys=$(ssh root@"$PVE_IP" cat /root/.ceph-rgw-terraform.json)
jq -r .access_key <<<"$keys" | kc_store_stdin ceph-s3-access-key
jq -r .secret_key <<<"$keys" | kc_store_stdin ceph-s3-secret-key
unset keys`},
		runOnly("tf-init", "tf-init", "step 5: terraform init, with the S3 backend"),
		labT("tf", "step 5: Terraform, the VMs and SDN (tf-plan with the plan guard, then tf-apply)"),
		labT("vault", "step 6: the Vault server. It leaves Vault sealed"),
		{name: "vault-init", kind: skHuman, touches: "step 6: you initialize Vault once, the keys go to the Keychain",
			done: keychainHas("vault-init-json"), doneText: "the Keychain has vault-init-json",
			steps: `scripts/vault-init.sh    # once: 5 unseal keys and the root token go to Keychain vault-init-json
# It tells you how to print the unseal keys for an offline paper copy. Keep one.`},
		runOnly("vault-unseal", "vault-unseal", "step 6: unseal with 3 of the 5 keys (prints already unsealed)"),
		runOnly("vault-policies", "vault-policies", "step 6: Vault policies, each written only when it differs"),
		{name: "site-to-vault", kind: skRun, cmd: run.NewMake("site-to-vault"), touches: "step 6: the Keychain site dict into Vault",
			done:     `source scripts/env.sh >/dev/null 2>&1 && [ "$(scripts/site-source.sh 2>/dev/null)" = vault ]`,
			doneText: "Vault already holds kv/homelab/site"},
		{name: "backup-key", kind: skHuman, touches: "step 6: you create the age key pair for backups",
			done: keychainHas("backup-age-recipient", "backup-age-identity"), doneText: "the Keychain has backup-age-recipient and backup-age-identity",
			steps: `scripts/backup-key-init.sh    # once: the age key pair for backups, into the Keychain
# Keep an offline copy of backup-age-identity: without it the backups cannot be read.`},
		{name: "secrets", kind: skHuman, touches: "step 7: you put the secrets the roles read into Vault (docs/secrets.md)",
			done:     `source scripts/env.sh >/dev/null 2>&1 && vault kv get -mount=kv -field=cloudflare_dns_token homelab/apps/caddy >/dev/null 2>&1`,
			doneText: "Vault has kv/homelab/apps/caddy cloudflare_dns_token",
			steps: `# docs/secrets.md lists every path and key, docs/usage.md (Secrets in Vault) shows how.
# scripts/import-secrets.sh copies some from old VMs. Add by hand:
#   the Cloudflare tunnel token for each tunnel host
#   cloudflare_dns_token in kv/homelab/apps/caddy (may only edit DNS in your zone)
#   the NetBird setup keys
#   optionally, the Vaultwarden SMTP keys`},
		ans("ceph-users", "ceph", "", "step 7: Ceph again, the S3 users for Filestash and the Vaultwarden backups"),
		ans("host-homepage", "host", "--tags homepage", "step 7: the read-only Proxmox token for the dashboard"),
		labT("enclave", "step 8: the secrets enclave, firewall and SDN with timed rollbacks"),
		labT("vlans", "step 8: VLANs 10, 20 and 30, gateway addresses with a timed rollback"),
		labT("switch", "the Cisco switch's ports and VLANs (docs/setup.md, Switch)"),
		ans("bootstrap-ssh-guests", "bootstrap-ssh", "--limit guests", "step 9: the operator SSH key on the guests"),
		labT("vms", "step 9: every guest: base roles and all workloads"),
		{name: "handsteps", kind: skHuman, ack: true, touches: "you do the hand steps once (docs/setup.md, Not managed here)",
			doneText: "acknowledged once (build/anvil-up.state)",
			steps: `# docs/setup.md, Not managed here:
#   Cloudflare: the tunnels, their public hostnames, the DNS-01 API token
#   Home router: DHCP reservations, Pi-hole as the primary DNS server
#   NetBird: the nameserver, groups, access policy and routes in the dashboard
#   Self-hosted NetBird: the Cloudflare route, the return route, the device profiles
#   The Mac's route to the secrets enclave
#   The Wi-Fi access point and the app settings`},
		runOnly("backup", "backup", "step 10: Terraform state, a Vault snapshot, Vaultwarden, into ~/homelab-backups"),
		{name: "status", kind: skStatus, touches: "anvil status"},
	}
}

const stateFile = "build/anvil-up.state"

type upState struct {
	Started      string   `json:"started"`
	Completed    []string `json:"completed"`
	Acknowledged []string `json:"acknowledged"`
}

func loadState(root string) upState {
	var s upState
	if b, err := os.ReadFile(filepath.Join(root, stateFile)); err == nil {
		_ = json.Unmarshal(b, &s)
	}
	return s
}

func saveState(root string, s upState) error {
	p := filepath.Join(root, stateFile)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	return os.WriteFile(p, append(b, '\n'), 0o600)
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// selectStages applies --from, --only and --skip.
func selectStages(all []stage, from, only, skip string) ([]stage, error) {
	names := make([]string, len(all))
	for i, s := range all {
		names[i] = s.name
	}
	check := func(n string) error {
		if slices.Contains(names, n) {
			return nil
		}
		msg := fmt.Sprintf("unknown stage %q", n)
		var near []string
		for _, c := range names {
			if levenshtein(n, c) <= 2 || strings.Contains(c, n) {
				near = append(near, c)
			}
		}
		if len(near) > 0 {
			msg += ". Did you mean: " + strings.Join(near, ", ") + "?"
		}
		return fmt.Errorf("%s (stages: %s)", msg, strings.Join(names, ", "))
	}
	onlyL, skipL := splitList(only), splitList(skip)
	for _, n := range append(append([]string{}, onlyL...), skipL...) {
		if err := check(n); err != nil {
			return nil, err
		}
	}
	if from != "" {
		if err := check(from); err != nil {
			return nil, err
		}
	}
	var out []stage
	started := from == ""
	for _, s := range all {
		if s.name == from {
			started = true
		}
		if !started || (len(onlyL) > 0 && !slices.Contains(onlyL, s.name)) || slices.Contains(skipL, s.name) {
			continue
		}
		out = append(out, s)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no stage left to run")
	}
	return out, nil
}

func printPlan(w io.Writer, stages []stage, all int) {
	fmt.Fprintf(w, "anvil up: %d of %d stages, in the order of docs/setup.md (First build).\n", len(stages), all)
	fmt.Fprintln(w, "Each command runs as: bash -c 'source scripts/env.sh && <command>' in the repo root.")
	for i, s := range stages {
		fmt.Fprintf(w, "\n%3d. %-21s %s\n", i+1, s.name, s.touches)
		switch s.kind {
		case skCheckApply:
			fmt.Fprintf(w, "       check  %s\n", s.t.checkCmd("", ""))
			fmt.Fprintf(w, "       apply  %s   (only when the check shows changes)\n", s.t.applyCmd("", ""))
		case skRun:
			fmt.Fprintf(w, "       run    %s\n", s.cmd)
			if s.doneText != "" {
				fmt.Fprintf(w, "       skip   when %s\n", s.doneText)
			}
		case skHuman:
			fmt.Fprintf(w, "       pause  for you, skipped when %s\n", s.doneText)
		case skStatus:
			fmt.Fprintln(w, "       run    anvil status (read-only)")
		}
	}
	fmt.Fprintln(w)
}

// exitNeedsYou is a stop that waits for a person, not a failure of make.
const exitNeedsYou = 3

func runStage(a *app.App, r *run.Runner, s stage, st *upState, yes bool) (int, outcome) {
	switch s.kind {
	case skCheckApply:
		return checkThenApply(a, r, s.t, targetOpts{}, nil)
	case skRun:
		if s.done != "" {
			if _, code := r.Quiet(s.done); code == 0 {
				fmt.Fprintf(a.Stdout, "anvil: %s: already done (%s)\n", s.name, s.doneText)
				return 0, outSkipped
			}
		}
		if !canReach(a, r, s.cmd.Target) {
			return 1, outFailed
		}
		if code := r.Make(s.cmd, nil); code != 0 {
			return code, outFailed
		}
		return 0, outApplied
	case skStatus:
		if code := a.Status(a, r); code != 0 {
			return code, outFailed
		}
		return 0, outUnchanged
	}
	// skHuman
	isDone := func() bool {
		if s.ack {
			return slices.Contains(st.Acknowledged, s.name)
		}
		_, code := r.Quiet(s.done)
		return code == 0
	}
	if isDone() {
		fmt.Fprintf(a.Stdout, "anvil: %s: already done (%s)\n", s.name, s.doneText)
		return 0, outSkipped
	}
	fmt.Fprintf(a.Stdout, "anvil: %s needs you: %s\n\n%s\n\n", s.name, s.touches, s.steps)
	hint := fmt.Sprintf("Do the steps above, then resume: anvil up --from %s", s.name)
	if yes {
		fmt.Fprintf(a.Stderr, "anvil: stopped at %s (--yes never waits). %s\n", s.name, hint)
		return exitNeedsYou, outStopped
	}
	fmt.Fprint(a.Stdout, "Press Enter when done, or type q to stop: ")
	ans, ok := app.ReadLine(a.Stdin)
	if !ok || ans == "q" {
		fmt.Fprintf(a.Stderr, "\nanvil: stopped at %s. %s\n", s.name, hint)
		return exitNeedsYou, outStopped
	}
	if s.ack {
		st.Acknowledged = append(st.Acknowledged, s.name)
		return 0, outApplied
	}
	if !isDone() {
		fmt.Fprintf(a.Stderr, "anvil: %s is still not done (%s is not true). %s\n", s.name, s.doneText, hint)
		return exitNeedsYou, outStopped
	}
	return 0, outApplied
}

// runAll runs steps in order with a header and a timed footer for each, and prints the
// summary table at the end, also when a step stops the run. It returns the index of the
// step that stopped it (or len(names)) and its exit code.
func runAll(a *app.App, names []string, step func(i int) (int, outcome)) (int, int) {
	p := a.Pal()
	start := time.Now()
	var rs []stageResult
	stop, code := len(names), 0
	for i, n := range names {
		stageHeader(a.Stdout, p, i+1, len(names), n)
		t0 := time.Now()
		c, out := step(i)
		r := stageResult{name: n, out: out, dur: since(t0)}
		rs = append(rs, r)
		stageFooter(a.Stdout, p, i+1, len(names), r)
		if c != 0 {
			stop, code = i, c
			for _, rest := range names[i+1:] {
				rs = append(rs, stageResult{name: rest, out: outNotRun})
			}
			break
		}
	}
	printSummary(a.Stdout, p, rs, since(start))
	return stop, code
}

func preflightChecks(a *app.App, r *run.Runner) bool {
	all := initFindings(a, r)
	printFindings(a.Stdout, a.Pal(), all)
	for _, f := range all {
		if f.upNeeds && f.lv == lvFail {
			fmt.Fprintln(a.Stderr, "anvil up: fix the FAIL lines above first (Vault may still be down: up builds it)")
			return false
		}
	}
	fmt.Fprintln(a.Stdout)
	return true
}

func cmdUp(a *app.App, args []string) int {
	fs := flag.NewFlagSet("up", flag.ContinueOnError)
	var yes, dry bool
	var from, only, skip string
	fs.BoolVar(&yes, "yes", false, "")
	fs.BoolVar(&dry, "dry-run", false, "")
	fs.StringVar(&from, "from", "", "")
	fs.StringVar(&only, "only", "", "")
	fs.StringVar(&skip, "skip", "", "")
	pos, code, ok := a.Flags(fs, upUsage, args)
	if !ok {
		return code
	}
	if a.Preflight == nil {
		a.Preflight = preflightChecks
	}
	if a.Status == nil {
		a.Status = printStatus
	}
	if len(pos) > 0 {
		if from != "" || only != "" || skip != "" {
			fmt.Fprintf(a.Stderr, "anvil: --from, --only and --skip are for the whole lab, not services\n")
			return 2
		}
		return upServices(a, pos, yes, dry)
	}
	all := upStages()
	stages, err := selectStages(all, from, only, skip)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return 2
	}
	r, ok := repo.Runner(a, dry)
	if !ok {
		return 1
	}
	if dry {
		printPlan(a.Stdout, stages, len(all))
		return 0
	}
	if !a.Preflight(a, r) {
		return 1
	}
	printPlan(a.Stdout, stages, len(all))
	if !yes && !app.AskTyped(a.Stdin, a.Stdout, fmt.Sprintf("This runs %d stages on the lab.", len(stages)), "up") {
		fmt.Fprintln(a.Stdout, "anvil: nothing run")
		return 1
	}
	st := loadState(r.Root)
	if from == "" {
		st.Completed = nil
		st.Started = time.Now().UTC().Format(time.RFC3339)
	}
	names := make([]string, len(stages))
	for i, s := range stages {
		names[i] = s.name
	}
	stop, code := runAll(a, names, func(i int) (int, outcome) {
		s := stages[i]
		code, out := runStage(a, r, s, &st, yes)
		if code == 0 && !slices.Contains(st.Completed, s.name) {
			st.Completed = append(st.Completed, s.name)
		}
		if err := saveState(r.Root, st); err != nil {
			fmt.Fprintf(a.Stderr, "anvil: cannot write %s: %v\n", stateFile, err)
		}
		return code, out
	})
	switch {
	case code == exitNeedsYou:
		return code
	case code != 0:
		n := stages[stop].name
		fmt.Fprintf(a.Stderr, "anvil up: stage %s failed (exit %d). Fix it, then resume: anvil up --from %s\n", n, code, n)
		return code
	}
	fmt.Fprintf(a.Stdout, "\nanvil up: done, %d stages\n", len(stages))
	return 0
}

// upServices deploys named services: check, then apply where the check shows changes.
func upServices(a *app.App, names []string, yes, dry bool) int {
	r, c, ok := setup(a, dry)
	if !ok {
		return 1
	}
	var ts []target
	for _, n := range names {
		t, err := c.resolve(n, "")
		if err != nil {
			fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
			return 2
		}
		ts = append(ts, t)
	}
	if dry {
		for _, t := range ts {
			_, _ = checkThenApply(a, r, t, targetOpts{}, nil)
		}
		return 0
	}
	if !a.Preflight(a, r) {
		return 1
	}
	fmt.Fprintln(a.Stdout, "anvil up: deploy, each one checked first and applied only when the check shows changes:")
	var plain []string
	for _, t := range ts {
		fmt.Fprintf(a.Stdout, "  %-15s %s\n", t.name, t.help)
		fmt.Fprintf(a.Stdout, "    check  %s\n    apply  %s\n", t.checkCmd("", ""), t.applyCmd("", ""))
		if !t.risky {
			plain = append(plain, t.name)
		}
	}
	if len(plain) > 0 && !yes && !app.AskYesNo(a.Stdin, a.Stdout, "Deploy "+strings.Join(plain, ", ")+"?") {
		fmt.Fprintln(a.Stdout, "anvil: nothing run")
		return 1
	}
	confirm := func(t target) bool { return !t.risky || confirmApply(a.Stdin, a.Stdout, t, yes) }
	tnames := make([]string, len(ts))
	for i, t := range ts {
		tnames[i] = t.name
	}
	stop, code := runAll(a, tnames, func(i int) (int, outcome) { return checkThenApply(a, r, ts[i], targetOpts{}, confirm) })
	if code != 0 {
		fmt.Fprintf(a.Stderr, "anvil up: %s stopped (exit %d). Resume: anvil up %s\n", ts[stop].name, code, strings.Join(names[stop:], " "))
	}
	return code
}
