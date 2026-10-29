package lab

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/testlab"
)

// TestMapping pins the command each name maps to, against the real playbooks.
func TestMapping(t *testing.T) {
	c, err := LoadCatalog(testlab.RealRoot)
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
		tg, err := c.Resolve(tc.name, tc.host)
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
	tg, _ := c.Resolve("apps", "")
	if got := tg.checkCmd("pihole,caddy", "-v").String(); got != "make vm HOST=apps ARGS='--check --diff --tags pihole,caddy -v'" {
		t.Errorf("tags and args: got %s", got)
	}
	for _, bad := range [][2]string{{"vm", ""}, {"vm", "nope"}, {"host", "apps"}, {"apps", "frigate"}, {"pihole", "frigate"}} {
		if _, err := c.Resolve(bad[0], bad[1]); err == nil {
			t.Errorf("%s --host %q was accepted", bad[0], bad[1])
		}
	}
}

func TestServicesComeFromThePlaybook(t *testing.T) {
	c, err := LoadCatalog(testlab.RealRoot)
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
		if _, err := c.Resolve(alias, ""); err != nil {
			t.Errorf("target alias %s -> %s: %v", alias, name, err)
		}
	}
	if !reflect.DeepEqual(c.vms, []string{"apps", "frigate", "identity", "llm", "netbird", "ragnarok", "vault", "vaultwarden"}) {
		t.Errorf("VMs = %v", c.vms)
	}
}

func TestUnknownNamesGetSuggestions(t *testing.T) {
	c, err := LoadCatalog(testlab.RealRoot)
	if err != nil {
		t.Fatal(err)
	}
	for name, hint := range map[string]string{"pihol": "pihole", "vaultwardn": "vaultwarden", "homepge": "homepage", "netbird_srv": "netbird_server"} {
		_, err := c.Resolve(name, "")
		if err == nil || !strings.Contains(err.Error(), hint) {
			t.Errorf("%s: got %v, want a suggestion of %s", name, err, hint)
		}
	}
	if _, err := c.Resolve("zzzz", ""); err == nil || strings.Contains(err.Error(), "Did you mean") {
		t.Errorf("zzzz: got %v", err)
	}
}

func TestSummaries(t *testing.T) {
	s := ansibleSummary(testlab.RecapNoChanges + "\x1b[0;32mfrigate\x1b[0m : ok=3 changed=0 unreachable=0 failed=0\n")
	if !s.Known || s.Changes || len(s.Lines) != 2 {
		t.Errorf("no changes: %+v", s)
	}
	if s := ansibleSummary(testlab.RecapChanges); !s.Known || !s.Changes {
		t.Errorf("changes: %+v", s)
	}
	if s := ansibleSummary("pve : ok=1 changed=0 unreachable=1 failed=0\n"); !s.Changes {
		t.Errorf("unreachable must count as changes: %+v", s)
	}
	// make vlans runs two playbooks: the counts add up.
	if s := ansibleSummary(testlab.RecapNoChanges + testlab.RecapChanges); !s.Changes || s.Lines[0] != "apps changed=2" {
		t.Errorf("two recaps: %+v", s)
	}
	if s := ansibleSummary("no recap here"); s.Known {
		t.Errorf("no recap: %+v", s)
	}
	if s := tfSummary("No changes. Your infrastructure matches the configuration."); !s.Known || s.Changes {
		t.Errorf("tf no changes: %+v", s)
	}
	if s := tfSummary("Plan: 1 to add, 2 to change, 0 to destroy."); !s.Changes || s.Lines[0] != "1 to add, 2 to change, 0 to destroy" {
		t.Errorf("tf plan: %+v", s)
	}
	if s := switchSummary(`"msg": "nothing to change"` + "\nDry run, nothing sent."); !s.Known || s.Changes {
		t.Errorf("switch no changes: %+v", s)
	}
	if s := switchSummary("interface gi10\nDry run, nothing sent."); !s.Changes {
		t.Errorf("switch plan: %+v", s)
	}
}

