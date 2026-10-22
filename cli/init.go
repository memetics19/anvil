package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	initUsage   = "usage: anvil init\n       anvil doctor\n" + checksUsage
	doctorUsage = "usage: anvil doctor\n       anvil init\n" + checksUsage
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

Each problem comes with its fix. Exit 1 when something is missing.
`

func init() {
	register(command{"init", "check the tools, the Keychain items and Vault (read-only)", initUsage, cmdInit, 10})
	register(command{"doctor", "the same checks as init, by its future name", doctorUsage, cmdInit, 10})
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

// probe runs a program with a timeout. Its output is returned, never printed.
func (a *app) probe(name string, args ...string) (string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if p := a.which(name); p != "" {
		name = p
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = a.env
	out, err := cmd.CombinedOutput()
	return string(out), exitCode(err)
}

// which finds a program on the PATH the children get, or returns "".
func (a *app) which(name string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, dir := range filepath.SplitList(a.getenv("PATH")) {
		p := filepath.Join(dir, name)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

func (a *app) lookPath(name string) bool { return a.which(name) != "" }

func (a *app) toolFindings() []finding {
	var out []finding
	for _, t := range tools {
		f := finding{group: "tools", upNeeds: true, fix: t.fix}
		if !a.lookPath(t.name) {
			f.lv, f.text = lvFail, t.name+" is missing"
			out = append(out, f)
			continue
		}
		f.text = t.name
		if t.args != nil {
			text, _ := a.probe(t.name, t.args...)
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
	return append(out, a.hvacFinding())
}

// hvacFinding does what the Makefile's HVAC_CHECK does.
func (a *app) hvacFinding() finding {
	f := finding{group: "tools", text: "hvac in the Python that runs Ansible", upNeeds: true}
	text, code := a.probe("ansible-playbook", "--version")
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
	if _, c := a.probe(py, "-c", "import hvac"); c != 0 {
		f.lv, f.fix = lvFail, fmt.Sprintf("%q -m pip install hvac", py)
	}
	return f
}

func (a *app) fileFindings() []finding {
	home := a.getenv("HOME")
	key := filepath.Join(home, ".ssh", "id_ed25519")
	var out []finding
	f := finding{group: "files", text: "SSH key ~/.ssh/id_ed25519", upNeeds: true}
	for _, p := range []string{key, key + ".pub"} {
		if _, err := os.Stat(p); err != nil {
			f.lv, f.fix = lvFail, "ssh-keygen -t ed25519"
		}
	}
	out = append(out, f)
	ca := a.getenv("HOMELAB_VAULT_CACERT")
	if ca == "" {
		ca = filepath.Join(home, ".config", "homelab", "vault-ca.pem")
	}
	f = finding{group: "files", text: "Vault CA certificate"}
	if fi, err := os.Stat(ca); err != nil || fi.Size() == 0 {
		f.lv, f.fix = lvWarn, "make vault copies it there"
	}
	return append(out, f)
}

func (a *app) keychainFindings() []finding {
	var out []finding
	hasSecurity := a.lookPath("security")
	for _, k := range keychainItems {
		f := finding{group: "keychain", text: k.name, fix: k.fix, upNeeds: k.required}
		present := false
		if hasSecurity {
			// Without -w, security reads the item's attributes, not its value. The output
			// is dropped anyway: only the exit code counts.
			_, code := a.probe("security", "find-generic-password", "-s", "homelab", "-a", k.name)
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
		f.lv, f.fix = lvFail, "check the Mac's route to the enclave (docs/setup.md), or set HOMELAB_VAULT_ADDR"
	case !v.initialized:
		f.lv, f.fix = lvFail, "make vault, then scripts/vault-init.sh once (or anvil up)"
	case v.sealed:
		f.lv, f.fix = lvFail, "make vault-unseal"
	}
	return f
}

func (a *app) initFindings(r *runner) []finding {
	var all []finding
	all = append(all, a.toolFindings()...)
	all = append(all, a.fileFindings()...)
	all = append(all, a.keychainFindings()...)
	all = append(all, vaultFinding(parseVaultStatus(r.quiet(vaultStatusScript))))
	return append(all, a.versionFinding(r.root))
}

// versionFinding compares this binary with the repo it runs. A mismatch is a warning: an
// older binary may not know a newer repo's stages, and the other way round.
func (a *app) versionFinding(root string) finding {
	f := finding{group: "version", lv: lvWarn}
	fix := "git -C " + shellQuote(tildePath(a.getenv, root)) + " checkout " + wantRef()
	if root == dataRepo(a.getenv) {
		fix = "anvil update"
	}
	head, code := a.git(root, false, "rev-parse", "HEAD")
	switch {
	case code != 0:
		f.text = "the repo is not a git checkout, so its version is unknown"
		f.fix = ""
	case isRelease():
		tags, _ := a.git(root, false, "tag", "--points-at", "HEAD")
		desc, _ := a.git(root, false, "describe", "--tags", "--always")
		if contains(strings.Fields(tags), "v"+version) {
			f.lv, f.text = lvOK, "anvil "+version+" matches the repo (v"+version+")"
		} else {
			f.text, f.fix = "anvil is "+version+", the repo is at "+desc, fix
		}
	case commit == "":
		f.lv, f.text = lvOK, "anvil "+version+", a build without a commit, not compared"
	case strings.HasPrefix(head, commit) || strings.HasPrefix(commit, head):
		f.lv, f.text = lvOK, "anvil "+version+" was built from the repo's commit"
	default:
		f.text = fmt.Sprintf("anvil was built from %.7s, the repo is at %.7s", commit, head)
		f.fix = "make cli rebuilds it from this checkout"
	}
	return f
}

func printFindings(w io.Writer, p palette, all []finding) {
	group := ""
	for _, f := range all {
		if f.group != group {
			group = f.group
			fmt.Fprintln(w, group)
		}
		mark := map[level]string{lvOK: "ok  ", lvWarn: "warn", lvFail: "FAIL"}[f.lv]
		line := fmt.Sprintf("  %s  %s", p.level(f.lv, mark), f.text)
		if f.lv != lvOK && f.fix != "" {
			line += ". Fix: " + f.fix
		}
		fmt.Fprintln(w, line)
	}
}

func cmdInit(a *app, args []string) int {
	name := "init"
	if a.cmd != "" {
		name = a.cmd
	}
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	usage := initUsage
	if name == "doctor" {
		usage = doctorUsage
	}
	if _, code, ok := a.flags(fs, usage, args); !ok {
		return code
	}
	r, ok := a.runner(false)
	if !ok {
		return 1
	}
	all := a.initFindings(r)
	p := a.pal()
	printFindings(a.stdout, p, all)
	for _, f := range all {
		if f.lv == lvFail {
			fmt.Fprintln(a.stdout, p.fail(name+": not ready, fix the FAIL lines above"))
			return 1
		}
	}
	fmt.Fprintln(a.stdout, p.ok(name+": ready"))
	return 0
}
