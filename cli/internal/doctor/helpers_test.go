package doctor

import (
	"net/netip"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

// newTestLab is testlab.New with the Mac's routing stubbed: it is never read in tests.
func newTestLab(t *testing.T) *testlab.Lab {
	t.Helper()
	l := testlab.New(t)
	oldAddrs := labAddrs
	labAddrs = func() []netip.Addr { return nil }
	t.Cleanup(func() { labAddrs = oldAddrs })
	return l
}
