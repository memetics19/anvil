package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

// TestVersionLdflags builds the binary the way make cli and GoReleaser do, and checks
// that anvil version shows what -ldflags set.
func TestVersionLdflags(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the binary")
	}
	bin := filepath.Join(t.TempDir(), "anvil")
	ld := "-X main.version=1.2.3 -X main.commit=0123abc -X main.date=2026-01-02T03:04:05Z"
	build := exec.Command("go", "build", "-trimpath", "-ldflags", ld, "-o", bin, ".")
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	for _, args := range [][]string{{"version"}, {"--version"}} {
		out, err := exec.Command(bin, args...).Output()
		if err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		for _, want := range []string{"anvil 1.2.3\n", "commit    0123abc", "built     2026-01-02T03:04:05Z",
			"go        " + runtime.Version(), "platform  " + runtime.GOOS + "/" + runtime.GOARCH} {
			if !strings.Contains(string(out), want) {
				t.Errorf("%v: missing %q in:\n%s", args, want, out)
			}
		}
	}
}

// TestMakeCliSetsTheVersion keeps make cli in step with the variables above.
func TestMakeCliSetsTheVersion(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(testlab.RealRoot, "Makefile"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"-X main.version=$(ANVIL_VERSION)", "-X main.commit=$(ANVIL_COMMIT)", "-X main.date=$(ANVIL_DATE)"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("make cli does not set %s", want)
		}
	}
}
