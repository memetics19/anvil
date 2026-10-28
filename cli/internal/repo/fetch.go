package repo

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/run"
)

// repoURL is where anvil fetch clones from. ANVIL_REPO_URL overrides it, for a fork.
const repoURL = "https://github.com/memetics19/anvil"

const fetchUsage = `usage: anvil fetch

Clones the anvil repo into ~/.local/share/anvil/repo ($XDG_DATA_HOME/anvil/repo when
set), for an anvil installed from a package. A release binary checks out its own
version's tag (v0.1.0 for anvil 0.1.0). A dev build checks out main.

anvil finds the repo in the current directory first, then ANVIL_REPO, then this copy.
It never touches a checkout of yours. The copy is in your home because runs write
build/ and terraform/.terraform inside the repo.

ANVIL_REPO_URL clones from another URL, for a fork.
`

const updateUsage = `usage: anvil update

Updates the copy anvil fetch made to this binary's version: the tag for a release,
the newest main for a dev build. It refuses when the copy has local changes. Your own
checkouts are never touched: update them with git.
`

func init() {
	app.Register(app.Command{Name: "fetch", Summary: "clone the repo for a packaged install (~/.local/share/anvil/repo)", Usage: fetchUsage, Run: cmdFetch, Order: 60})
	app.Register(app.Command{Name: "update", Summary: "update the fetched repo to this binary's version", Usage: updateUsage, Run: cmdUpdate, Order: 61})
}

var releaseRe = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// IsRelease: this binary is a release, so its repo is the tag v<version>.
func IsRelease() bool { return releaseRe.MatchString(app.Version) }

// WantRef is the ref this binary wants: v<version> for a release, else main.
func WantRef() string {
	if IsRelease() {
		return "v" + app.Version
	}
	return "main"
}

// Git runs git in dir. Quiet captures stdout and drops stderr. Loud passes both on.
func Git(a *app.App, dir string, loud bool, args ...string) (string, int) {
	name := "git"
	if p := a.Which(name); p != "" {
		name = p
	}
	cmd := exec.Command(name, args...)
	cmd.Dir, cmd.Env = dir, a.Env
	var out bytes.Buffer
	cmd.Stdout = &out
	if loud {
		cmd.Stdout, cmd.Stderr = a.Stdout, a.Stderr
	}
	err := cmd.Run()
	return strings.TrimSpace(out.String()), run.ExitCode(err)
}

func cloneURL(a *app.App) string {
	if u := a.Getenv("ANVIL_REPO_URL"); u != "" {
		return u
	}
	return repoURL
}

func cmdFetch(a *app.App, args []string) int {
	fs := flag.NewFlagSet("fetch", flag.ContinueOnError)
	pos, code, ok := a.Flags(fs, fetchUsage, args)
	if !ok {
		return code
	}
	if len(pos) > 0 {
		fmt.Fprint(a.Stderr, fetchUsage)
		return 2
	}
	dir := DataRepo(a.Getenv)
	shown := TildePath(a.Getenv, dir)
	if entries, err := os.ReadDir(dir); err == nil && len(entries) > 0 {
		if _, c := Git(a, dir, false, "rev-parse", "--show-toplevel"); c == 0 && IsRoot(dir) {
			fmt.Fprintf(a.Stdout, "anvil fetch: %s is already there. anvil update moves it to this version.\n", shown)
			return 0
		}
		fmt.Fprintf(a.Stderr, "anvil fetch: %s is not empty and not an anvil checkout. Move it away first.\n", shown)
		return 1
	}
	ref := WantRef()
	fmt.Fprintf(a.Stdout, "anvil fetch: cloning %s at %s into %s\n", cloneURL(a), ref, shown)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(a.Stderr, "anvil fetch: %v\n", err)
		return 1
	}
	if _, c := Git(a, dir, true, "-c", "advice.detachedHead=false", "clone", "--quiet", "--branch", ref, cloneURL(a), "."); c != 0 || !IsRoot(dir) {
		// The directory was empty or missing before: nothing of the user's is removed.
		os.RemoveAll(dir)
		fmt.Fprintf(a.Stderr, "anvil fetch: the clone of %s at %s failed\n", cloneURL(a), ref)
		return 1
	}
	fmt.Fprintf(a.Stdout, "anvil fetch: %s is at %s. Next: anvil doctor\n", shown, ref)
	return 0
}

func cmdUpdate(a *app.App, args []string) int {
	fs := flag.NewFlagSet("update", flag.ContinueOnError)
	pos, code, ok := a.Flags(fs, updateUsage, args)
	if !ok {
		return code
	}
	if len(pos) > 0 {
		fmt.Fprint(a.Stderr, updateUsage)
		return 2
	}
	dir := DataRepo(a.Getenv)
	shown := TildePath(a.Getenv, dir)
	if !IsRoot(dir) {
		fmt.Fprintf(a.Stderr, "anvil update: %s has no fetched repo. Run anvil fetch first.\n", shown)
		return 1
	}
	if out, c := Git(a, dir, false, "status", "--porcelain", "--untracked-files=no"); c != 0 || out != "" {
		fmt.Fprintf(a.Stderr, "anvil update: %s has local changes (git status). Commit or discard them first.\n", shown)
		return 1
	}
	ref := WantRef()
	steps := [][]string{{"fetch", "--quiet", "--tags", "--force", "origin"}, {"checkout", "--quiet", ref}}
	if !IsRelease() {
		steps = append(steps, []string{"merge", "--quiet", "--ff-only", "origin/main"})
	}
	for _, s := range steps {
		if _, c := Git(a, dir, true, s...); c != 0 {
			fmt.Fprintf(a.Stderr, "anvil update: git %s failed (exit %d)\n", strings.Join(s, " "), c)
			return c
		}
	}
	head, _ := Git(a, dir, false, "rev-parse", "--short", "HEAD")
	fmt.Fprintf(a.Stdout, "anvil update: %s is at %s (%s)\n", shown, ref, head)
	return 0
}