func TestConfirmation(t *testing.T) {
	ask := func(in string, f func(*bufio.Reader, *bytes.Buffer) bool) bool {
		var out bytes.Buffer
		return f(bufio.NewReader(strings.NewReader(in)), &out)
	}
	yn := func(r *bufio.Reader, w *bytes.Buffer) bool { return app.AskYesNo(r, w, "go?") }
	for in, want := range map[string]bool{"y\n": true, "YES\n": true, "n\n": false, "\n": false, "": false, "yep\n": false} {
		if got := ask(in, yn); got != want {
			t.Errorf("app.AskYesNo(%q) = %v", in, got)
		}
	}
	typed := func(r *bufio.Reader, w *bytes.Buffer) bool { return app.AskTyped(r, w, "sure?", "vlans") }
	for in, want := range map[string]bool{"vlans\n": true, " vlans \n": true, "y\n": false, "VLANS\n": false, "": false} {
		if got := ask(in, typed); got != want {
			t.Errorf("app.AskTyped(%q) = %v", in, got)
		}
	}
	plain := Target{Name: "host"}
	risky := Target{Name: "vlans", risky: true}
	cases := []struct {
		t    Target
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
			t.Errorf("confirmApply(%s, yes=%v, %q) = %v", tc.t.Name, tc.yes, tc.in, got)
		}
	}
}

