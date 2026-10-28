package app

import (
	"reflect"
	"testing"
)

func TestStripNoColor(t *testing.T) {
	for _, tc := range []struct {
		in, want []string
		found    bool
	}{
		{[]string{"--no-color", "status"}, []string{"status"}, true},
		{[]string{"check", "apps", "--no-color"}, []string{"check", "apps"}, true},
		// The value of --args stays.
		{[]string{"check", "apps", "--args", "--no-color"}, []string{"check", "apps", "--args", "--no-color"}, false},
	} {
		got, found := stripNoColor(tc.in)
		if !reflect.DeepEqual(got, tc.want) || found != tc.found {
			t.Errorf("%q: %q %v", tc.in, got, found)
		}
	}
}
