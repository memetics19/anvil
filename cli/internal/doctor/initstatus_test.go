package doctor

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

func TestInitReadyAndProblems(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)
	// Only the fakes and the system: a tool the test removes stays missing.
	l.Env["PATH"] = l.Bin + ":/usr/bin:/bin"
	if code := l.Run("", "init"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.Output())
	}
	out := l.Output()
	for _, want := range []string{"ok    terraform 1.13.3 (needs 1.10 or newer)", "ok    pve-ip", "ok    Vault unsealed", "init: ready"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}

	cases := []struct {
		setup func()
		want  string
	}{
		{func() { l.Tool("terraform", "#!/bin/sh\necho 'Terraform v1.9.8'\n") }, "FAIL  terraform 1.9.8 (needs 1.10 or newer). Fix: brew install hashicorp/tap/terraform"},
		{func() { os.Remove(filepath.Join(l.Bin, "gitleaks")) }, "FAIL  gitleaks is missing. Fix: brew install gitleaks"},
		{func() { l.Env["FAKE_MISSING_ITEM"] = "pve-ip" }, "FAIL  pve-ip is missing. Fix: security add-generic-password"},
		{func() { l.Env["FAKE_VAULT_JSON"] = `{"initialized":true,"sealed":true}`; l.Env["FAKE_VAULT_RC"] = "2" }, "FAIL  Vault sealed. Fix: make vault-unseal"},
		{func() { l.Env["FAKE_VAULT_RC"] = "1"; l.Env["FAKE_VAULT_JSON"] = "" }, "FAIL  Vault unreachable"},
		{func() { l.Tool("ansible-python", "#!/bin/sh\nexit 1\n") }, "FAIL  hvac in the Python that runs Ansible. Fix:"},
	}
	for _, tc := range cases {
		testlab.FakeTools(l)
		for _, k := range []string{"FAKE_MISSING_ITEM", "FAKE_VAULT_JSON", "FAKE_VAULT_RC"} {
			delete(l.Env, k)
		}
		tc.setup()
		code := l.Run("", "init")
		if code != 1 || !strings.Contains(l.Output(), tc.want) {
			t.Errorf("want exit 1 and %q, got %d:\n%s", tc.want, code, l.Output())
		}
	}
	// An optional item is a warning, not a failure.
	testlab.FakeTools(l)
	delete(l.Env, "FAKE_VAULT_RC")
	delete(l.Env, "FAKE_VAULT_JSON")
	l.Env["FAKE_MISSING_ITEM"] = "ceph-dashboard-password"
	if code := l.Run("", "init"); code != 0 || !strings.Contains(l.Output(), "warn  ceph-dashboard-password is missing") {
		t.Errorf("optional item: exit %d:\n%s", code, l.Output())
	}
	if strings.Contains(l.Output(), testlab.SentinelEnv) || strings.Contains(l.Output(), testlab.SentinelSource) {
		t.Errorf("init printed a value:\n%s", l.Output())
	}
}

func TestVersionAtLeast(t *testing.T) {
	for _, tc := range []struct {
		have, min string
		want      bool
	}{{"1.10.0", "1.10", true}, {"1.9.8", "1.10", false}, {"25.9.2", "25.9.2", true}, {"8.27.9", "8.28.0", false}, {"2.0", "1.99.99", true}} {
		if got := versionAtLeast(tc.have, tc.min); got != tc.want {
			t.Errorf("versionAtLeast(%s, %s) = %v", tc.have, tc.min, got)
		}
	}
}

const testSiteJSON = `{"domain":"example.test","gateway":{"subdomain":"internal"},` +
	`"hosts":{"apps":{"home_ip":"198.51.100.53"}},` +
	`"services":[{"name":"dns"},{"name":"pass"},{"name":"old","enabled":false},{"name":"home"}]}`

func TestStatusShowsNamesOnly(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)
	l.Write("scripts/env.sh", "export PVE_IP="+testlab.SentinelSource+"\n"+
		"export TF_VAR_site_json='"+testSiteJSON+"' HOMELAB_SITE_USED=vault\n"+
		"echo 'env.sh: warning: the Keychain bootstrap copy (site-bootstrap) is stale; Vault is used.' >&2\n")
	backups := filepath.Join(l.Env["HOME"], "homelab-backups")
	if err := os.MkdirAll(backups, 0o700); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-3*time.Hour - time.Minute)
	for _, f := range []string{"tfstate-20261022-0700.json.age", "vault-20261022-0700.snap"} {
		p := filepath.Join(backups, f)
		os.WriteFile(p, []byte("x"), 0o600)
		os.Chtimes(p, old, old)
	}

	var (
		mu                 sync.Mutex
		urls               []string
		dnsServer, dnsName string
	)
	statusHTTP = func(u string) int {
		mu.Lock()
		urls = append(urls, u)
		mu.Unlock()
		if strings.HasPrefix(u, "https://pass.") {
			return 0
		}
		return 200
	}
	statusDNS = func(server, name string) bool { dnsServer, dnsName = server, name; return true }
	t.Cleanup(func() { statusHTTP, statusDNS = httpStatus, dnsAnswers })

	if code := l.Run("", "status"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.Output())
	}
	out := l.Output()
	for _, want := range []string{
		"vault         unsealed",
		"site source   vault, the Keychain copy is stale",
		"  dns         200", "  pass        000", "  home        200",
		"pi-hole       answering",
		"  tfstate     3h ago", "  vault       3h ago", "  vaultwarden none",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "old") {
		t.Errorf("a disabled service was checked:\n%s", out)
	}
	for _, secret := range []string{"example.test", "198.51.100", testlab.SentinelEnv, testlab.SentinelSource} {
		if strings.Contains(out, secret) {
			t.Errorf("status printed %q:\n%s", secret, out)
		}
	}
	if len(urls) != 3 || !slices.Contains(urls, "https://dns.internal.example.test/") {
		t.Errorf("urls %q", urls)
	}
	if dnsServer != "198.51.100.53" || dnsName != "dns.internal.example.test" {
		t.Errorf("dns asked %s for %s", dnsServer, dnsName)
	}
}
