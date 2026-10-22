package main

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestFindRoot(t *testing.T) {
	l := newTestLab(t)
	deep := filepath.Join(l.root, "ansible", "roles", "x", "tasks")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := findRoot(deep, "")
	if err != nil || got != l.root {
		t.Fatalf("findRoot from a subdirectory = %q, %v; want %q", got, err, l.root)
	}
	other := t.TempDir()
	if _, err := findRoot(other, ""); err == nil {
		t.Fatal("findRoot outside the repo found one")
	}
	got, err = findRoot(other, l.root)
	if err != nil || got != l.root {
		t.Fatalf("findRoot with ANVIL_REPO = %q, %v; want %q", got, err, l.root)
	}
	if _, err := findRoot(l.root, other); err == nil {
		t.Fatal("ANVIL_REPO pointing elsewhere was accepted")
	}
}

func TestMakeCmdQuoting(t *testing.T) {
	cases := map[string]makeCmd{
		"make vm HOST=apps ARGS='--check --diff'": newMake("vm", "HOST", "apps", "ARGS", "--check --diff"),
		"make tf-apply":                newMake("tf-apply", "ARGS", ""),
		`make x ARGS='-e a='\''b'\'''`: newMake("x", "ARGS", "-e a='b'"),
		"make provision NAME=pve2":     newMake("provision", "NAME", "pve2"),
	}
	for want, m := range cases {
		if got := m.String(); got != want {
			t.Errorf("got %s, want %s", got, want)
		}
	}
}

// TestMapping pins the command each name maps to, against the real playbooks.
func TestMapping(t *testing.T) {
	c, err := loadCatalog(realRoot)
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name, host, check, apply string
		risky                    bool
	}{
		{"apps", "apps", "make vm HOST=apps ARGS='--check --diff'", "make vm HOST=apps", false},
		{"vm", "frigate", "make vm HOST=frigate ARGS='--check --diff'", "make vm HOST=frigate", false},
		{"vms", "", "make vms ARGS='--check --diff'", "make vms", false},
		{"vms", "netbird", "make vm HOST=netbird ARGS='--check --diff'", "make vm HOST=netbird", false},
		{"host", "", "make host ARGS='--check --diff'", "make host", false},
		{"host-network", "", "make host-network ARGS='--check --diff'", "make host-network", true},
		{"enclave", "", "make enclave ARGS='--check --diff'", "make enclave", true},
		{"vlans", "", "make vlans ARGS='--check --diff'", "make vlans", true},
		{"switch", "", "make switch", "make switch ARGS='-e network_switch_apply=true'", true},
		{"tf", "", "make tf-plan", "make tf-apply", true},
		{"tf-apply", "", "make tf-plan", "make tf-apply", true},
		{"vault", "", "make vault ARGS='--check --diff'", "make vault", false},
		{"ceph", "", "make ceph ARGS='--check --diff'", "make ceph", false},
		{"pihole", "", "make vm HOST=apps ARGS='--check --diff --tags pihole'", "make vm HOST=apps ARGS='--tags pihole'", false},
		{"gateway", "", "make vm HOST=apps ARGS='--check --diff --tags caddy'", "make vm HOST=apps ARGS='--tags caddy'", false},
		{"iptv", "", "make vm HOST=ragnarok ARGS='--check --diff --tags iptv'", "make vm HOST=ragnarok ARGS='--tags iptv'", false},
		{"arr_stack", "", "make vm HOST=ragnarok ARGS='--check --diff --tags arr'", "make vm HOST=ragnarok ARGS='--tags arr'", false},
		{"netbird-server", "", "make vm HOST=netbird ARGS='--check --diff --tags netbird_server'", "make vm HOST=netbird ARGS='--tags netbird_server'", false},
		{"docker", "", "make vms ARGS='--check --diff --tags docker'", "make vms ARGS='--tags docker'", false},
		{"docker", "apps", "make vm HOST=apps ARGS='--check --diff --tags docker'", "make vm HOST=apps ARGS='--tags docker'", false},
		{"vaultwarden", "", "make vm HOST=vaultwarden ARGS='--check --diff'", "make vm HOST=vaultwarden", false},
	}
	for _, tc := range cases {
		tg, err := c.resolve(tc.name, tc.host)
		if err != nil {
			t.Errorf("%s --host %q: %v", tc.name, tc.host, err)
			continue
		}
		if got := tg.checkCmd("", "").String(); got != tc.check {
			t.Errorf("%s check: got %s, want %s", tc.name, got, tc.check)
		}
		if got := tg.applyCmd("", "").String(); got != tc.apply {
			t.Errorf("%s apply: got %s, want %s", tc.name, got, tc.apply)
		}
		if tg.risky != tc.risky {
			t.Errorf("%s risky = %v, want %v", tc.name, tg.risky, tc.risky)
		}
	}
	tg, _ := c.resolve("apps", "")
	if got := tg.checkCmd("pihole,caddy", "-v").String(); got != "make vm HOST=apps ARGS='--check --diff --tags pihole,caddy -v'" {
		t.Errorf("tags and args: got %s", got)
	}
	for _, bad := range [][2]string{{"vm", ""}, {"vm", "nope"}, {"host", "apps"}, {"apps", "frigate"}, {"pihole", "frigate"}} {
		if _, err := c.resolve(bad[0], bad[1]); err == nil {
			t.Errorf("%s --host %q was accepted", bad[0], bad[1])
		}
	}
}

