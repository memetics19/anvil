package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

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
			return "", errors.New("not inside the anvil repo; cd into it or set ANVIL_REPO")
		}
		dir = parent
	}
}
