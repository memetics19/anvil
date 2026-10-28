package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestDoctorIsInitWithAVersionCheck(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)
	l.Env["PATH"] = l.Bin + ":/usr/bin:/bin"
	// The real git, on a checkout tagged v1.2.3.
	os.Remove(filepath.Join(l.Bin, "git"))
	home := l.Env["HOME"]
	testlab.Git(t, home, l.Root, "init", "-q", "-b", "main")
	testlab.Git(t, home, l.Root, "add", "Makefile", "scripts/env.sh")
	testlab.Git(t, home, l.Root, "commit", "-q", "-m", "one")
	testlab.Git(t, home, l.Root, "tag", "v1.2.3")
	head := testlab.Git(t, home, l.Root, "rev-parse", "HEAD")

	testlab.SetVersion(t, "1.2.3")
	if code := l.Run("", "init"); code != 0 {
		t.Fatalf("init: exit %d:\n%s", code, l.Output())
	}
	initOut := l.Output()
	if code := l.Run("", "doctor"); code != 0 {
		t.Fatalf("doctor: exit %d:\n%s", code, l.Output())
	}
	if strings.ReplaceAll(l.Output(), "doctor: ready", "init: ready") != initOut {
		t.Errorf("doctor and init differ:\n%s\n---\n%s", initOut, l.Output())
	}
	if !strings.Contains(l.Output(), "ok    anvil 1.2.3 matches the repo (v1.2.3)") {
		t.Errorf("tagged:\n%s", l.Output())
	}

	oldCommit := app.Commit
	t.Cleanup(func() { app.Commit = oldCommit })
	cases := []struct {
		version, commit, want string
	}{
		{"1.2.4", "", "warn  anvil is 1.2.4, the repo is at v1.2.3. Fix: git -C "},
		{"dev", head, "ok    anvil dev was built from the repo's commit"},
		{"dev", "0123456789abcdef", "warn  anvil was built from 0123456, the repo is at " + head[:7] + ". Fix: make cli"},
		{"dev", "", "ok    anvil dev, a build without a commit, not compared"},
	}
	for _, tc := range cases {
		app.Version, app.Commit = tc.version, tc.commit
		// A mismatch is a warning: doctor still passes.
		if code := l.Run("", "doctor"); code != 0 || !strings.Contains(l.Output(), tc.want) {
			t.Errorf("%s %s: exit %d, want %q in:\n%s", tc.version, tc.commit, code, tc.want, l.Output())
		}
	}
	if !strings.Contains(l.Output(), "doctor: ready") {
		t.Errorf("doctor's verdict:\n%s", l.Output())
	}
}
