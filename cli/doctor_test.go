package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDoctorIsInitWithAVersionCheck(t *testing.T) {
	l := newTestLab(t)
	fakeTools(l)
	l.env["PATH"] = l.bin + ":/usr/bin:/bin"
	// The real git, on a checkout tagged v1.2.3.
	os.Remove(filepath.Join(l.bin, "git"))
	home := l.env["HOME"]
	gitT(t, home, l.root, "init", "-q", "-b", "main")
	gitT(t, home, l.root, "add", "Makefile", "scripts/env.sh")
	gitT(t, home, l.root, "commit", "-q", "-m", "one")
	gitT(t, home, l.root, "tag", "v1.2.3")
	head := gitT(t, home, l.root, "rev-parse", "HEAD")

	setVersion(t, "1.2.3")
	if code := l.run("", "init"); code != 0 {
		t.Fatalf("init: exit %d:\n%s", code, l.output())
	}
	initOut := l.output()
	if code := l.run("", "doctor"); code != 0 {
		t.Fatalf("doctor: exit %d:\n%s", code, l.output())
	}
	if strings.ReplaceAll(l.output(), "doctor: ready", "init: ready") != initOut {
		t.Errorf("doctor and init differ:\n%s\n---\n%s", initOut, l.output())
	}
	if !strings.Contains(l.output(), "ok    anvil 1.2.3 matches the repo (v1.2.3)") {
		t.Errorf("tagged:\n%s", l.output())
	}

	oldCommit := commit
	t.Cleanup(func() { commit = oldCommit })
	cases := []struct {
		version, commit, want string
	}{
		{"1.2.4", "", "warn  anvil is 1.2.4, the repo is at v1.2.3. Fix: git -C "},
		{"dev", head, "ok    anvil dev was built from the repo's commit"},
		{"dev", "0123456789abcdef", "warn  anvil was built from 0123456, the repo is at " + head[:7] + ". Fix: make cli"},
		{"dev", "", "ok    anvil dev, a build without a commit, not compared"},
	}
	for _, tc := range cases {
		version, commit = tc.version, tc.commit
		// A mismatch is a warning: doctor still passes.
		if code := l.run("", "doctor"); code != 0 || !strings.Contains(l.output(), tc.want) {
			t.Errorf("%s %s: exit %d, want %q in:\n%s", tc.version, tc.commit, code, tc.want, l.output())
		}
	}
	if !strings.Contains(l.output(), "doctor: ready") {
		t.Errorf("doctor's verdict:\n%s", l.output())
	}
}
