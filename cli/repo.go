package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var errNoRepo = errors.New("not inside the anvil repo")

// isRepoRoot reports whether dir looks like the anvil repo: a Makefile next to
// scripts/env.sh.
func isRepoRoot(dir string) bool {
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
		if !isRepoRoot(dir) {
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
		if isRepoRoot(dir) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errNoRepo
		}
		dir = parent
	}
}

// dataRepo is where anvil fetch keeps its copy of the repo: $XDG_DATA_HOME/anvil/repo, or
// ~/.local/share/anvil/repo. It is in the user's home, not /usr/share, because runs write
// build/ and terraform/.terraform inside the repo.
func dataRepo(getenv func(string) string) string {
	base := getenv("XDG_DATA_HOME")
	if base == "" {
		base = filepath.Join(getenv("HOME"), ".local", "share")
	}
	return filepath.Join(base, "anvil", "repo")
}

// tildePath shows a path under $HOME with ~.
func tildePath(getenv func(string) string, p string) string {
	if home := getenv("HOME"); home != "" && strings.HasPrefix(p, home+string(filepath.Separator)) {
		return "~" + p[len(home):]
	}
	return p
}

// repoRoot finds the repo: ANVIL_REPO, else the current directory upwards, else the copy
// anvil fetch made. Without any, at a terminal it offers to fetch that copy now (what a
// packaged install needs once). Elsewhere the error says how to get one.
func (a *app) repoRoot() (string, error) {
	root, err := findRoot(a.cwd, a.getenv("ANVIL_REPO"))
	if !errors.Is(err, errNoRepo) {
		return root, err
	}
	d := dataRepo(a.getenv)
	if isRepoRoot(d) {
		return d, nil
	}
	if a.tty && !a.fetchOffered {
		a.fetchOffered = true
		fmt.Fprintf(a.stdout, "anvil keeps a copy of its repo (the scripts, Ansible and Terraform it runs) in %s,\n"+
			"and there is none yet.\n", tildePath(a.getenv, d))
		if askYesDefault(a.stdin, a.stdout, "Fetch it now?") && cmdFetch(a, nil) == 0 && isRepoRoot(d) {
			return d, nil
		}
	}
	return "", fmt.Errorf("no anvil repo found: not inside a checkout, ANVIL_REPO is unset, and %s is empty.\n"+
		"Run anvil fetch to clone it there (then anvil doctor), cd into a checkout, or set ANVIL_REPO",
		tildePath(a.getenv, dataRepo(a.getenv)))
}
