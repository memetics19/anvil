package disk

import (
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestParseGB(t *testing.T) {
	for in, want := range map[string]int{
		"600gb": 600, "600GB": 600, "600G": 600, "600": 600, " 600 gb ": 600,
		"1tb": 1024, "1.5TB": 1536, "2T": 2048, "100gib": 100, "0.5tb": 512,
	} {
		if got, err := parseGB(in); err != nil || got != want {
			t.Errorf("parseGB(%q) = %d, %v; want %d", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "0", "-5", "600mb", "lots", "1.5", "0.0001tb", "70tb", "600 gigs"} {
		if _, err := parseGB(bad); err == nil {
			t.Errorf("parseGB(%q) accepted", bad)
		}
	}
}

func TestIncreaseDiskChecksAsksThenGrows(t *testing.T) {
	l := testlab.New(t)
	if code := l.Run("y\n", "increase-disk", "ragnarok", "600gb"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	calls := l.MakeCalls()
	if len(calls) != 2 || calls[0] != "grow-disk HOST=ragnarok ADD=600 CHECK=1" || calls[1] != "grow-disk HOST=ragnarok ADD=600" {
		t.Fatalf("make calls = %q", calls)
	}
	if !strings.Contains(l.Out.String(), "Add 600 GB to ragnarok's disk now? [y/N]") {
		t.Errorf("no confirmation: %s", l.Out.String())
	}
}

func TestIncreaseDiskNoMeansNoChange(t *testing.T) {
	l := testlab.New(t)
	if code := l.Run("n\n", "increase-disk", "ragnarok", "1.5tb"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if calls := l.MakeCalls(); len(calls) != 1 || calls[0] != "grow-disk HOST=ragnarok ADD=1536 CHECK=1" {
		t.Fatalf("make calls = %q", calls)
	}
	if !strings.Contains(l.Out.String(), "Nothing changed.") {
		t.Errorf("output: %s", l.Out.String())
	}
}

func TestIncreaseDiskFailedCheckStops(t *testing.T) {
	l := testlab.New(t)
	l.Env["FAKE_RC"] = "1"
	if code := l.Run("y\n", "increase-disk", "ragnarok", "600"); code != 1 {
		t.Fatalf("exit %d, want the check's 1", code)
	}
	if calls := l.MakeCalls(); len(calls) != 1 {
		t.Fatalf("grew after a failed check: %q", calls)
	}
}

func TestIncreaseDiskYesAndMountAfterTheWords(t *testing.T) {
	l := testlab.New(t)
	if code := l.Run("", "increase-disk", "frigate", "100", "--mount", "/home", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	calls := l.MakeCalls()
	if len(calls) != 2 || calls[1] != "grow-disk HOST=frigate ADD=100 MOUNT=/home" {
		t.Fatalf("make calls = %q", calls)
	}
}

func TestIncreaseDiskUsage(t *testing.T) {
	l := testlab.New(t)
	for _, args := range [][]string{{"increase-disk"}, {"increase-disk", "ragnarok"}, {"increase-disk", "ragnarok", "lots"}} {
		if code := l.Run("", args...); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
	}
	if calls := l.MakeCalls(); len(calls) != 0 {
		t.Errorf("make ran: %q", calls)
	}
}

func TestIncreaseDiskSizeWithoutVM(t *testing.T) {
	l := testlab.New(t)
	for _, size := range []string{"600gb", "600"} {
		if code := l.Run("", "increase-disk", size, "--yes"); code != 2 ||
			!strings.Contains(l.Err.String(), "which VM? Name it before the size: anvil increase-disk <vm> "+size) {
			t.Errorf("%s: exit %d, stderr %q", size, code, l.Err.String())
		}
	}
	if calls := l.MakeCalls(); len(calls) != 0 {
		t.Errorf("make ran: %q", calls)
	}
}
