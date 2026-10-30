package suite

import (
	"reflect"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestTestRunsALayerThroughMake(t *testing.T) {
	l := testlab.New(t)
	if code := l.Run("", "test", "smoke", "gateway"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	if code := l.Run("", "test", "unit"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	if want := []string{"test-smoke T=gateway", "test-unit"}; !reflect.DeepEqual(l.MakeCalls(), want) {
		t.Fatalf("calls %q, want %q", l.MakeCalls(), want)
	}
	l.Env["FAKE_SMOKE_RC"] = "1"
	if code := l.Run("", "test", "smoke"); code != 1 {
		t.Fatalf("a failed smoke test: exit %d", code)
	}
}

func TestTestRefusesUnknownLayersAndNames(t *testing.T) {
	l := testlab.New(t)
	for _, args := range [][]string{{"test"}, {"test", "e2e-ish"}, {"test", "smoke", "a;b"}, {"test", "unit", "a", "b"}} {
		if code := l.Run("", args...); code != 2 {
			t.Errorf("%q: exit %d, want 2", args, code)
		}
	}
	if calls := l.MakeCalls(); calls != nil {
		t.Errorf("make ran: %q", calls)
	}
}
