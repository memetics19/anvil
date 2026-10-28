package main

import (
	"strings"
	"testing"
	"time"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func fixedClock(t *testing.T, d time.Duration) {
	t.Helper()
	since = func(time.Time) time.Duration { return d }
	t.Cleanup(func() { since = time.Since })
}

func wantAll(t *testing.T, out string, wants ...string) {
	t.Helper()
	last := -1
	for _, w := range wants {
		i := strings.Index(out, w)
		if i < 0 || i < last {
			t.Fatalf("missing or out of order %q in:\n%s", w, out)
		}
		last = i
	}
}

func TestUpProgressAndSummary(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)
	fixedClock(t, 1500*time.Millisecond)

	l.SetCheckOutput(testlab.RecapChanges)
	if code := l.Run("", "up", "--only", "host,vault-init,vms,status", "--yes"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.Output())
	}
	wantAll(t, l.Output(),
		"stage 1/4: host\n", "stage 1/4: host applied in 1.5s",
		"stage 2/4: vault-init\n", "stage 2/4: vault-init skipped in 1.5s",
		"stage 3/4: vms\n", "stage 4/4: status\n", "STATUS-RAN", "stage 4/4: status unchanged in 1.5s",
		"anvil up: summary",
		"  host        applied    1.5s", "  vault-init  skipped    1.5s", "  vms         applied    1.5s",
		"  status      unchanged  1.5s", "  total                  1.5s  (1 unchanged, 2 applied, 1 skipped)",
		"anvil up: done, 4 stages")

	// A failure: the summary still prints, the rest is not run, then the resume hint.
	l.Env["FAKE_RC"] = "5"
	if code := l.Run("", "up", "--only", "host,vms", "--yes"); code != 5 {
		t.Fatalf("exit %d", code)
	}
	wantAll(t, l.Output(), "stage 1/2: host failed in 1.5s", "  host   failed     1.5s", "  vms    not run\n", "(1 failed, 1 not run)")
	if !strings.Contains(l.Err.String(), "anvil up --from host") || strings.Contains(l.Output(), "stage 2/2") {
		t.Errorf("after a failure:\n%s", l.Output())
	}
	delete(l.Env, "FAKE_RC")

	// anvil up <service> has the same headers and table.
	l.SetCheckOutput(testlab.RecapNoChanges)
	if code := l.Run("", "up", "pihole", "homepage", "--yes"); code != 0 {
		t.Fatalf("services: exit %d:\n%s", code, l.Output())
	}
	wantAll(t, l.Output(), "stage 1/2: pihole\n", "stage 1/2: pihole unchanged in 1.5s", "stage 2/2: homepage\n",
		"anvil up: summary", "  pihole    unchanged  1.5s", "  homepage  unchanged  1.5s", "(2 unchanged)")
	if strings.Contains(l.Output(), esc) {
		t.Errorf("colored without a terminal")
	}

	l.TTY = true
	l.Run("", "up", "pihole", "--yes")
	if !strings.Contains(l.Output(), esc+"1mstage 1/1: pihole"+esc+"0m") || !strings.Contains(l.Output(), esc+"32munchanged") {
		t.Errorf("tty: no colors:\n%q", l.Output())
	}
}

func TestFmtDur(t *testing.T) {
	for d, want := range map[time.Duration]string{
		400 * time.Millisecond: "0.4s", 12300 * time.Millisecond: "12.3s",
		4*time.Minute + 5*time.Second: "4m05s", time.Hour + 2*time.Minute: "1h02m",
	} {
		if got := fmtDur(d); got != want {
			t.Errorf("fmtDur(%v) = %q, want %q", d, got, want)
		}
	}
}
