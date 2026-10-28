// Package testlab is the test harness of anvil's packages: a throwaway repo with the real
// playbook and inventory, a fake make on PATH, sentinel values that must never show up in
// the output, and fakes of the tools the checks run.
package testlab

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/run"
)

// RealRoot is the repo this module lives in. Catalog tests read its real playbooks.
var RealRoot = findRealRoot()

// findRealRoot walks up from the test's directory to the repo: the directory with a
// Makefile and cli/go.mod.
func findRealRoot() string {
	dir, err := os.Getwd()
	if err != nil {
		return ".."
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "cli", "go.mod")); err == nil {
			if _, err := os.Stat(filepath.Join(dir, "Makefile")); err == nil {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ".."
		}
		dir = parent
	}
}

// Sentinel values: they must never show up in anvil's output.
const (
	SentinelEnv    = "sentinel-env-value-4f1c"
	SentinelSource = "sentinel-sourced-value-9b2e"
)

// TFState marks a checkout whose Terraform is set up.
const TFState = "terraform/.terraform/terraform.tfstate"

// The files of the real repo that New copies.
const (
	playbookPath  = "ansible/playbooks/vms.yml"
	inventoryPath = "ansible/inventory/hosts.yml"
)

// FakeMake is make for the tests. It logs its arguments, prints $FAKE_CHECK_OUT for a
// check run and exits with $FAKE_RC (or $FAKE_APPLY_RC for a real run).
const FakeMake = `#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *--check*|tf-plan*|switch)
    [ -n "${FAKE_CHECK_OUT:-}" ] && cat "$FAKE_CHECK_OUT"
    exit "${FAKE_RC:-0}" ;;
esac
exit "${FAKE_APPLY_RC:-${FAKE_RC:-0}}"
`

// Lab is a repo for one test, and anvil as the next run in it sees it.
type Lab struct {
	T        *testing.T
	Root     string
	Bin      string
	Log      string
	CheckOut string
	Env      map[string]string
	// RealReach keeps the real endpoint checks (reach_test.go).
	RealReach bool
	// TTY makes anvil believe stdout is a terminal (color_test.go).
	TTY bool
	// Dir is where anvil runs. Empty: the repo root.
	Dir      string
	Out, Err bytes.Buffer
}

// New makes a repo with the real playbook and inventory, a scripts/env.sh that exports a
// sentinel, and a fake make on PATH.
func New(t *testing.T) *Lab {
	t.Helper()
	dir := t.TempDir()
	l := &Lab{T: t, Root: filepath.Join(dir, "repo"), Bin: filepath.Join(dir, "bin"),
		Log: filepath.Join(dir, "make.log"), CheckOut: filepath.Join(dir, "check.out")}
	l.Write("Makefile", "")
	l.Write("scripts/env.sh", "export PVE_IP="+SentinelSource+"\n")
	// An initialised checkout, so commands do not run tf-init first (TestPrepareTerraform).
	l.Write(TFState, "{}")
	for _, p := range []string{playbookPath, inventoryPath, "scripts/install-collections.sh", "ansible/requirements.yml"} {
		b, err := os.ReadFile(filepath.Join(RealRoot, p))
		if err != nil {
			t.Fatal(err)
		}
		l.Write(p, string(b))
	}
	if err := os.MkdirAll(l.Bin, 0o755); err != nil {
		t.Fatal(err)
	}
	l.Tool("make", FakeMake)
	l.Env = map[string]string{
		"PATH":                    l.Bin + ":" + os.Getenv("PATH"),
		"HOME":                    dir,
		"FAKE_LOG":                l.Log,
		"FAKE_CHECK_OUT":          l.CheckOut,
		"VAULT_TOKEN":             SentinelEnv,
		"HOMELAB_SECRET":          SentinelEnv,
		"ANSIBLE_BECOME_PASSWORD": SentinelEnv,
	}
	return l
}

// Write writes a file in the repo.
func (l *Lab) Write(rel, content string) {
	l.T.Helper()
	p := filepath.Join(l.Root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		l.T.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o755); err != nil {
		l.T.Fatal(err)
	}
}

// Tool puts a fake command on PATH.
func (l *Lab) Tool(name, script string) {
	l.T.Helper()
	if err := os.WriteFile(filepath.Join(l.Bin, name), []byte(script), 0o755); err != nil {
		l.T.Fatal(err)
	}
}

// SetCheckOutput is what fake make prints for a check run.
func (l *Lab) SetCheckOutput(s string) {
	l.T.Helper()
	if err := os.WriteFile(l.CheckOut, []byte(s), 0o644); err != nil {
		l.T.Fatal(err)
	}
}

// App is anvil as the next run sees it.
func (l *Lab) App() *app.App {
	var env []string
	for k, v := range l.Env {
		env = append(env, k+"="+v)
	}
	cwd := l.Dir
	if cwd == "" {
		cwd = l.Root
	}
	return &app.App{
		Stdout: &l.Out, Stderr: &l.Err,
		Getenv: func(k string) string { return l.Env[k] },
		Cwd:    cwd,
		Env:    env,
		TTY:    l.TTY,
	}
}

// Cwd makes the next runs start in dir.
func (l *Lab) Cwd(dir string) { l.Dir = dir }

// Run runs anvil with stdin as the user's answers.
func (l *Lab) Run(stdin string, args ...string) int {
	l.Out.Reset()
	l.Err.Reset()
	a := l.App()
	a.Stdin = bufio.NewReader(strings.NewReader(stdin))
	setTestHooks(a)
	if l.RealReach {
		a.Reach = nil
	}
	return a.Run(args)
}

// MakeCalls is what fake make was called with, one line per call.
func (l *Lab) MakeCalls() []string {
	b, err := os.ReadFile(l.Log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		l.T.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(b), "\n"), "\n")
}

// ResetCalls forgets the make calls so far.
func (l *Lab) ResetCalls() {
	_ = os.Remove(l.Log)
}

// Output is stdout and stderr of the last run.
func (l *Lab) Output() string { return l.Out.String() + l.Err.String() }

// RecapNoChanges and RecapChanges are Ansible's PLAY RECAP without and with changes.
const RecapNoChanges = `PLAY RECAP *********************************************************************
apps                       : ok=42   changed=0    unreachable=0    failed=0    skipped=7    rescued=0    ignored=0
`

const RecapChanges = `PLAY RECAP *********************************************************************
apps                       : ok=42   changed=2    unreachable=0    failed=0    skipped=7    rescued=0    ignored=0
`

// setTestHooks replaces the parts of app that reach outside the test lab: anvil up's
// init checks pass, every lab endpoint answers, and its status stage prints a marker.
func setTestHooks(a *app.App) {
	a.Reach = func(*app.App, *run.Runner, string) bool { return true }
	a.Preflight = func(*app.App, *run.Runner) bool { return true }
	a.Status = func(a *app.App, _ *run.Runner) int {
		fmt.Fprintln(a.Stdout, "STATUS-RAN")
		return 0
	}
}

// SetVersion sets the binary's version for one test.
func SetVersion(t *testing.T, v string) {
	old := app.Version
	app.Version = v
	t.Cleanup(func() { app.Version = old })
}
