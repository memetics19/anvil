package app

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/memetics19/anvil/cli/internal/run"
)

// Probe runs a program with a timeout. Its output is returned, never printed.
func (a *App) Probe(name string, args ...string) (string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if p := a.Which(name); p != "" {
		name = p
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = a.Env
	out, err := cmd.CombinedOutput()
	return string(out), run.ExitCode(err)
}

// Which finds a program on the PATH the children get, or returns "".
func (a *App) Which(name string) string {
	if strings.Contains(name, "/") {
		return name
	}
	for _, dir := range filepath.SplitList(a.Getenv("PATH")) {
		p := filepath.Join(dir, name)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// LookPath reports whether a program is on the PATH the children get.
func (a *App) LookPath(name string) bool { return a.Which(name) != "" }
