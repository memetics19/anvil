package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/run"
)

const (
	initUsage   = "usage: anvil init\n       anvil doctor\n" + checksUsage
	doctorUsage = "usage: anvil doctor [--fix]\n       anvil init\n" + checksUsage + doctorFixUsage
)

const checksUsage = `
Checks, read-only, that this Mac can run the lab. doctor and init are the same:

  tools      installed, at the minimum versions in docs/setup.md, and hvac in the
             Python that runs Ansible
  files      the SSH key ~/.ssh/id_ed25519 and Vault's CA certificate
  keychain   the items of service homelab (docs/setup.md, Keychain items): only
             their names and whether each is there, never a value
  vault      reachable and unsealed
  version    this binary's version matches the repo checkout (a warning)
  network    macOS only: no lab address alias or route left on the Wi-Fi or a USB
             adapter hides the VPN's route to the lab

Each problem comes with its fix. Exit 1 when something is missing.
`

const doctorFixUsage = `
  --fix      before the checks, remove the lab aliases and routes that hide the VPN
             (the network check). It shows what it found and asks first. sudo asks
             for your password. Nothing in the lab changes.
`

func init() {
	app.Register(app.Command{Name: "init", Summary: "check the tools, the Keychain items and Vault (read-only)", Usage: initUsage, Run: cmdInit, Order: 10})
	app.Register(app.Command{Name: "doctor", Summary: "the same checks as init, by its future name", Usage: doctorUsage, Run: cmdInit, Order: 10})
}

type level int

const (
	lvOK level = iota
	lvWarn
	lvFail
)

type finding struct {
	group string
	lv    level
	text  string
	fix   string
	// upNeeds: anvil up cannot start without it. Vault is not one: up builds it.
	upNeeds bool
}

type toolSpec struct {
	name string
	args []string
	min  string
	fix  string
}

// tools are the brew list in docs/setup.md, with the versions it pins as minimums.
var tools = []toolSpec{
	{"terraform", []string{"version"}, "1.10", "brew install hashicorp/tap/terraform"},
	{"vault", []string{"version"}, "", "brew install hashicorp/tap/vault"},
	{"ansible-playbook", []string{"--version"}, "", "brew install ansible"},
	{"ansible-lint", []string{"--version"}, "25.9.2", "brew install ansible-lint"},
	{"yamllint", []string{"--version"}, "1.37.1", "brew install yamllint"},
	{"gitleaks", []string{"version"}, "8.28.0", "brew install gitleaks"},
	{"tflint", []string{"--version"}, "", "brew install tflint"},
	{"jq", []string{"--version"}, "", "brew install jq"},
	{"age", []string{"--version"}, "", "brew install age"},
	{"sshpass", []string{"-V"}, "", "brew install sshpass"},
	{"aws", []string{"--version"}, "", "brew install awscli"},
	{"pre-commit", []string{"--version"}, "", "brew install pre-commit"},
	{"python3", []string{"--version"}, "", "brew install python"},
	{"git", []string{"--version"}, "", "xcode-select --install"},
	{"security", nil, "", "a Mac: the scripts keep secrets in its Keychain"},
}

type keychainItem struct {
	name     string
	required bool
	fix      string
}

// keychainItems is the table in docs/setup.md (service homelab).
var keychainItems = []keychainItem{
	{"pve-ip", true, "security add-generic-password -s homelab -a pve-ip -w <proxmox-address>"},
	{"vault-ip", false, "security add-generic-password -s homelab -a vault-ip -w <vault-address>"},
	{"site-bootstrap", false, "docs/setup.md, Create the bootstrap copy"},
	{"pve-root-password", false, "security add-generic-password -s homelab -a pve-root-password -w"},
	{"vm-sudo-password", false, "security add-generic-password -s homelab -a vm-sudo-password -w"},
	{"pve-api-token", false, "make host creates it"},
	{"ceph-osd-disk-id", false, "security add-generic-password -s homelab -a ceph-osd-disk-id -w <by-id-name>, unless site.pve.ceph_osd_disk_id is set"},
	{"ceph-s3-access-key", false, "docs/setup.md, First build, step 4"},
	{"ceph-s3-secret-key", false, "docs/setup.md, First build, step 4"},
	{"ceph-dashboard-password", false, "optional, docs/services.md, Ceph dashboard"},
	{"vault-init-json", false, "scripts/vault-init.sh, once"},
	{"backup-age-recipient", false, "scripts/backup-key-init.sh, once"},
	{"backup-age-identity", false, "scripts/backup-key-init.sh, once"},
}

var versionRe = regexp.MustCompile(`(\d+)\.(\d+)(?:\.(\d+))?`)

