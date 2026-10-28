package repo

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestFindRoot(t *testing.T) {
	l := testlab.New(t)
	deep := filepath.Join(l.Root, "ansible", "roles", "x", "tasks")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := findRoot(deep, "")
	if err != nil || got != l.Root {
		t.Fatalf("findRoot from a subdirectory = %q, %v; want %q", got, err, l.Root)
	}
	other := t.TempDir()
	if _, err := findRoot(other, ""); err == nil {
		t.Fatal("findRoot outside the repo found one")
	}
	got, err = findRoot(other, l.Root)
	if err != nil || got != l.Root {
		t.Fatalf("findRoot with ANVIL_REPO = %q, %v; want %q", got, err, l.Root)
	}
	if _, err := findRoot(l.Root, other); err == nil {
		t.Fatal("ANVIL_REPO pointing elsewhere was accepted")
	}
}