func TestApplySkipsWhenTheCheckShowsNoChanges(t *testing.T) {
	l := testlab.New(t)
	l.SetCheckOutput(testlab.RecapNoChanges)
	if code := l.Run("", "apply", "pihole"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	want := []string{"vm HOST=apps ARGS=--check --diff --tags pihole"}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
	if !strings.Contains(l.Output(), "nothing to apply") {
		t.Errorf("output: %s", l.Output())
	}
}

func TestApplyAsksThenApplies(t *testing.T) {
	l := testlab.New(t)
	l.SetCheckOutput(testlab.RecapChanges)

	if code := l.Run("n\n", "apply", "pihole"); code != 1 || len(l.MakeCalls()) != 1 {
		t.Fatalf("declined: exit %d, calls %q", code, l.MakeCalls())
	}
	l.ResetCalls()
	if code := l.Run("y\n", "apply", "pihole"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	want := []string{"vm HOST=apps ARGS=--check --diff --tags pihole", "vm HOST=apps ARGS=--tags pihole"}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
	l.ResetCalls()
	if code := l.Run("", "apply", "pihole", "--yes"); code != 0 || len(l.MakeCalls()) != 2 {
		t.Fatalf("--yes: exit %d, calls %q", code, l.MakeCalls())
	}
	// A risky target needs its name, --yes or not.
	l.ResetCalls()
	if code := l.Run("y\n", "apply", "vlans", "--yes"); code != 1 || len(l.MakeCalls()) != 1 {
		t.Fatalf("risky with y: exit %d, calls %q", code, l.MakeCalls())
	}
	l.ResetCalls()
	if code := l.Run("vlans\n", "apply", "vlans"); code != 0 || len(l.MakeCalls()) != 2 {
		t.Fatalf("risky typed: exit %d, calls %q", code, l.MakeCalls())
	}
}

func TestExitCodesComeFromMake(t *testing.T) {
	l := testlab.New(t)
	l.Env["FAKE_RC"] = "3"
	if code := l.Run("", "check", "apps"); code != 3 {
		t.Errorf("check: exit %d, want 3", code)
	}
	l.ResetCalls()
	if code := l.Run("y\n", "apply", "apps"); code != 3 || len(l.MakeCalls()) != 1 {
		t.Errorf("apply after a failed check: exit %d, calls %q", code, l.MakeCalls())
	}
	delete(l.Env, "FAKE_RC")
	l.Env["FAKE_APPLY_RC"] = "7"
	if code := l.Run("", "backup"); code != 7 {
		t.Errorf("backup: exit %d, want 7", code)
	}
}

func TestCheckWithoutTargetRunsTheSafeSet(t *testing.T) {
	l := testlab.New(t)
	l.SetCheckOutput(testlab.RecapNoChanges)
	if code := l.Run("", "check"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	want := []string{"host ARGS=--check --diff", "vms ARGS=--check --diff", "tf-plan"}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
}

func TestDryRunPrintsCommandsAndNoValues(t *testing.T) {
	l := testlab.New(t)
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
		if code := l.Run("", args...); code != 0 {
			t.Errorf("%v: exit %d: %s", args, code, l.Output())
		}
		out := l.Output()
		if strings.Contains(out, testlab.SentinelEnv) || strings.Contains(out, testlab.SentinelSource) {
			t.Errorf("%v printed a value from the environment:\n%s", args, out)
		}
		if args[0] != "restore" && !strings.Contains(out, "make ") {
			t.Errorf("%v printed no make command:\n%s", args, out)
		}
	}
	if calls := l.MakeCalls(); calls != nil {
		t.Errorf("a dry run ran make: %q", calls)
	}
	l.Run("", "apply", "host-network", "--dry-run")
	want := "# host-network: check\nsource scripts/env.sh && make host-network ARGS='--check --diff'\n" +
		"# host-network: apply, only when the check shows changes\nsource scripts/env.sh && make host-network\n"
	if l.Out.String() != want {
		t.Errorf("dry run output:\n%s\nwant:\n%s", l.Out.String(), want)
	}
}

func TestRealRunsPrintNoValues(t *testing.T) {
	l := testlab.New(t)
	l.SetCheckOutput(testlab.RecapChanges)
	l.Run("y\n", "apply", "apps")
	if out := l.Output(); strings.Contains(out, testlab.SentinelEnv) || strings.Contains(out, testlab.SentinelSource) {
		t.Errorf("printed a value:\n%s", out)
	}
}

func TestForbiddenArgs(t *testing.T) {
	l := testlab.New(t)
	for _, a := range []string{"--force", "-target=x", "-v --force"} {
		if code := l.Run("", "check", "apps", "--args", a); code != 2 {
			t.Errorf("--args %q: exit %d", a, code)
		}
	}
	if l.MakeCalls() != nil {
		t.Errorf("make ran: %q", l.MakeCalls())
	}
}

// A checkout without Terraform setup gets tf-init before the first check, once.
func TestPrepareTerraform(t *testing.T) {
	l := testlab.New(t)
	testlab.FakeTools(l)
	l.SetCheckOutput(testlab.RecapNoChanges)
	if err := os.Remove(filepath.Join(l.Root, testlab.TFState)); err != nil {
		t.Fatal(err)
	}
	if code := l.Run("", "check", "vms"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	got := l.MakeCalls()
	if len(got) < 2 || got[0] != "tf-init" || strings.Count(strings.Join(got, "\n"), "tf-init") != 1 {
		t.Fatalf("calls %q, want tf-init first, once", got)
	}
	l.ResetCalls()
	l.Write(testlab.TFState, "{}")
	if code := l.Run("", "check", "vms"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	for _, c := range l.MakeCalls() {
		if c == "tf-init" {
			t.Fatalf("tf-init ran on an initialised checkout: %q", l.MakeCalls())
		}
	}
}

// Missing collections are installed once before the first check.
func TestPrepareCollections(t *testing.T) {
	l := testlab.New(t)
	testlab.FakeTools(l)
	l.Write("ansible/requirements.yml", "collections:\n  - name: community.general\n  - name: ansible.posix\n")
	l.SetCheckOutput(testlab.RecapNoChanges)
	l.Env["FAKE_GALAXY_EMPTY"] = "1"
	if code := l.Run("", "check", "vms"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	b, _ := os.ReadFile(l.Log)
	if strings.Count(string(b), "galaxy install") != 1 {
		t.Fatalf("want one install, log:\n%s\nout:\n%s", b, l.Output())
	}
	l.ResetCalls()
	delete(l.Env, "FAKE_GALAXY_EMPTY")
	if code := l.Run("", "check", "vms"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	b, _ = os.ReadFile(l.Log)
	if strings.Contains(string(b), "galaxy install") {
		t.Fatalf("installed although every collection is there, log:\n%s", b)
	}
}