// versionAtLeast compares dotted versions. Missing parts count as 0.
func versionAtLeast(have, min string) bool {
	parse := func(s string) [3]int {
		var v [3]int
		m := versionRe.FindStringSubmatch(s)
		for i := 0; m != nil && i < 3; i++ {
			v[i], _ = strconv.Atoi(m[i+1])
		}
		return v
	}
	h, m := parse(have), parse(min)
	for i := range h {
		if h[i] != m[i] {
			return h[i] > m[i]
		}
	}
	return true
}

func toolFindings(a *app.App) []finding {
	var out []finding
	for _, t := range tools {
		f := finding{group: "tools", upNeeds: true, fix: t.fix}
		if !a.LookPath(t.name) {
			f.lv, f.text = lvFail, t.name+" is missing"
			out = append(out, f)
			continue
		}
		f.text = t.name
		if t.args != nil {
			text, _ := a.Probe(t.name, t.args...)
			v := versionRe.FindString(text)
			if v != "" {
				f.text += " " + v
			}
			if t.min != "" {
				f.text += " (needs " + t.min + " or newer)"
				if v == "" || !versionAtLeast(v, t.min) {
					f.lv = lvFail
				}
			}
		}
		out = append(out, f)
	}
	return append(out, hvacFinding(a))
}

// hvacFinding does what the Makefile's HVAC_CHECK does.
func hvacFinding(a *app.App) finding {
	f := finding{group: "tools", text: "hvac in the Python that runs Ansible", upNeeds: true}
	text, code := a.Probe("ansible-playbook", "--version")
	py := "python3"
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, "python version =") {
			if i := strings.LastIndex(line, "("); i >= 0 && strings.HasSuffix(strings.TrimSpace(line), ")") {
				py = strings.TrimSuffix(strings.TrimSpace(line[i+1:]), ")")
			}
		}
	}
	if code != 0 {
		f.lv, f.fix = lvFail, "install ansible first"
		return f
	}
	if _, c := a.Probe(py, "-c", "import hvac"); c != 0 {
		f.lv, f.fix = lvFail, fmt.Sprintf("%q -m pip install hvac", py)
	}
	return f
}

func fileFindings(a *app.App) []finding {
	home := a.Getenv("HOME")
	key := filepath.Join(home, ".ssh", "id_ed25519")
	var out []finding
	f := finding{group: "files", text: "SSH key ~/.ssh/id_ed25519", upNeeds: true}
	for _, p := range []string{key, key + ".pub"} {
		if _, err := os.Stat(p); err != nil {
			f.lv, f.fix = lvFail, "ssh-keygen -t ed25519"
		}
	}
	out = append(out, f)
	ca := a.Getenv("HOMELAB_VAULT_CACERT")
	if ca == "" {
		ca = filepath.Join(home, ".config", "homelab", "vault-ca.pem")
	}
	f = finding{group: "files", text: "Vault CA certificate"}
	if fi, err := os.Stat(ca); err != nil || fi.Size() == 0 {
		f.lv, f.fix = lvWarn, "make vault copies it there"
	}
	return append(out, f)
}

func keychainFindings(a *app.App) []finding {
	var out []finding
	hasSecurity := a.LookPath("security")
	for _, k := range keychainItems {
		f := finding{group: "keychain", text: k.name, fix: k.fix, upNeeds: k.required}
		present := false
		if hasSecurity {
			// Without -w, security reads the item's attributes, not its value. The output
			// is dropped anyway: only the exit code counts.
			_, code := a.Probe("security", "find-generic-password", "-s", "homelab", "-a", k.name)
			present = code == 0
		}
		switch {
		case present:
		case k.required:
			f.lv, f.text = lvFail, k.name+" is missing"
		default:
			f.lv, f.text = lvWarn, k.name+" is missing"
		}
		out = append(out, f)
	}
	return out
}

type vaultState struct {
	// env is false when scripts/env.sh failed (no Keychain pve-ip).
	env         bool
	reachable   bool
	initialized bool
	sealed      bool
}

func (v vaultState) String() string {
	switch {
	case !v.env:
		return "unknown, scripts/env.sh failed"
	case !v.reachable:
		return "unreachable"
	case !v.initialized:
		return "not initialized"
	case v.sealed:
		return "sealed"
	}
	return "unsealed"
}

const vaultStatusScript = `source scripts/env.sh >/dev/null 2>&1 || exit 90
VAULT_CLIENT_TIMEOUT=5 VAULT_MAX_RETRIES=0 vault status -format=json 2>/dev/null`

// parseVaultStatus reads vault status -format=json and its exit code (0 unsealed,
// 2 sealed, 1 error).
func parseVaultStatus(out string, code int) vaultState {
	if code == 90 {
		return vaultState{}
	}
	v := vaultState{env: true}
	var s struct {
		Initialized bool `json:"initialized"`
		Sealed      bool `json:"sealed"`
	}
	if (code == 0 || code == 2) && json.Unmarshal([]byte(out), &s) == nil {
		v.reachable, v.initialized, v.sealed = true, s.Initialized, s.Sealed
	}
	return v
}

