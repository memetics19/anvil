package main

import (
	"strings"
	"testing"
)

func TestRotateChecksAsksThenRotates(t *testing.T) {
	l := newTestLab(t)
	if code := l.Run("y\n", "rotate", "radarr", "Sonarr,radarr"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Err.String())
	}
	calls := l.MakeCalls()
	if len(calls) != 2 || calls[0] != "rotate SECRET=radarr,sonarr CHECK=1" || calls[1] != "rotate SECRET=radarr,sonarr" {
		t.Fatalf("make calls = %q", calls)
	}
	if !strings.Contains(l.Out.String(), "Rotate radarr, sonarr now? The old keys stop working. [y/N]") {
		t.Errorf("no confirmation: %s", l.Out.String())
	}
}

func TestRotateNoMeansNoChange(t *testing.T) {
	l := newTestLab(t)
	if code := l.Run("n\n", "rotate", "arr"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if calls := l.MakeCalls(); len(calls) != 1 || calls[0] != "rotate SECRET=arr CHECK=1" {
		t.Fatalf("make calls = %q", calls)
	}
}

func TestRotateRefusesUnknown(t *testing.T) {
	l := newTestLab(t)
	for _, args := range [][]string{{"rotate"}, {"rotate", "vault"}, {"rotate", "radarr,jellyfin"}} {
		if code := l.Run("", args...); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
		if calls := l.MakeCalls(); len(calls) != 0 {
			t.Errorf("%v: make ran: %q", args, calls)
		}
	}
	if !strings.Contains(l.Err.String(), `no rotation for "jellyfin". These can rotate: radarr, sonarr, prowlarr, arr`) {
		t.Errorf("stderr: %s", l.Err.String())
	}
}
