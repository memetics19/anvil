package main

import (
	"strings"
	"testing"
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
	l := newTestLab(t)
	if code := l.run("y\n", "increase-disk", "ragnarok", "600gb"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	calls := l.makeCalls()
	if len(calls) != 2 || calls[0] != "grow-disk HOST=ragnarok ADD=600 CHECK=1" || calls[1] != "grow-disk HOST=ragnarok ADD=600" {
		t.Fatalf("make calls = %q", calls)
	}
	if !strings.Contains(l.out.String(), "Add 600 GB to ragnarok's disk now? [y/N]") {
		t.Errorf("no confirmation: %s", l.out.String())
	}
}

func TestIncreaseDiskNoMeansNoChange(t *testing.T) {
	l := newTestLab(t)
	if code := l.run("n\n", "increase-disk", "ragnarok", "1.5tb"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if calls := l.makeCalls(); len(calls) != 1 || calls[0] != "grow-disk HOST=ragnarok ADD=1536 CHECK=1" {
		t.Fatalf("make calls = %q", calls)
	}
	if !strings.Contains(l.out.String(), "Nothing changed.") {
		t.Errorf("output: %s", l.out.String())
	}
}

func TestIncreaseDiskFailedCheckStops(t *testing.T) {
	l := newTestLab(t)
	l.env["FAKE_RC"] = "1"
	if code := l.run("y\n", "increase-disk", "ragnarok", "600"); code != 1 {
		t.Fatalf("exit %d, want the check's 1", code)
	}
	if calls := l.makeCalls(); len(calls) != 1 {
		t.Fatalf("grew after a failed check: %q", calls)
	}
}

func TestIncreaseDiskYesAndMountAfterTheWords(t *testing.T) {
	l := newTestLab(t)
	if code := l.run("", "increase-disk", "frigate", "100", "--mount", "/home", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.err.String())
	}
	calls := l.makeCalls()
	if len(calls) != 2 || calls[1] != "grow-disk HOST=frigate ADD=100 MOUNT=/home" {
		t.Fatalf("make calls = %q", calls)
	}
}

func TestIncreaseDiskUsage(t *testing.T) {
	l := newTestLab(t)
	for _, args := range [][]string{{"increase-disk"}, {"increase-disk", "ragnarok"}, {"increase-disk", "ragnarok", "lots"}} {
		if code := l.run("", args...); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
	}
	if calls := l.makeCalls(); len(calls) != 0 {
		t.Errorf("make ran: %q", calls)
	}
}
