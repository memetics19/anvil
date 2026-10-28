package provision

import (
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestProvisionPowerOff(t *testing.T) {
	l := testlab.New(t)
	if code := l.Run("pve2\n", "provision", "pve2", "--install", "--power-off"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	calls := l.MakeCalls()
	want := []string{"provision NAME=pve2 ARGS=-e provision_power_off=true",
		"provision NAME=pve2 ARGS=-e provision_confirm=pve2 -e provision_power_off=true"}
	if len(calls) != 2 || calls[0] != want[0] || calls[1] != want[1] {
		t.Fatalf("make calls = %q, want %q", calls, want)
	}
}
