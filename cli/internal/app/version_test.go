package app_test

import (
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestVersionUnset(t *testing.T) {
	l := testlab.New(t)
	l.Run("", "version")
	if !strings.Contains(l.Output(), "anvil dev\n") || !strings.Contains(l.Output(), "commit    unknown") {
		t.Errorf("dev build:\n%s", l.Output())
	}
}
