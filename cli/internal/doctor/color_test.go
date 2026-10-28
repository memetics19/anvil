package doctor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

const esc = "\x1b["

func TestColorOnlyOnATerminal(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)
	l.Env["PATH"] = l.Bin + ":/usr/bin:/bin"

	// Not a terminal: plain.
	if code := l.Run("", "init"); code != 0 || strings.Contains(l.Output(), esc) {
		t.Fatalf("pipe: exit %d, colored:\n%q", code, l.Output())
	}
	// A terminal: the marks and the verdict are colored.
	l.TTY = true
	l.Run("", "init")
	for _, want := range []string{esc + "32mok  " + esc + "0m  terraform", esc + "32minit: ready"} {
		if !strings.Contains(l.Output(), want) {
			t.Errorf("tty: missing %q in:\n%q", want, l.Output())
		}
	}
	// NO_COLOR, TERM=dumb and --no-color (anywhere) turn it off.
	l.Env["NO_COLOR"] = "1"
	if l.Run("", "init"); strings.Contains(l.Output(), esc) {
		t.Errorf("NO_COLOR: colored")
	}
	delete(l.Env, "NO_COLOR")
	l.Env["TERM"] = "dumb"
	if l.Run("", "init"); strings.Contains(l.Output(), esc) {
		t.Errorf("TERM=dumb: colored")
	}
	delete(l.Env, "TERM")
	for _, args := range [][]string{{"--no-color", "init"}, {"init", "--no-color"}} {
		if code := l.Run("", args...); code != 0 || strings.Contains(l.Output(), esc) {
			t.Errorf("%v: exit %d, colored", args, code)
		}
	}
}

func TestStatusMarksProblems(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)
	l.Write("scripts/env.sh", "export PVE_IP="+testlab.SentinelSource+"\n"+
		"export TF_VAR_site_json='"+testSiteJSON+"' HOMELAB_SITE_USED=vault\n")
	l.Env["FAKE_VAULT_JSON"] = `{"initialized":true,"sealed":true}`
	l.Env["FAKE_VAULT_RC"] = "2"
	backups := filepath.Join(l.Env["HOME"], "homelab-backups")
	os.MkdirAll(backups, 0o700)
	for f, age := range map[string]time.Duration{"tfstate-1.json.age": 40 * time.Hour, "vault-1.snap": 2 * time.Hour, "vaultwarden-1.tar.age": 35 * time.Hour} {
		p := filepath.Join(backups, f)
		os.WriteFile(p, []byte("x"), 0o600)
		ts := time.Now().Add(-age)
		os.Chtimes(p, ts, ts)
	}
	statusHTTP = func(u string) int {
		switch {
		case strings.HasPrefix(u, "https://pass."):
			return 0
		case strings.HasPrefix(u, "https://home."):
			return 502
		}
		return 302
	}
	statusDNS = func(string, string) bool { return true }
	t.Cleanup(func() { statusHTTP, statusDNS = httpStatus, dnsAnswers })

	if code := l.Run("", "status"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.Output())
	}
	out := l.Output()
	for _, want := range []string{
		"vault         sealed. Fix: make vault-unseal",
		"  dns         302\n", "  pass        000  no connection", "  home        502  server error",
		"  tfstate     40h ago, stale (over 36h)", "  vault       2h ago\n", "  vaultwarden 35h ago\n",
		"status: 4 problem(s): vault, gateway pass, gateway home, backup tfstate",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, esc) {
		t.Errorf("colored without a terminal")
	}
	l.TTY = true
	l.Run("", "status")
	if out := l.Output(); !strings.Contains(out, esc+"31m000  no connection"+esc+"0m") || !strings.Contains(out, "  dns         302\n") {
		t.Errorf("tty: problems not red, or a fine line colored:\n%q", out)
	}
}
