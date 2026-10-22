package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeTools puts every tool init checks on PATH, with versions that pass.
func fakeTools(l *testLab) {
	versions := map[string]string{
		"terraform": "Terraform v1.13.3", "vault": "Vault v1.20.4", "ansible-lint": "ansible-lint 25.9.2 using ansible-core:2.19.2",
		"yamllint": "yamllint 1.37.1", "gitleaks": "8.28.0", "tflint": "TFLint version 0.59.1",
		"age": "v1.2.1", "sshpass": "sshpass 1.10", "aws": "aws-cli/2.31.0", "pre-commit": "pre-commit 4.3.0",
		"python3": "Python 3.13.7", "git": "git version 2.51.0",
	}
	for name, v := range versions {
		l.tool(name, "#!/bin/sh\necho '"+v+"'\n")
	}
	// ansible-galaxy: every required collection is installed unless FAKE_GALAXY_EMPTY is set;
	// an install is logged to FAKE_LOG as "galaxy install".
	l.tool("ansible-galaxy", `#!/bin/sh
case "$*" in
  "collection list --format json")
    if [ -n "$FAKE_GALAXY_EMPTY" ]; then echo '{}'; else
    echo '{"/c":{"community.general":{},"community.hashi_vault":{},"community.crypto":{},"ansible.posix":{}}}'; fi ;;
  "collection install"*) echo "galaxy install" >> "$FAKE_LOG" ;;
esac
`)
	py := filepath.Join(l.bin, "ansible-python")
	l.tool("ansible-python", "#!/bin/sh\nexit 0\n")
	l.tool("ansible-playbook", "#!/bin/sh\necho 'ansible-playbook [core 2.19.2]'\necho '  python version = 3.13.7 (main) [Clang 17] ("+py+")'\n")
	// The Keychain answers with a value on stdout, which must never be printed.
	l.tool("security", "#!/bin/sh\necho 'password: \""+sentinelEnv+"\"'\ncase \"$*\" in *\"-a ${FAKE_MISSING_ITEM:-none}\"*) exit 44 ;; esac\nexit 0\n")
	// jq is the real one (status needs it). vault is fake.
	l.tool("vault", `#!/bin/sh
[ "$1" = version ] && { echo 'Vault v1.20.4'; exit 0; }
if [ -n "${FAKE_VAULT_JSON+x}" ]; then printf '%s\n' "$FAKE_VAULT_JSON"; else echo '{"initialized":true,"sealed":false}'; fi
exit "${FAKE_VAULT_RC:-0}"
`)
	home := l.env["HOME"]
	for _, f := range []string{".ssh/id_ed25519", ".ssh/id_ed25519.pub", ".config/homelab/vault-ca.pem"} {
		p := filepath.Join(home, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			l.t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x\n"), 0o600); err != nil {
			l.t.Fatal(err)
		}
	}
}

func TestInitReadyAndProblems(t *testing.T) {
	l := newTestLab(t)
	fakeTools(l)
	// Only the fakes and the system: a tool the test removes stays missing.
	l.env["PATH"] = l.bin + ":/usr/bin:/bin"
	if code := l.run("", "init"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.output())
	}
	out := l.output()
	for _, want := range []string{"ok    terraform 1.13.3 (needs 1.10 or newer)", "ok    pve-ip", "ok    Vault unsealed", "init: ready"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}

	cases := []struct {
		setup func()
		want  string
	}{
		{func() { l.tool("terraform", "#!/bin/sh\necho 'Terraform v1.9.8'\n") }, "FAIL  terraform 1.9.8 (needs 1.10 or newer). Fix: brew install hashicorp/tap/terraform"},
		{func() { os.Remove(filepath.Join(l.bin, "gitleaks")) }, "FAIL  gitleaks is missing. Fix: brew install gitleaks"},
		{func() { l.env["FAKE_MISSING_ITEM"] = "pve-ip" }, "FAIL  pve-ip is missing. Fix: security add-generic-password"},
		{func() { l.env["FAKE_VAULT_JSON"] = `{"initialized":true,"sealed":true}`; l.env["FAKE_VAULT_RC"] = "2" }, "FAIL  Vault sealed. Fix: make vault-unseal"},
		{func() { l.env["FAKE_VAULT_RC"] = "1"; l.env["FAKE_VAULT_JSON"] = "" }, "FAIL  Vault unreachable"},
		{func() { l.tool("ansible-python", "#!/bin/sh\nexit 1\n") }, "FAIL  hvac in the Python that runs Ansible. Fix:"},
	}
	for _, tc := range cases {
		fakeTools(l)
		for _, k := range []string{"FAKE_MISSING_ITEM", "FAKE_VAULT_JSON", "FAKE_VAULT_RC"} {
			delete(l.env, k)
		}
		tc.setup()
		code := l.run("", "init")
		if code != 1 || !strings.Contains(l.output(), tc.want) {
			t.Errorf("want exit 1 and %q, got %d:\n%s", tc.want, code, l.output())
		}
	}
	// An optional item is a warning, not a failure.
	fakeTools(l)
	delete(l.env, "FAKE_VAULT_RC")
	delete(l.env, "FAKE_VAULT_JSON")
	l.env["FAKE_MISSING_ITEM"] = "ceph-dashboard-password"
	if code := l.run("", "init"); code != 0 || !strings.Contains(l.output(), "warn  ceph-dashboard-password is missing") {
		t.Errorf("optional item: exit %d:\n%s", code, l.output())
	}
	if strings.Contains(l.output(), sentinelEnv) || strings.Contains(l.output(), sentinelSource) {
		t.Errorf("init printed a value:\n%s", l.output())
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
	fakeTools(l)
	l.write("scripts/env.sh", "export PVE_IP="+sentinelSource+"\n"+
		"export TF_VAR_site_json='"+testSiteJSON+"' HOMELAB_SITE_USED=vault\n"+
		"echo 'env.sh: warning: the Keychain bootstrap copy (site-bootstrap) is stale; Vault is used.' >&2\n")
	backups := filepath.Join(l.env["HOME"], "homelab-backups")
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

	if code := l.run("", "status"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.output())
	}
	out := l.output()
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
	for _, secret := range []string{"example.test", "198.51.100", sentinelEnv, sentinelSource} {
		if strings.Contains(out, secret) {
			t.Errorf("status printed %q:\n%s", secret, out)
		}
	}
	if len(urls) != 3 || !contains(urls, "https://dns.internal.example.test/") {
		t.Errorf("urls %q", urls)
	}
	if dnsServer != "198.51.100.53" || dnsName != "dns.internal.example.test" {
		t.Errorf("dns asked %s for %s", dnsServer, dnsName)
	}
}
