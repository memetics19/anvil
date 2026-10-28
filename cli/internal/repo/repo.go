// Package repo finds the anvil repo the commands run in, and fetches and updates the copy a
// packaged install keeps (anvil fetch, anvil update).
package repo

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/run"
)

var errNoRepo = errors.New("not inside the anvil repo")

// IsRoot reports whether dir looks like the anvil repo: a Makefile next to
// scripts/env.sh.
func IsRoot(dir string) bool {
	for _, p := range []string{"Makefile", filepath.Join("scripts", "env.sh")} {
		if fi, err := os.Stat(filepath.Join(dir, p)); err != nil || fi.IsDir() {
			return false
		}
	}
	return true
}

// findRoot returns the repo root: ANVIL_REPO when set, else the first directory from
// start upwards that holds the repo.
func findRoot(start, override string) (string, error) {
	if override != "" {
		dir, err := filepath.Abs(override)
		if err != nil {
			return "", err
		}
		if !IsRoot(dir) {
			return "", fmt.Errorf("ANVIL_REPO=%s is not the anvil repo (no Makefile and scripts/env.sh)", override)
		}
		return dir, nil
	}
	if start == "" {
		return "", errors.New("no current directory")
	}
	dir, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		if IsRoot(dir) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errNoRepo
		}
		dir = parent
	}
}

// DataRepo is where anvil fetch keeps its copy of the repo: $XDG_DATA_HOME/anvil/repo, or
// ~/.local/share/anvil/repo. It is in the user's home, not /usr/share, because runs write
// build/ and terraform/.terraform inside the repo.
func DataRepo(getenv func(string) string) string {
	base := getenv("XDG_DATA_HOME")
	if base == "" {
		base = filepath.Join(getenv("HOME"), ".local", "share")
	}
	return filepath.Join(base, "anvil", "repo")
}

// TildePath shows a path under $HOME with ~.
func TildePath(getenv func(string) string, p string) string {
	if home := getenv("HOME"); home != "" && strings.HasPrefix(p, home+string(filepath.Separator)) {
		return "~" + p[len(home):]
	}
	return p
}

// Root finds the repo: ANVIL_REPO, else the current directory upwards, else the copy
// anvil fetch made. Without any, at a terminal it offers to fetch that copy now (what a
// packaged install needs once). Elsewhere the error says how to get one.
func Root(a *app.App) (string, error) {
	root, err := findRoot(a.Cwd, a.Getenv("ANVIL_REPO"))
	if !errors.Is(err, errNoRepo) {
		return root, err
	}
	d := DataRepo(a.Getenv)
	if IsRoot(d) {
		return d, nil
	}
	if a.TTY && !a.FetchOffered {
		a.FetchOffered = true
		fmt.Fprintf(a.Stdout, "anvil keeps a copy of its repo (the scripts, Ansible and Terraform it runs) in %s,\n"+
			"and there is none yet.\n", TildePath(a.Getenv, d))
		if app.AskYesDefault(a.Stdin, a.Stdout, "Fetch it now?") && cmdFetch(a, nil) == 0 && IsRoot(d) {
			return d, nil
		}
	}
	return "", fmt.Errorf("no anvil repo found: not inside a checkout, ANVIL_REPO is unset, and %s is empty.\n"+
		"Run anvil fetch to clone it there (then anvil doctor), cd into a checkout, or set ANVIL_REPO",
		TildePath(a.Getenv, DataRepo(a.Getenv)))
}

// Runner returns a runner for the repo, or prints why there is none.
func Runner(a *app.App, dryRun bool) (*run.Runner, bool) {
	root, err := Root(a)
	if err != nil {
		fmt.Fprintf(a.Stderr, "anvil: %v\n", err)
		return nil, false
	}
	return &run.Runner{Root: root, Stdout: a.Stdout, Stderr: a.Stderr, DryRun: dryRun, Env: a.Env}, true
}
