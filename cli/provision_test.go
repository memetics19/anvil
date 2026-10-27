package main

import "testing"

func TestProvisionPowerOff(t *testing.T) {
	l := newTestLab(t)
	if code := l.run("pve2\n", "provision", "pve2", "--install", "--power-off"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	calls := l.makeCalls()
	want := []string{"provision NAME=pve2 ARGS=-e provision_power_off=true",
		"provision NAME=pve2 ARGS=-e provision_confirm=pve2 -e provision_power_off=true"}
	if len(calls) != 2 || calls[0] != want[0] || calls[1] != want[1] {
		t.Fatalf("make calls = %q, want %q", calls, want)
	}
}