func TestServicesComeFromThePlaybook(t *testing.T) {
	c, err := loadCatalog(realRoot)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"pihole": "apps", "homepage": "apps", "caddy": "apps", "vaultwarden": "vaultwarden",
		"iptv": "ragnarok", "arr": "ragnarok", "frigate": "frigate", "netbird_server": "netbird",
	}
	for name, host := range want {
		s, ok := c.service(name)
		if !ok || !reflect.DeepEqual(s.hosts, []string{host}) {
			t.Errorf("service %s = %+v, %v; want it on %s", name, s, ok, host)
		}
	}
	for alias, tag := range serviceAliases {
		if _, ok := c.service(tag); !ok {
			t.Errorf("alias %s points at %s, which is no tag in %s", alias, tag, playbookPath)
		}
	}
	for alias, name := range targetAliases {
		if _, err := c.resolve(alias, ""); err != nil {
			t.Errorf("target alias %s -> %s: %v", alias, name, err)
		}
	}
	if !reflect.DeepEqual(c.vms, []string{"apps", "frigate", "netbird", "ragnarok", "vault", "vaultwarden"}) {
		t.Errorf("VMs = %v", c.vms)
	}
}

func TestUnknownNamesGetSuggestions(t *testing.T) {
	c, err := loadCatalog(realRoot)
	if err != nil {
		t.Fatal(err)
	}
	for name, hint := range map[string]string{"pihol": "pihole", "vaultwardn": "vaultwarden", "homepge": "homepage", "netbird_srv": "netbird_server"} {
		_, err := c.resolve(name, "")
		if err == nil || !strings.Contains(err.Error(), hint) {
			t.Errorf("%s: got %v, want a suggestion of %s", name, err, hint)
		}
	}
	if _, err := c.resolve("zzzz", ""); err == nil || strings.Contains(err.Error(), "Did you mean") {
		t.Errorf("zzzz: got %v", err)
	}
}

func TestSummaries(t *testing.T) {
	s := ansibleSummary(recapNoChanges + "\x1b[0;32mfrigate\x1b[0m : ok=3 changed=0 unreachable=0 failed=0\n")
	if !s.known || s.changes || len(s.lines) != 2 {
		t.Errorf("no changes: %+v", s)
	}
	if s := ansibleSummary(recapChanges); !s.known || !s.changes {
		t.Errorf("changes: %+v", s)
	}
	if s := ansibleSummary("pve : ok=1 changed=0 unreachable=1 failed=0\n"); !s.changes {
		t.Errorf("unreachable must count as changes: %+v", s)
	}
	// make vlans runs two playbooks: the counts add up.
	if s := ansibleSummary(recapNoChanges + recapChanges); !s.changes || s.lines[0] != "apps changed=2" {
		t.Errorf("two recaps: %+v", s)
	}
	if s := ansibleSummary("no recap here"); s.known {
		t.Errorf("no recap: %+v", s)
	}
	if s := tfSummary("No changes. Your infrastructure matches the configuration."); !s.known || s.changes {
		t.Errorf("tf no changes: %+v", s)
	}
	if s := tfSummary("Plan: 1 to add, 2 to change, 0 to destroy."); !s.changes || s.lines[0] != "1 to add, 2 to change, 0 to destroy" {
		t.Errorf("tf plan: %+v", s)
	}
	if s := switchSummary(`"msg": "nothing to change"` + "\nDry run, nothing sent."); !s.known || s.changes {
		t.Errorf("switch no changes: %+v", s)
	}
	if s := switchSummary("interface gi10\nDry run, nothing sent."); !s.changes {
		t.Errorf("switch plan: %+v", s)
	}
}

