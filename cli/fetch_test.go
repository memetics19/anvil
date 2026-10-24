package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitT runs git for the test, with no user or system config.
func gitT(t *testing.T, home, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"}, args...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "HOME="+home, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// remoteLab is a bare repo standing in for GitHub: main with tag v1.2.3, and one more
// commit on main after it. No network.
type remoteLab struct {
	*testLab
	src, bare, data string
}

func newRemoteLab(t *testing.T) *remoteLab {
	l := newTestLab(t)
	dir := filepath.Dir(l.root)
	r := &remoteLab{testLab: l, src: filepath.Join(dir, "src"), bare: filepath.Join(dir, "remote.git"), data: filepath.Join(dir, "data")}
	home := l.env["HOME"]
	gitT(t, home, dir, "init", "-q", "-b", "main", r.src)
	for p, c := range map[string]string{"Makefile": "", "scripts/env.sh": "", "VERSION": "1.2.3\n"} {
		os.MkdirAll(filepath.Join(r.src, filepath.Dir(p)), 0o755)
		os.WriteFile(filepath.Join(r.src, p), []byte(c), 0o644)
	}
	gitT(t, home, r.src, "add", ".")
	gitT(t, home, r.src, "commit", "-q", "-m", "one")
	gitT(t, home, r.src, "tag", "v1.2.3")
	r.commit("after the tag\n")
	gitT(t, home, dir, "clone", "-q", "--bare", r.src, r.bare)
	l.env["ANVIL_REPO_URL"] = r.bare
	l.env["XDG_DATA_HOME"] = r.data
	return r
}

func (r *remoteLab) commit(version string) {
	home := r.env["HOME"]
	os.WriteFile(filepath.Join(r.src, "VERSION"), []byte(version), 0o644)
	gitT(r.t, home, r.src, "commit", "-q", "-am", "change")
	if _, err := os.Stat(r.bare); err == nil {
		gitT(r.t, home, r.src, "push", "-q", "--tags", r.bare, "main")
	}
}

func (r *remoteLab) clone() string { return filepath.Join(r.data, "anvil", "repo") }

func (r *remoteLab) cloneFile() string {
	b, _ := os.ReadFile(filepath.Join(r.clone(), "VERSION"))
	return string(b)
}

func setVersion(t *testing.T, v string) {
	old := version
	version = v
	t.Cleanup(func() { version = old })
}

func TestFetchAndUpdateARelease(t *testing.T) {
	r := newRemoteLab(t)
	setVersion(t, "1.2.3")
	if code := r.run("", "fetch"); code != 0 {
		t.Fatalf("fetch: exit %d:\n%s", code, r.output())
	}
	if r.cloneFile() != "1.2.3\n" || !strings.Contains(r.output(), "at v1.2.3") {
		t.Fatalf("fetch checked out %q:\n%s", r.cloneFile(), r.output())
	}
	// A second fetch leaves it alone.
	if code := r.run("", "fetch"); code != 0 || !strings.Contains(r.output(), "already there") {
		t.Fatalf("second fetch: exit %d:\n%s", code, r.output())
	}

	// The repo is found from anywhere now.
	r.cwd(t.TempDir())
	if got, err := r.app().repoRoot(); err != nil || got != r.clone() {
		t.Fatalf("repoRoot = %q, %v", got, err)
	}

	// A new release: update moves the copy to its tag.
	r.commit("1.2.4\n")
	gitT(t, r.env["HOME"], r.src, "tag", "v1.2.4")
	gitT(t, r.env["HOME"], r.src, "push", "-q", "--tags", r.bare, "main")
	setVersion(t, "1.2.4")
	if code := r.run("", "update"); code != 0 || r.cloneFile() != "1.2.4\n" {
		t.Fatalf("update: exit %d, VERSION %q:\n%s", code, r.cloneFile(), r.output())
	}

	// Local changes: update refuses.
	os.WriteFile(filepath.Join(r.clone(), "VERSION"), []byte("mine\n"), 0o644)
	setVersion(t, "1.2.3")
	if code := r.run("", "update"); code != 1 || !strings.Contains(r.output(), "local changes") || r.cloneFile() != "mine\n" {
		t.Fatalf("dirty update: exit %d:\n%s", code, r.output())
	}
}

func TestFetchAndUpdateADevBuild(t *testing.T) {
	r := newRemoteLab(t)
	setVersion(t, "dev")
	if code := r.run("", "fetch"); code != 0 || r.cloneFile() != "after the tag\n" {
		t.Fatalf("fetch: exit %d, VERSION %q:\n%s", code, r.cloneFile(), r.output())
	}
	r.commit("newer\n")
	if code := r.run("", "update"); code != 0 || r.cloneFile() != "newer\n" {
		t.Fatalf("update: exit %d, VERSION %q:\n%s", code, r.cloneFile(), r.output())
	}
}

func TestFetchNeverTouchesOtherDirs(t *testing.T) {
	r := newRemoteLab(t)
	setVersion(t, "dev")
	// update without a fetched copy refuses, even inside a checkout of the user's.
	r.cwd(r.root)
	before, _ := os.ReadFile(filepath.Join(r.root, "Makefile"))
	if code := r.run("", "update"); code != 1 || !strings.Contains(r.output(), "Run anvil fetch first") {
		t.Fatalf("update with no copy: exit %d:\n%s", code, r.output())
	}
	after, _ := os.ReadFile(filepath.Join(r.root, "Makefile"))
	if string(before) != string(after) {
		t.Fatal("update touched the user's checkout")
	}
	// A non-empty directory that is not a checkout is refused, and kept.
	os.MkdirAll(r.clone(), 0o755)
	os.WriteFile(filepath.Join(r.clone(), "notes"), []byte("x"), 0o644)
	if code := r.run("", "fetch"); code != 1 {
		t.Fatalf("fetch over a directory: exit %d", code)
	}
	if _, err := os.Stat(filepath.Join(r.clone(), "notes")); err != nil {
		t.Fatal("fetch removed a file of the user's")
	}
	// A failed clone leaves nothing behind.
	os.RemoveAll(r.clone())
	r.env["ANVIL_REPO_URL"] = filepath.Join(r.data, "missing.git")
	if code := r.run("", "fetch"); code != 1 {
		t.Fatalf("fetch from nowhere: exit %d", code)
	}
	if _, err := os.Stat(r.clone()); !os.IsNotExist(err) {
		t.Fatal("a failed fetch left a directory")
	}
}

func TestNoRepoSaysHowToGetOne(t *testing.T) {
	r := newRemoteLab(t)
	r.cwd(t.TempDir())
	for _, cmd := range []string{"init", "status", "services"} {
		if code := r.run("", cmd); code != 1 || !strings.Contains(r.output(), "Run anvil fetch") {
			t.Errorf("%s: exit %d:\n%s", cmd, code, r.output())
		}
	}
}

func TestNoRepoAtATerminalOffersToFetch(t *testing.T) {
	r := newRemoteLab(t)
	r.cwd(t.TempDir())
	r.tty = true
	if code := r.run("\n", "backup", "--dry-run"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, r.output())
	}
	if !isRepoRoot(r.clone()) {
		t.Fatal("the repo was not fetched")
	}
	out := r.output()
	for _, want := range []string{"there is none yet", "Fetch it now? [Y/n]", "anvil fetch: cloning"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// The next command finds it without asking again.
	if code := r.run("", "backup", "--dry-run"); code != 0 || strings.Contains(r.output(), "Fetch it now?") {
		t.Errorf("second run: exit %d:\n%s", code, r.output())
	}
}

func TestNoRepoAtATerminalNoFetchesNothing(t *testing.T) {
	r := newRemoteLab(t)
	r.cwd(t.TempDir())
	r.tty = true
	if code := r.run("n\n", "backup", "--dry-run"); code != 1 || !strings.Contains(r.output(), "Run anvil fetch") {
		t.Fatalf("exit %d:\n%s", code, r.output())
	}
	if _, err := os.Stat(r.clone()); !os.IsNotExist(err) {
		t.Error("declining still fetched the repo")
	}
}
