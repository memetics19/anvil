package main

import (
	"os"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/repo"
	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestNoRepoSaysHowToGetOne(t *testing.T) {
	r := testlab.NewRemote(t)
	r.Cwd(t.TempDir())
	for _, cmd := range []string{"init", "status", "services"} {
		if code := r.Run("", cmd); code != 1 || !strings.Contains(r.Output(), "Run anvil fetch") {
			t.Errorf("%s: exit %d:\n%s", cmd, code, r.Output())
		}
	}
}

func TestNoRepoAtATerminalOffersToFetch(t *testing.T) {
	r := testlab.NewRemote(t)
	r.Cwd(t.TempDir())
	r.TTY = true
	if code := r.Run("\n", "backup", "--dry-run"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, r.Output())
	}
	if !repo.IsRoot(r.Clone()) {
		t.Fatal("the repo was not fetched")
	}
	out := r.Output()
	for _, want := range []string{"there is none yet", "Fetch it now? [Y/n]", "anvil fetch: cloning"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// The next command finds it without asking again.
	if code := r.Run("", "backup", "--dry-run"); code != 0 || strings.Contains(r.Output(), "Fetch it now?") {
		t.Errorf("second run: exit %d:\n%s", code, r.Output())
	}
}

func TestNoRepoAtATerminalNoFetchesNothing(t *testing.T) {
	r := testlab.NewRemote(t)
	r.Cwd(t.TempDir())
	r.TTY = true
	if code := r.Run("n\n", "backup", "--dry-run"); code != 1 || !strings.Contains(r.Output(), "Run anvil fetch") {
		t.Fatalf("exit %d:\n%s", code, r.Output())
	}
	if _, err := os.Stat(r.Clone()); !os.IsNotExist(err) {
		t.Error("declining still fetched the repo")
	}
}
