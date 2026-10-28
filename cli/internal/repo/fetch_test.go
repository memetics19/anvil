package repo

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestFetchAndUpdateARelease(t *testing.T) {
	r := testlab.NewRemote(t)
	testlab.SetVersion(t, "1.2.3")
	if code := r.Run("", "fetch"); code != 0 {
		t.Fatalf("fetch: exit %d:\n%s", code, r.Output())
	}
	if r.CloneFile() != "1.2.3\n" || !strings.Contains(r.Output(), "at v1.2.3") {
		t.Fatalf("fetch checked out %q:\n%s", r.CloneFile(), r.Output())
	}
	// A second fetch leaves it alone.
	if code := r.Run("", "fetch"); code != 0 || !strings.Contains(r.Output(), "already there") {
		t.Fatalf("second fetch: exit %d:\n%s", code, r.Output())
	}

	// The repo is found from anywhere now.
	r.Cwd(t.TempDir())
	if got, err := Root(r.App()); err != nil || got != r.Clone() {
		t.Fatalf("repoRoot = %q, %v", got, err)
	}

	// A new release: update moves the copy to its tag.
	r.Commit("1.2.4\n")
	testlab.Git(t, r.Env["HOME"], r.Src, "tag", "v1.2.4")
	testlab.Git(t, r.Env["HOME"], r.Src, "push", "-q", "--tags", r.Bare, "main")
	testlab.SetVersion(t, "1.2.4")
	if code := r.Run("", "update"); code != 0 || r.CloneFile() != "1.2.4\n" {
		t.Fatalf("update: exit %d, VERSION %q:\n%s", code, r.CloneFile(), r.Output())
	}

	// Local changes: update refuses.
	os.WriteFile(filepath.Join(r.Clone(), "VERSION"), []byte("mine\n"), 0o644)
	testlab.SetVersion(t, "1.2.3")
	if code := r.Run("", "update"); code != 1 || !strings.Contains(r.Output(), "local changes") || r.CloneFile() != "mine\n" {
		t.Fatalf("dirty update: exit %d:\n%s", code, r.Output())
	}
}

func TestFetchAndUpdateADevBuild(t *testing.T) {
	r := testlab.NewRemote(t)
	testlab.SetVersion(t, "dev")
	if code := r.Run("", "fetch"); code != 0 || r.CloneFile() != "after the tag\n" {
		t.Fatalf("fetch: exit %d, VERSION %q:\n%s", code, r.CloneFile(), r.Output())
	}
	r.Commit("newer\n")
	if code := r.Run("", "update"); code != 0 || r.CloneFile() != "newer\n" {
		t.Fatalf("update: exit %d, VERSION %q:\n%s", code, r.CloneFile(), r.Output())
	}
}

func TestFetchNeverTouchesOtherDirs(t *testing.T) {
	r := testlab.NewRemote(t)
	testlab.SetVersion(t, "dev")
	// update without a fetched copy refuses, even inside a checkout of the user's.
	r.Cwd(r.Root)
	before, _ := os.ReadFile(filepath.Join(r.Root, "Makefile"))
	if code := r.Run("", "update"); code != 1 || !strings.Contains(r.Output(), "Run anvil fetch first") {
		t.Fatalf("update with no copy: exit %d:\n%s", code, r.Output())
	}
	after, _ := os.ReadFile(filepath.Join(r.Root, "Makefile"))
	if string(before) != string(after) {
		t.Fatal("update touched the user's checkout")
	}
	// A non-empty directory that is not a checkout is refused, and kept.
	os.MkdirAll(r.Clone(), 0o755)
	os.WriteFile(filepath.Join(r.Clone(), "notes"), []byte("x"), 0o644)
	if code := r.Run("", "fetch"); code != 1 {
		t.Fatalf("fetch over a directory: exit %d", code)
	}
	if _, err := os.Stat(filepath.Join(r.Clone(), "notes")); err != nil {
		t.Fatal("fetch removed a file of the user's")
	}
	// A failed clone leaves nothing behind.
	os.RemoveAll(r.Clone())
	r.Env["ANVIL_REPO_URL"] = filepath.Join(r.Data, "missing.git")
	if code := r.Run("", "fetch"); code != 1 {
		t.Fatalf("fetch from nowhere: exit %d", code)
	}
	if _, err := os.Stat(r.Clone()); !os.IsNotExist(err) {
		t.Fatal("a failed fetch left a directory")
	}
}
