package run

import "testing"

func TestMakeCmdQuoting(t *testing.T) {
	cases := map[string]MakeCmd{
		"make vm HOST=apps ARGS='--check --diff'": NewMake("vm", "HOST", "apps", "ARGS", "--check --diff"),
		"make tf-apply":                NewMake("tf-apply", "ARGS", ""),
		`make x ARGS='-e a='\''b'\'''`: NewMake("x", "ARGS", "-e a='b'"),
		"make provision NAME=pve2":     NewMake("provision", "NAME", "pve2"),
	}
	for want, m := range cases {
		if got := m.String(); got != want {
			t.Errorf("got %s, want %s", got, want)
		}
	}
}
