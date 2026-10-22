// Command anvil is a thin wrapper over the repo's make targets (docs/cli.md).
//
// Make stays the source of truth: every command runs
//
//	bash -c 'source scripts/env.sh && make <target> HOST=... ARGS=...'
//
// in the repo root, with the caller's environment. anvil never prints a secret, never
// logs the environment, never adds a force flag, and exits with make's exit code.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
)

// version is set at build time (make cli).
var version = "dev"

// childRunning is set while make runs. An interrupt then goes to make (same process
// group), and anvil waits for it and passes on its exit code.
var childRunning atomic.Bool

type app struct {
	stdout, stderr io.Writer
	stdin          *bufio.Reader
	getenv         func(string) string
	cwd            string
	// env is the environment for child processes. nil inherits anvil's own.
	env []string
	// preflight and status are anvil up's first and last steps. nil: the real ones.
	// Tests replace them.
	preflight func(a *app, r *runner) bool
	status    func(a *app, r *runner) int
	// reach checks the lab endpoints a run needs (reach.go). nil: the real one.
	reach func(a *app, r *runner, n needs) bool
	// reached are the endpoints that answered in this run.
	reached map[string]bool
}

// canReach checks the endpoints of one make target before it runs.
func (a *app) canReach(r *runner, makeTarget string) bool {
	if a.reach == nil {
		a.reach = reachable
	}
	return a.reach(a, r, needsOf(makeTarget))
}

type command struct {
	name, summary, usage string
	run                  func(a *app, args []string) int
	// order places the command in the help list.
	order int
}

var commands []command

// register adds a command. Each command's file registers it in its own init.
func register(c command) {
	commands = append(commands, c)
	sort.SliceStable(commands, func(i, j int) bool { return commands[i].order < commands[j].order })
}

func init() {
	register(command{"version", "print the version", "usage: anvil version\n\nPrints the version of this binary.\n", cmdVersion, 90})
	register(command{"help", "help for a command", "usage: anvil help [command]\n", cmdHelp, 91})
}

func main() {
	a := &app{
		stdout: os.Stdout,
		stderr: os.Stderr,
		stdin:  bufio.NewReader(os.Stdin),
		getenv: os.Getenv,
	}
	a.cwd, _ = os.Getwd()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		for range sig {
			if !childRunning.Load() {
				os.Exit(130)
			}
		}
	}()

	os.Exit(a.run(os.Args[1:]))
}

func (a *app) run(args []string) int {
	if len(args) == 0 {
		a.printHelp(a.stderr)
		return 2
	}
	name := args[0]
	switch name {
	case "-h", "--help":
		a.printHelp(a.stdout)
		return 0
	case "-v", "--version":
		name = "version"
	}
	c, ok := findCommand(name)
	if !ok {
		fmt.Fprintf(a.stderr, "anvil: unknown command %q\n\n", name)
		a.printHelp(a.stderr)
		return 2
	}
	return c.run(a, args[1:])
}

func findCommand(name string) (command, bool) {
	for _, c := range commands {
		if c.name == name {
			return c, true
		}
	}
	return command{}, false
}

func (a *app) printHelp(w io.Writer) {
	fmt.Fprint(w, "anvil runs the homelab's make targets (docs/cli.md).\n\nusage: anvil <command> [options]\n\ncommands:\n")
	for _, c := range commands {
		fmt.Fprintf(w, "  %-14s %s\n", c.name, c.summary)
	}
	fmt.Fprint(w, "\nEvery command takes --help. The repo is found from the current directory, or ANVIL_REPO.\n")
}

func cmdVersion(a *app, args []string) int {
	if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
		c, _ := findCommand("version")
		fmt.Fprint(a.stdout, c.usage)
		return 0
	}
	fmt.Fprintf(a.stdout, "anvil %s\n", version)
	return 0
}

func cmdHelp(a *app, args []string) int {
	if len(args) == 0 {
		a.printHelp(a.stdout)
		return 0
	}
	if args[0] == "-h" || args[0] == "--help" {
		args[0] = "help"
	}
	c, ok := findCommand(args[0])
	if !ok {
		fmt.Fprintf(a.stderr, "anvil: unknown command %q\n", args[0])
		return 2
	}
	fmt.Fprint(a.stdout, c.usage)
	return 0
}

// flags parses a command's options. Options may come before or after the positional
// arguments. It returns the positional arguments, or the exit code when the caller
// should stop (help printed, or a usage error).
func (a *app) flags(fs *flag.FlagSet, usage string, args []string) ([]string, int, bool) {
	fs.SetOutput(io.Discard)
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			if errors.Is(err, flag.ErrHelp) {
				fmt.Fprint(a.stdout, usage)
				return nil, 0, false
			}
			fmt.Fprintf(a.stderr, "anvil: %v\n\n%s", err, usage)
			return nil, 2, false
		}
		args = fs.Args()
		if len(args) == 0 {
			return pos, 0, true
		}
		pos = append(pos, args[0])
		args = args[1:]
	}
}

// runner returns a runner for the repo, or prints why there is none.
func (a *app) runner(dryRun bool) (*runner, bool) {
	root, err := findRoot(a.cwd, a.getenv("ANVIL_REPO"))
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: %v\n", err)
		return nil, false
	}
	return &runner{root: root, stdout: a.stdout, stderr: a.stderr, dryRun: dryRun, env: a.env}, true
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func joinNonEmpty(sep string, parts ...string) string {
	var out []string
	for _, p := range parts {
		if strings.TrimSpace(p) != "" {
			out = append(out, strings.TrimSpace(p))
		}
	}
	return strings.Join(out, sep)
}