func TestConfirmation(t *testing.T) {
	ask := func(in string, f func(*bufio.Reader, *bytes.Buffer) bool) bool {
		var out bytes.Buffer
		return f(bufio.NewReader(strings.NewReader(in)), &out)
	}
	yn := func(r *bufio.Reader, w *bytes.Buffer) bool { return askYesNo(r, w, "go?") }
	for in, want := range map[string]bool{"y\n": true, "YES\n": true, "n\n": false, "\n": false, "": false, "yep\n": false} {
		if got := ask(in, yn); got != want {
			t.Errorf("askYesNo(%q) = %v", in, got)
		}
	}
	typed := func(r *bufio.Reader, w *bytes.Buffer) bool { return askTyped(r, w, "sure?", "vlans") }
	for in, want := range map[string]bool{"vlans\n": true, " vlans \n": true, "y\n": false, "VLANS\n": false, "": false} {
		if got := ask(in, typed); got != want {
			t.Errorf("askTyped(%q) = %v", in, got)
		}
	}
	plain := target{name: "host"}
	risky := target{name: "vlans", risky: true}
	cases := []struct {
		t    target
		yes  bool
		in   string
		want bool
	}{
		{plain, true, "", true},
		{plain, false, "y\n", true},
		{plain, false, "", false},
		{risky, true, "", false},
		{risky, true, "y\n", false},
		{risky, true, "vlans\n", true},
		{risky, false, "vlans\n", true},
	}
	for _, tc := range cases {
		var out bytes.Buffer
		if got := confirmApply(bufio.NewReader(strings.NewReader(tc.in)), &out, tc.t, tc.yes); got != tc.want {
			t.Errorf("confirmApply(%s, yes=%v, %q) = %v", tc.t.name, tc.yes, tc.in, got)
		}
	}
}