func vaultFinding(v vaultState) finding {
	f := finding{group: "vault", text: "Vault " + v.String()}
	switch {
	case !v.env:
		f.lv, f.fix = lvFail, "add the Keychain item pve-ip"
	case !v.reachable:
		f.lv, f.fix = lvFail, "anvil doctor --fix if the network line below fails, else check the Mac's route to the enclave (docs/setup.md) or set HOMELAB_VAULT_ADDR"
	case !v.initialized:
		f.lv, f.fix = lvFail, "make vault, then scripts/vault-init.sh once (or anvil up)"
	case v.sealed:
		f.lv, f.fix = lvFail, "make vault-unseal"
	}
	return f
}

func initFindings(a *app.App, r *run.Runner) []finding {
	var all []finding
	all = append(all, toolFindings(a)...)
	all = append(all, fileFindings(a)...)
	all = append(all, keychainFindings(a)...)
	all = append(all, vaultFinding(parseVaultStatus(r.Quiet(vaultStatusScript))))
	all = append(all, versionFinding(a, r.Root))
	return append(all, networkFinding()...)
}

// versionFinding compares this binary with the repo it runs. A mismatch is a warning: an
// older binary may not know a newer repo's stages, and the other way round.
func versionFinding(a *app.App, root string) finding {
	f := finding{group: "version", lv: lvWarn}
	fix := "git -C " + run.ShellQuote(repo.TildePath(a.Getenv, root)) + " checkout " + repo.WantRef()
	if root == repo.DataRepo(a.Getenv) {
		fix = "anvil update"
	}
	head, code := repo.Git(a, root, false, "rev-parse", "HEAD")
	switch {
	case code != 0:
		f.text = "the repo is not a git checkout, so its version is unknown"
		f.fix = ""
	case repo.IsRelease():
		tags, _ := repo.Git(a, root, false, "tag", "--points-at", "HEAD")
		desc, _ := repo.Git(a, root, false, "describe", "--tags", "--always")
		if slices.Contains(strings.Fields(tags), "v"+app.Version) {
			f.lv, f.text = lvOK, "anvil "+app.Version+" matches the repo (v"+app.Version+")"
		} else {
			f.text, f.fix = "anvil is "+app.Version+", the repo is at "+desc, fix
		}
	case app.Commit == "":
		f.lv, f.text = lvOK, "anvil "+app.Version+", a build without a commit, not compared"
	case strings.HasPrefix(head, app.Commit) || strings.HasPrefix(app.Commit, head):
		f.lv, f.text = lvOK, "anvil "+app.Version+" was built from the repo's commit"
	default:
		f.text = fmt.Sprintf("anvil was built from %.7s, the repo is at %.7s", app.Commit, head)
		f.fix = "make cli rebuilds it from this checkout"
	}
	return f
}

// paintLevel paints s in the color of lv.
func paintLevel(p app.Palette, lv level, s string) string {
	switch lv {
	case lvWarn:
		return p.Warn(s)
	case lvFail:
		return p.Fail(s)
	}
	return p.Ok(s)
}

func printFindings(w io.Writer, p app.Palette, all []finding) {
	group := ""
	for _, f := range all {
		if f.group != group {
			group = f.group
			fmt.Fprintln(w, group)
		}
		mark := map[level]string{lvOK: "ok  ", lvWarn: "warn", lvFail: "FAIL"}[f.lv]
		line := fmt.Sprintf("  %s  %s", paintLevel(p, f.lv, mark), f.text)
		if f.lv != lvOK && f.fix != "" {
			line += ". Fix: " + f.fix
		}
		fmt.Fprintln(w, line)
	}
}

func cmdInit(a *app.App, args []string) int {
	name := "init"
	if a.Cmd != "" {
		name = a.Cmd
	}
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	usage := initUsage
	var fix bool
	if name == "doctor" {
		usage = doctorUsage
		fs.BoolVar(&fix, "fix", false, "")
	}
	if _, code, ok := a.Flags(fs, usage, args); !ok {
		return code
	}
	if fix {
		fixNetwork(a)
		fmt.Fprintln(a.Stdout)
	}
	r, ok := repo.Runner(a, false)
	if !ok {
		return 1
	}
	all := initFindings(a, r)
	p := a.Pal()
	printFindings(a.Stdout, p, all)
	for _, f := range all {
		if f.lv == lvFail {
			fmt.Fprintln(a.Stdout, p.Fail(name+": not ready, fix the FAIL lines above"))
			return 1
		}
	}
	fmt.Fprintln(a.Stdout, p.Ok(name+": ready"))
	return 0
}
