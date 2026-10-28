package main

import (
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
)

func TestHelp(t *testing.T) {
	l := newTestLab(t)
	for _, c := range app.Commands() {
		if code := l.Run("", c.Name, "--help"); code != 0 || !strings.Contains(l.Out.String(), "usage: anvil "+c.Name) {
			t.Errorf("%s --help: exit %d, %q", c.Name, code, l.Out.String())
		}
	}
	if code := l.Run("", "nope"); code != 2 {
		t.Errorf("unknown command: exit %d", code)
	}
}
