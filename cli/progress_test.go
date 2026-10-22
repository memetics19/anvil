package main

import (
	"strings"
	"testing"
	"time"
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
	fakeTools(l)
	fixedClock(t, 1500*time.Millisecond)

	l.setCheckOutput(recapChanges)
	if code := l.run("", "up", "--only", "host,vault-init,vms,status", "--yes"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.output())
	}
	wantAll(t, l.output(),
		"stage 1/4: host\n", "stage 1/4: host applied in 1.5s",
		"stage 2/4: vault-init\n", "stage 2/4: vault-init skipped in 1.5s",
		"stage 3/4: vms\n", "stage 4/4: status\n", "STATUS-RAN", "stage 4/4: status unchanged in 1.5s",
		"anvil up: summary",
		"  host        applied    1.5s", "  vault-init  skipped    1.5s", "  vms         applied    1.5s",
		"  status      unchanged  1.5s", "  total                  1.5s  (1 unchanged, 2 applied, 1 skipped)",
		"anvil up: done, 4 stages")

	// A failure: the summary still prints, the rest is not run, then the resume hint.
	l.env["FAKE_RC"] = "5"
	if code := l.run("", "up", "--only", "host,vms", "--yes"); code != 5 {
		t.Fatalf("exit %d", code)
	}
	wantAll(t, l.output(), "stage 1/2: host failed in 1.5s", "  host   failed     1.5s", "  vms    not run\n", "(1 failed, 1 not run)")
	if !strings.Contains(l.err.String(), "anvil up --from host") || strings.Contains(l.output(), "stage 2/2") {
		t.Errorf("after a failure:\n%s", l.output())
	}
	delete(l.env, "FAKE_RC")

	// anvil up <service> has the same headers and table.
	l.setCheckOutput(recapNoChanges)
	if code := l.run("", "up", "pihole", "homepage", "--yes"); code != 0 {
		t.Fatalf("services: exit %d:\n%s", code, l.output())
	}
	wantAll(t, l.output(), "stage 1/2: pihole\n", "stage 1/2: pihole unchanged in 1.5s", "stage 2/2: homepage\n",
		"anvil up: summary", "  pihole    unchanged  1.5s", "  homepage  unchanged  1.5s", "(2 unchanged)")
	if strings.Contains(l.output(), esc) {
		t.Errorf("colored without a terminal")
	}

	l.tty = true
	l.run("", "up", "pihole", "--yes")
	if !strings.Contains(l.output(), esc+"1mstage 1/1: pihole"+esc+"0m") || !strings.Contains(l.output(), esc+"32munchanged") {
		t.Errorf("tty: no colors:\n%q", l.output())
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
