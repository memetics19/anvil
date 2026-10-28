package main

import (
	"strings"
	"testing"
)

func TestPoolsChecksAsksThenCreates(t *testing.T) {
	l := newTestLab(t)
	if code := l.Run("y\n", "pools", "pve2"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	calls := l.MakeCalls()
	if len(calls) != 2 || calls[0] != "pools HOST=pve2 ARGS=--check" || calls[1] != "pools HOST=pve2" {
		t.Fatalf("make calls = %q", calls)
	}
}

func TestPoolsWipeNamesThePool(t *testing.T) {
	l := newTestLab(t)
	if code := l.Run("n\n", "pools", "pve2", "--wipe", "tank"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if calls := l.MakeCalls(); len(calls) != 1 || calls[0] != "pools HOST=pve2 WIPE=tank ARGS=--check" {
		t.Fatalf("make calls = %q", calls)
	}
	if !strings.Contains(l.Out.String(), "Wipe the disks of tank and create the missing pools on pve2 now?") {
		t.Errorf("output: %s", l.Out.String())
	}
}

func TestPoolsWipeSeveral(t *testing.T) {
	l := newTestLab(t)
	if code := l.Run("y\n", "pools", "pve2", "--wipe", "vmdata,tank"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	calls := l.MakeCalls()
	if len(calls) != 2 || calls[1] != "pools HOST=pve2 WIPE=vmdata,tank" {
		t.Fatalf("make calls = %q", calls)
	}
	if !strings.Contains(l.Out.String(), "Wipe the disks of vmdata, tank and create") {
		t.Errorf("output: %s", l.Out.String())
	}
}

func TestPoolsRefusesBadNames(t *testing.T) {
	l := newTestLab(t)
	for _, args := range [][]string{{"pools"}, {"pools", "a", "b"}, {"pools", "../x"}, {"pools", "pve2", "--wipe", "rm -rf"}, {"pools", "pve2", "--wipe", "tank,../x"}} {
		if code := l.Run("", args...); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
	}
	if calls := l.MakeCalls(); len(calls) != 0 {
		t.Errorf("make ran: %q", calls)
	}
}
