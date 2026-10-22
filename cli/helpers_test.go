package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// realRoot is the repo this package lives in. Catalog tests read its real playbooks.
const realRoot = ".."

// Sentinel values: they must never show up in anvil's output.
const (
	sentinelEnv    = "sentinel-env-value-4f1c"
	sentinelSource = "sentinel-sourced-value-9b2e"
)

// fakeMake is make for the tests. It logs its arguments, prints $FAKE_CHECK_OUT for a
// check run and exits with $FAKE_RC (or $FAKE_APPLY_RC for a real run).
const fakeMake = `#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *--check*|tf-plan*|switch)
    [ -n "${FAKE_CHECK_OUT:-}" ] && cat "$FAKE_CHECK_OUT"
    exit "${FAKE_RC:-0}" ;;
esac
exit "${FAKE_APPLY_RC:-${FAKE_RC:-0}}"
`

type testLab struct {
	t        *testing.T
	root     string
	bin      string
	log      string
	checkOut string
	env      map[string]string
	out, err bytes.Buffer
}

// newTestLab makes a repo with the real playbook and inventory, a scripts/env.sh that
// exports a sentinel, and a fake make on PATH.
func newTestLab(t *testing.T) *testLab {
	t.Helper()
	dir := t.TempDir()
	l := &testLab{t: t, root: filepath.Join(dir, "repo"), bin: filepath.Join(dir, "bin"),
		log: filepath.Join(dir, "make.log"), checkOut: filepath.Join(dir, "check.out")}
	l.write("Makefile", "")
	l.write("scripts/env.sh", "export PVE_IP="+sentinelSource+"\n")
	for _, p := range []string{playbookPath, inventoryPath} {
		b, err := os.ReadFile(filepath.Join(realRoot, p))
		if err != nil {
			t.Fatal(err)
		}
		l.write(p, string(b))
	}
	if err := os.MkdirAll(l.bin, 0o755); err != nil {
		t.Fatal(err)
	}
	l.tool("make", fakeMake)
	l.env = map[string]string{
		"PATH":                    l.bin + ":" + os.Getenv("PATH"),
		"HOME":                    dir,
		"FAKE_LOG":                l.log,
		"FAKE_CHECK_OUT":          l.checkOut,
		"VAULT_TOKEN":             sentinelEnv,
		"HOMELAB_SECRET":          sentinelEnv,
		"ANSIBLE_BECOME_PASSWORD": sentinelEnv,
	}
	return l
}

func (l *testLab) write(rel, content string) {
	l.t.Helper()
	p := filepath.Join(l.root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		l.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o755); err != nil {
		l.t.Fatal(err)
	}
}

// tool puts a fake command on PATH.
func (l *testLab) tool(name, script string) {
	l.t.Helper()
	if err := os.WriteFile(filepath.Join(l.bin, name), []byte(script), 0o755); err != nil {
		l.t.Fatal(err)
	}
}

func (l *testLab) setCheckOutput(s string) {
	l.t.Helper()
	if err := os.WriteFile(l.checkOut, []byte(s), 0o644); err != nil {
		l.t.Fatal(err)
	}
}

// run runs anvil with stdin as the user's answers.
func (l *testLab) run(stdin string, args ...string) int {
	l.out.Reset()
	l.err.Reset()
	var env []string
	for k, v := range l.env {
		env = append(env, k+"="+v)
	}
	a := &app{
		stdout: &l.out, stderr: &l.err,
		stdin:  bufio.NewReader(strings.NewReader(stdin)),
		getenv: func(k string) string { return l.env[k] },
		cwd:    l.root,
		env:    env,
	}
	setTestHooks(a)
	return a.run(args)
}

// makeCalls is what fake make was called with, one line per call.
func (l *testLab) makeCalls() []string {
	b, err := os.ReadFile(l.log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		l.t.Fatal(err)
	}
	return strings.Split(strings.TrimRight(string(b), "\n"), "\n")
}

func (l *testLab) resetCalls() {
	_ = os.Remove(l.log)
}

func (l *testLab) output() string { return l.out.String() + l.err.String() }

const recapNoChanges = `PLAY RECAP *********************************************************************
apps                       : ok=42   changed=0    unreachable=0    failed=0    skipped=7    rescued=0    ignored=0
`

const recapChanges = `PLAY RECAP *********************************************************************
apps                       : ok=42   changed=2    unreachable=0    failed=0    skipped=7    rescued=0    ignored=0
`

// setTestHooks replaces the parts of app that reach outside the test lab: anvil up's
// init checks pass, and its status stage prints a marker.
func setTestHooks(a *app) {
	a.preflight = func(*app, *runner) bool { return true }
	a.status = func(a *app, _ *runner) int {
		fmt.Fprintln(a.stdout, "STATUS-RAN")
		return 0
	}
}
