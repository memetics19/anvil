package drift

import (
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/testlab"
)

// newTestLab is testlab.New with the Keychain stubbed: it is never read in tests.
func newTestLab(t *testing.T) *testlab.Lab {
	t.Helper()
	l := testlab.New(t)
	oldKeychain := keychainValue
	keychainValue = func(*app.App, string) string { return "" }
	t.Cleanup(func() { keychainValue = oldKeychain })
	return l
}
