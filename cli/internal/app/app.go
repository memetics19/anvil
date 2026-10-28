// Package app is anvil's command line: the commands and their registry, option parsing,
// help and version, colors and the confirmation prompts. The commands themselves live in
// the other internal packages, which register here in their init.
//
// Make stays the source of truth: every command runs
//
//	bash -c 'source scripts/env.sh && make <target> HOST=... ARGS=...'
//
// in the repo root, with the caller's environment. anvil never prints a secret, never
// logs the environment, never adds a force flag, and exits with make's exit code.
package app

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime"
	"sort"
	"strings"
	"syscall"

	"github.com/memetics19/anvil/cli/internal/run"
)

// Version, Commit and Date are the build's. cmd/anvil sets them from its -ldflags -X
// variables (make cli, GoReleaser). Version has no leading v. A release is a plain X.Y.Z.
var (
	Version = "dev"
	Commit  = ""
	Date    = ""
)

// App is one run of anvil.
type App struct {
	Stdout, Stderr io.Writer
	Stdin          *bufio.Reader
	Getenv         func(string) string
	Cwd            string
	// Env is the environment for child processes. nil inherits anvil's own.
	Env []string
	// Cmd is the command being run, as typed (init or doctor).
	Cmd string
	// TTY: stdout is a terminal. NoColor: --no-color was given. See color.go.
	TTY, NoColor bool
	// FetchOffered: the repo lookup asked once to fetch the repo in this run (package repo).
	FetchOffered bool
	// Preflight and Status are anvil up's first and last steps. nil: the real ones.
	// Tests replace them.
	Preflight func(a *App, r *run.Runner) bool
	Status    func(a *App, r *run.Runner) int
	// Reach checks the lab endpoints one make target needs. nil: the real one. Tests
	// replace it.
	Reach func(a *App, r *run.Runner, makeTarget string) bool
	// Reached are the endpoints that answered in this run.
	Reached map[string]bool
}

// Command is one anvil command.
type Command struct {
	Name, Summary, Usage string
	Run                  func(a *App, args []string) int
	// Order places the command in the help list.
	Order int
}

var commands []Command

// Register adds a command. Each command's package registers it in its own init.
func Register(c Command) {
	commands = append(commands, c)
	sort.SliceStable(commands, func(i, j int) bool { return commands[i].Order < commands[j].Order })
}

// Commands lists the registered commands in help order.
func Commands() []Command { return commands }

func init() {
	Register(Command{Name: "version", Summary: "print the version, commit, build date, Go version and platform", Usage: versionUsage, Run: cmdVersion, Order: 90})
	Register(Command{Name: "help", Summary: "help for a command", Usage: "usage: anvil help [command]\n", Run: cmdHelp, Order: 91})
}

// Main runs anvil with args on the terminal and returns the exit code.
func Main(args []string) int {
	a := &App{
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Stdin:  bufio.NewReader(os.Stdin),
		Getenv: os.Getenv,
		TTY:    IsTerminal(os.Stdout),
	}
	a.Cwd, _ = os.Getwd()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		for range sig {
			if !run.ChildRunning.Load() {
				os.Exit(130)
			}
		}
	}()

	return a.Run(args)
}

// Run runs one command line and returns its exit code.
func (a *App) Run(args []string) int {
	args, noColor := stripNoColor(args)
	a.NoColor = a.NoColor || noColor
	if len(args) == 0 {
		a.printHelp(a.Stderr)
		return 2
	}
	name := args[0]
	switch name {
	case "-h", "--help":
		a.printHelp(a.Stdout)
		return 0
	case "-v", "--version":
		name = "version"
	}
	c, ok := FindCommand(name)
	if !ok {
		fmt.Fprintf(a.Stderr, "anvil: unknown command %q\n\n", name)
		a.printHelp(a.Stderr)
		return 2
	}
	a.Cmd = c.Name
	return c.Run(a, args[1:])
}

// FindCommand finds a registered command by name.
func FindCommand(name string) (Command, bool) {
	for _, c := range commands {
		if c.Name == name {
			return c, true
		}
	}
	return Command{}, false
}

func (a *App) printHelp(w io.Writer) {
	fmt.Fprint(w, "anvil runs the homelab's make targets (docs/cli.md).\n\nusage: anvil <command> [options]\n\ncommands:\n")
	for _, c := range commands {
		fmt.Fprintf(w, "  %-14s %s\n", c.Name, c.Summary)
	}
	fmt.Fprint(w, "\nEvery command takes --help, and --no-color (or NO_COLOR) for plain output.\n"+
		"The repo is found from the current directory, or ANVIL_REPO.\n")
}

func cmdVersion(a *App, args []string) int {
	if len(args) > 0 && (args[0] == "-h" || args[0] == "--help") {
		c, _ := FindCommand("version")
		fmt.Fprint(a.Stdout, c.Usage)
		return 0
	}
	fmt.Fprint(a.Stdout, versionText())
	return 0
}

const versionUsage = `usage: anvil version

Prints the version of this binary, the commit and date it was built from, the Go version
and the platform. make cli and the release build set them from git.
`

func versionText() string {
	or := func(s, def string) string {
		if s == "" {
			return def
		}
		return s
	}
	return fmt.Sprintf("anvil %s\n  commit    %s\n  built     %s\n  go        %s\n  platform  %s/%s\n",
		Version, or(Commit, "unknown"), or(Date, "unknown"), runtime.Version(), runtime.GOOS, runtime.GOARCH)
}

func cmdHelp(a *App, args []string) int {
	if len(args) == 0 {
		a.printHelp(a.Stdout)
		return 0
	}
	if args[0] == "-h" || args[0] == "--help" {
		args[0] = "help"
	}
	c, ok := FindCommand(args[0])
	if !ok {
		fmt.Fprintf(a.Stderr, "anvil: unknown command %q\n", args[0])
		return 2
	}
	fmt.Fprint(a.Stdout, c.Usage)
	return 0
}

// Flags parses a command's options. Options may come before or after the positional
// arguments. It returns the positional arguments, or the exit code when the caller
// should stop (help printed, or a usage error).
func (a *App) Flags(fs *flag.FlagSet, usage string, args []string) ([]string, int, bool) {
	fs.SetOutput(io.Discard)
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			if errors.Is(err, flag.ErrHelp) {
				fmt.Fprint(a.Stdout, usage)
				return nil, 0, false
			}
			fmt.Fprintf(a.Stderr, "anvil: %v\n\n%s", err, usage)
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

// InterleaveFlags puts flags (and the value of each flag in valued) before the words, so
// `increase-disk ragnarok 600gb --yes` parses like `increase-disk --yes ragnarok 600gb`.
func InterleaveFlags(args []string, valued ...string) []string {
	var flags, words []string
	for i := 0; i < len(args); i++ {
		s := args[i]
		if !strings.HasPrefix(s, "-") {
			words = append(words, s)
			continue
		}
		flags = append(flags, s)
		for _, v := range valued {
			if s == v && i+1 < len(args) {
				flags = append(flags, args[i+1])
				i++
			}
		}
	}
	return append(flags, words...)
}