func TestApplySkipsWhenTheCheckShowsNoChanges(t *testing.T) {
	l := newTestLab(t)
	l.setCheckOutput(recapNoChanges)
	if code := l.run("", "apply", "pihole"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	want := []string{"vm HOST=apps ARGS=--check --diff --tags pihole"}
	if got := l.makeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
	if !strings.Contains(l.output(), "nothing to apply") {
		t.Errorf("output: %s", l.output())
	}
}

func TestApplyAsksThenApplies(t *testing.T) {
	l := newTestLab(t)
	l.setCheckOutput(recapChanges)

	if code := l.run("n\n", "apply", "pihole"); code != 1 || len(l.makeCalls()) != 1 {
		t.Fatalf("declined: exit %d, calls %q", code, l.makeCalls())
	}
	l.resetCalls()
	if code := l.run("y\n", "apply", "pihole"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	want := []string{"vm HOST=apps ARGS=--check --diff --tags pihole", "vm HOST=apps ARGS=--tags pihole"}
	if got := l.makeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
	l.resetCalls()
	if code := l.run("", "apply", "pihole", "--yes"); code != 0 || len(l.makeCalls()) != 2 {
		t.Fatalf("--yes: exit %d, calls %q", code, l.makeCalls())
	}
	// A risky target needs its name, --yes or not.
	l.resetCalls()
	if code := l.run("y\n", "apply", "vlans", "--yes"); code != 1 || len(l.makeCalls()) != 1 {
		t.Fatalf("risky with y: exit %d, calls %q", code, l.makeCalls())
	}
	l.resetCalls()
	if code := l.run("vlans\n", "apply", "vlans"); code != 0 || len(l.makeCalls()) != 2 {
		t.Fatalf("risky typed: exit %d, calls %q", code, l.makeCalls())
	}
}

func TestExitCodesComeFromMake(t *testing.T) {
	l := newTestLab(t)
	l.env["FAKE_RC"] = "3"
	if code := l.run("", "check", "apps"); code != 3 {
		t.Errorf("check: exit %d, want 3", code)
	}
	l.resetCalls()
	if code := l.run("y\n", "apply", "apps"); code != 3 || len(l.makeCalls()) != 1 {
		t.Errorf("apply after a failed check: exit %d, calls %q", code, l.makeCalls())
	}
	delete(l.env, "FAKE_RC")
	l.env["FAKE_APPLY_RC"] = "7"
	if code := l.run("", "backup"); code != 7 {
		t.Errorf("backup: exit %d, want 7", code)
	}
}

func TestCheckWithoutTargetRunsTheSafeSet(t *testing.T) {
	l := newTestLab(t)
	l.setCheckOutput(recapNoChanges)
	if code := l.run("", "check"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	want := []string{"host ARGS=--check --diff", "vms ARGS=--check --diff", "tf-plan"}
	if got := l.makeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
}

func TestDryRunPrintsCommandsAndNoValues(t *testing.T) {
	l := newTestLab(t)
	runs := [][]string{
		{"check", "apps", "--dry-run"},
		{"check", "--dry-run"},
		{"apply", "host-network", "--dry-run"},
		{"apply", "pihole", "--tags", "pihole", "--dry-run"},
		{"backup", "--dry-run"},
		{"restore", "tfstate", "--dry-run"},
		{"provision", "pve2", "--install", "--dry-run"},
		{"provision-iso", "pve2", "--dry-run"},
	}
	for _, args := range runs {
		if code := l.run("", args...); code != 0 {
			t.Errorf("%v: exit %d: %s", args, code, l.output())
		}
		out := l.output()
		if strings.Contains(out, sentinelEnv) || strings.Contains(out, sentinelSource) {
			t.Errorf("%v printed a value from the environment:\n%s", args, out)
		}
		if args[0] != "restore" && !strings.Contains(out, "make ") {
			t.Errorf("%v printed no make command:\n%s", args, out)
		}
	}
	if calls := l.makeCalls(); calls != nil {
		t.Errorf("a dry run ran make: %q", calls)
	}
	l.run("", "apply", "host-network", "--dry-run")
	want := "# host-network: check\nsource scripts/env.sh && make host-network ARGS='--check --diff'\n" +
		"# host-network: apply, only when the check shows changes\nsource scripts/env.sh && make host-network\n"
	if l.out.String() != want {
		t.Errorf("dry run output:\n%s\nwant:\n%s", l.out.String(), want)
	}
}

func TestRealRunsPrintNoValues(t *testing.T) {
	l := newTestLab(t)
	l.setCheckOutput(recapChanges)
	l.run("y\n", "apply", "apps")
	if out := l.output(); strings.Contains(out, sentinelEnv) || strings.Contains(out, sentinelSource) {
		t.Errorf("printed a value:\n%s", out)
	}
}

func TestForbiddenArgs(t *testing.T) {
	l := newTestLab(t)
	for _, a := range []string{"--force", "-target=x", "-v --force"} {
		if code := l.run("", "check", "apps", "--args", a); code != 2 {
			t.Errorf("--args %q: exit %d", a, code)
		}
	}
	if l.makeCalls() != nil {
		t.Errorf("make ran: %q", l.makeCalls())
	}
}

func TestHelp(t *testing.T) {
	l := newTestLab(t)
	for _, c := range commands {
		if code := l.run("", c.name, "--help"); code != 0 || !strings.Contains(l.out.String(), "usage: anvil "+c.name) {
			t.Errorf("%s --help: exit %d, %q", c.name, code, l.out.String())
		}
	}
	if code := l.run("", "nope"); code != 2 {
		t.Errorf("unknown command: exit %d", code)
	}
}
