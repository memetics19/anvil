package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
)

// envPrefix loads the Keychain values the way the docs do it by hand.
const envPrefix = "source scripts/env.sh && "

// makeCmd is one make invocation. Empty variables are left out.
type makeCmd struct {
	target string
	vars   [][2]string
}

func newMake(target string, kv ...string) makeCmd {
	m := makeCmd{target: target}
	for i := 0; i+1 < len(kv); i += 2 {
		m.vars = append(m.vars, [2]string{kv[i], kv[i+1]})
	}
	return m
}

// String is the command line, quoted for bash. It is exactly what runs.
func (m makeCmd) String() string {
	parts := []string{"make", shellQuote(m.target)}
	for _, kv := range m.vars {
		if kv[1] != "" {
			parts = append(parts, kv[0]+"="+shellQuote(kv[1]))
		}
	}
	return strings.Join(parts, " ")
}

var shellSafe = regexp.MustCompile(`^[A-Za-z0-9_@%+=:,./-]+$`)

func shellQuote(s string) string {
	if shellSafe.MatchString(s) {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// runner runs commands in the repo root through bash.
type runner struct {
	root           string
	stdout, stderr io.Writer
	dryRun         bool
	// env for the child. nil inherits anvil's environment. It is never printed.
	env []string
}

// make runs one make command after sourcing scripts/env.sh. With capture set, the output
// is also copied there, so the caller can read the summary. It returns make's exit code.
func (r *runner) make(m makeCmd, capture *bytes.Buffer) int {
	return r.shell(envPrefix+m.String(), capture)
}

// shell runs a bash script in the repo root, its output on the terminal. In a dry run it
// only prints the script.
func (r *runner) shell(script string, capture *bytes.Buffer) int {
	if r.dryRun {
		fmt.Fprintln(r.stdout, script)
		return 0
	}
	fmt.Fprintf(r.stderr, "==> %s\n", script)
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = r.root
	cmd.Env = r.env
	cmd.Stdout, cmd.Stderr = r.stdout, r.stderr
	if capture != nil {
		cmd.Stdout = io.MultiWriter(r.stdout, capture)
		cmd.Stderr = io.MultiWriter(r.stderr, capture)
	}
	childRunning.Store(true)
	defer childRunning.Store(false)
	return exitCode(cmd.Run())
}

// quiet runs a bash script for its output only: stdout is returned, stderr dropped. It is
// for read-only probes, and it runs in a dry run too only when the caller allows it.
func (r *runner) quiet(script string) (string, int) {
	var out bytes.Buffer
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = r.root
	cmd.Env = r.env
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), exitCode(err)
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	}
	return 127
}
