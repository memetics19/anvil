package main

import (
	"net/netip"
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/testlab"
)

// newTestLab is testlab.New with the Mac's routing and the Keychain stubbed: they are
// never read in tests.
func newTestLab(t *testing.T) *testlab.Lab {
	t.Helper()
	l := testlab.New(t)
	oldAddrs, oldKeychain := labAddrs, keychainValue
	labAddrs = func() []netip.Addr { return nil }
	keychainValue = func(*app.App, string) string { return "" }
	t.Cleanup(func() { labAddrs, keychainValue = oldAddrs, oldKeychain })
	return l
}
