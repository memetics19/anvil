// Package run runs make and bash in the repo root: the make command line, the runner with
// its dry run, and the exit codes it passes on.
package run

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"sync/atomic"
	"syscall"
)

// EnvPrefix loads the Keychain values the way the docs do it by hand.
const EnvPrefix = "source scripts/env.sh && "

// ChildRunning is set while make runs. An interrupt then goes to make (same process
// group), and anvil waits for it and passes on its exit code.
var ChildRunning atomic.Bool

// MakeCmd is one make invocation. Empty variables are left out.
type MakeCmd struct {
	Target string
	vars   [][2]string
}

// NewMake is make target with the variables kv (name, value, name, value, ...).
func NewMake(target string, kv ...string) MakeCmd {
	m := MakeCmd{Target: target}
	for i := 0; i+1 < len(kv); i += 2 {
		m.vars = append(m.vars, [2]string{kv[i], kv[i+1]})
	}
	return m
}

// String is the command line, quoted for bash. It is exactly what runs.
func (m MakeCmd) String() string {
	parts := []string{"make", ShellQuote(m.Target)}
	for _, kv := range m.vars {
		if kv[1] != "" {
			parts = append(parts, kv[0]+"="+ShellQuote(kv[1]))
		}
	}
	return strings.Join(parts, " ")
}

var shellSafe = regexp.MustCompile(`^[A-Za-z0-9_@%+=:,./-]+$`)

// ShellSafe reports whether s needs no quotes in bash.
func ShellSafe(s string) bool { return shellSafe.MatchString(s) }

// ShellQuote quotes s for bash, when it needs it.
func ShellQuote(s string) string {
	if ShellSafe(s) {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// Runner runs commands in the repo root through bash.
type Runner struct {
	Root           string
	Stdout, Stderr io.Writer
	DryRun         bool
	// Env for the child. nil inherits anvil's environment. It is never printed.
	Env []string
}

// Make runs one make command after sourcing scripts/env.sh. With capture set, the output
// is also copied there, so the caller can read the summary. It returns make's exit code.
func (r *Runner) Make(m MakeCmd, capture *bytes.Buffer) int {
	return r.Shell(EnvPrefix+m.String(), capture)
}

// Shell runs a bash script in the repo root, its output on the terminal. In a dry run it
// only prints the script.
func (r *Runner) Shell(script string, capture *bytes.Buffer) int {
	if r.DryRun {
		fmt.Fprintln(r.Stdout, script)
		return 0
	}
	fmt.Fprintf(r.Stderr, "==> %s\n", script)
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = r.Root
	cmd.Env = r.Env
	cmd.Stdout, cmd.Stderr = r.Stdout, r.Stderr
	if capture != nil {
		cmd.Stdout = io.MultiWriter(r.Stdout, capture)
		cmd.Stderr = io.MultiWriter(r.Stderr, capture)
	}
	ChildRunning.Store(true)
	defer ChildRunning.Store(false)
	return ExitCode(cmd.Run())
}

// Quiet runs a bash script for its output only: stdout is returned, stderr dropped. It is
// for read-only probes, and it runs in a dry run too only when the caller allows it.
func (r *Runner) Quiet(script string) (string, int) {
	var out bytes.Buffer
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = r.Root
	cmd.Env = r.Env
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), ExitCode(err)
}

// ExitCode is the exit code of a finished command: 128+N for a signal, 127 when it did
// not start.
func ExitCode(err error) int {
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
