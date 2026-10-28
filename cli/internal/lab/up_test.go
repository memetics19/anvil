package lab

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

// docsOrder is docs/setup.md, First build, as anvil up runs it.
var docsOrder = []string{
	"bootstrap-ssh-host", "host", "host-network", "ceph", "s3-keys", "tf-init", "tf", "vault",
	"vault-init", "vault-unseal", "vault-policies", "site-to-vault", "backup-key", "secrets",
	"ceph-users", "host-homepage", "enclave", "vlans", "switch", "bootstrap-ssh-guests", "vms",
	"handsteps", "backup", "status",
}

func TestUpStageOrder(t *testing.T) {
	var got []string
	for _, s := range upStages() {
		got = append(got, s.name)
	}
	if !reflect.DeepEqual(got, docsOrder) {
		t.Fatalf("stages\n%q\nwant\n%q", got, docsOrder)
	}
	for _, s := range upStages() {
		if s.kind == skCheckApply && s.t.make == "provision" {
			t.Errorf("provision must never be part of anvil up")
		}
		if s.kind == skHuman && s.done == "" && !s.ack {
			t.Errorf("%s: a human stage needs a probe or an acknowledgement", s.name)
		}
	}
}

func TestUpDryRunPrintsThePlan(t *testing.T) {
	l := testlab.New(t)
	if code := l.Run("", "up", "--dry-run"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	out := l.Output()
	last := -1
	for _, n := range docsOrder {
		i := strings.Index(out, ". "+n+" ")
		if i < 0 || i < last {
			t.Fatalf("stage %s missing or out of order in:\n%s", n, out)
		}
		last = i
	}
	for _, want := range []string{
		"check  make bootstrap-ssh ARGS='--limit proxmox --check --diff'",
		"apply  make host ARGS='--skip-tags homepage'",
		"check  make tf-plan", "apply  make tf-apply",
		"apply  make switch ARGS='-e network_switch_apply=true'",
		"run    make vault-unseal", "run    make backup",
		"pause  for you, skipped when the Keychain has vault-init-json",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(out, "--force") || strings.Contains(out, "provision") {
		t.Errorf("the plan has a force flag or provision:\n%s", out)
	}
	if strings.Contains(out, testlab.SentinelEnv) || strings.Contains(out, testlab.SentinelSource) {
		t.Errorf("printed a value:\n%s", out)
	}
	if l.MakeCalls() != nil {
		t.Errorf("a dry run ran make: %q", l.MakeCalls())
	}

	l.Run("", "up", "--only", "vms", "--dry-run")
	if out := l.Output(); !strings.Contains(out, "1 of 24 stages") || !strings.Contains(out, "make vms ARGS='--check --diff'") || strings.Contains(out, ". host ") {
		t.Errorf("--only vms:\n%s", out)
	}
}

func TestUpSkipsApplyWhenChecksShowNoChanges(t *testing.T) {
	l := testlab.New(t)
	testlab.FakeTools(l)
	l.SetCheckOutput(testlab.RecapNoChanges)
	if code := l.Run("", "up", "--only", "host,enclave,vms", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	want := []string{"host ARGS=--skip-tags homepage --check --diff", "enclave ARGS=--check --diff", "vms ARGS=--check --diff"}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}

	l.ResetCalls()
	l.SetCheckOutput(testlab.RecapChanges)
	if code := l.Run("", "up", "--only", "host,vms", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	want = []string{"host ARGS=--skip-tags homepage --check --diff", "host ARGS=--skip-tags homepage", "vms ARGS=--check --diff", "vms"}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
}

func TestUpAsksOnce(t *testing.T) {
	l := testlab.New(t)
	testlab.FakeTools(l)
	l.SetCheckOutput(testlab.RecapChanges)
	if code := l.Run("y\n", "up", "--only", "vms"); code != 1 || l.MakeCalls() != nil {
		t.Fatalf("y is not up: exit %d, calls %q", code, l.MakeCalls())
	}
	// One "up" covers every stage, risky ones included.
	if code := l.Run("up\n", "up", "--only", "vlans,vms"); code != 0 || len(l.MakeCalls()) != 4 {
		t.Fatalf("exit %d, calls %q: %s", code, l.MakeCalls(), l.Output())
	}
}

func TestUpStopsOnFailureAndResumes(t *testing.T) {
	l := testlab.New(t)
	testlab.FakeTools(l)
	l.SetCheckOutput(testlab.RecapNoChanges)
	l.Env["FAKE_RC"] = "5"
	if code := l.Run("", "up", "--only", "host,vms", "--yes"); code != 5 {
		t.Fatalf("exit %d, want 5", code)
	}
	if !strings.Contains(l.Output(), "anvil up --from host") || len(l.MakeCalls()) != 1 {
		t.Fatalf("calls %q, output:\n%s", l.MakeCalls(), l.Output())
	}
	delete(l.Env, "FAKE_RC")
	l.ResetCalls()
	if code := l.Run("", "up", "--from", "vms", "--skip", "handsteps,backup", "--yes"); code != 0 {
		t.Fatalf("resume: exit %d: %s", code, l.Output())
	}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, []string{"vms ARGS=--check --diff"}) {
		t.Fatalf("resume calls %q", got)
	}
	if !strings.Contains(l.Output(), "STATUS-RAN") {
		t.Errorf("status did not run:\n%s", l.Output())
	}
	st := readState(t, l)
	if !reflect.DeepEqual(st.Completed, []string{"vms", "status"}) {
		t.Errorf("state completed %q", st.Completed)
	}
}

func readState(t *testing.T, l *testlab.Lab) upState {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(l.Root, stateFile))
	if err != nil {
		t.Fatal(err)
	}
	var st upState
	if err := json.Unmarshal(b, &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func TestUpPausesForPeople(t *testing.T) {
	l := testlab.New(t)
	testlab.FakeTools(l)

	// Already done: the Keychain has the items.
	if code := l.Run("", "up", "--only", "vault-init", "--yes"); code != 0 || !strings.Contains(l.Output(), "already done") {
		t.Fatalf("done: exit %d:\n%s", code, l.Output())
	}

	// Not done, --yes: stop with a resume hint instead of waiting.
	l.Env["FAKE_MISSING_ITEM"] = "vault-init-json"
	if code := l.Run("", "up", "--only", "vault-init,vault-unseal", "--yes"); code != exitNeedsYou {
		t.Fatalf("--yes: exit %d", code)
	}
	if out := l.Output(); !strings.Contains(out, "scripts/vault-init.sh") || !strings.Contains(out, "anvil up --from vault-init") {
		t.Errorf("--yes output:\n%s", out)
	}
	if l.MakeCalls() != nil {
		t.Errorf("ran past the pause: %q", l.MakeCalls())
	}

	// Not done, interactive: Enter, but the item is still missing.
	if code := l.Run("up\n\n", "up", "--only", "vault-init,vault-unseal"); code != exitNeedsYou || !strings.Contains(l.Output(), "still not done") {
		t.Fatalf("still missing: exit %d:\n%s", code, l.Output())
	}
	// q stops.
	if code := l.Run("up\nq\n", "up", "--only", "vault-init"); code != exitNeedsYou {
		t.Fatalf("q: exit %d", code)
	}

	// handsteps has no probe: Enter acknowledges it once, and the state keeps that.
	delete(l.Env, "FAKE_MISSING_ITEM")
	if code := l.Run("up\n\n", "up", "--only", "handsteps,backup"); code != 0 {
		t.Fatalf("handsteps: exit %d:\n%s", code, l.Output())
	}
	if !slices.Contains(readState(t, l).Acknowledged, "handsteps") || !reflect.DeepEqual(l.MakeCalls(), []string{"backup"}) {
		t.Fatalf("state %+v, calls %q", readState(t, l), l.MakeCalls())
	}
	if code := l.Run("", "up", "--only", "handsteps", "--yes"); code != 0 || !strings.Contains(l.Output(), "already done") {
		t.Fatalf("acknowledged handsteps: exit %d:\n%s", code, l.Output())
	}
}

func TestUpOnlyAndSkip(t *testing.T) {
	l := testlab.New(t)
	cases := map[string][]string{
		"--only=vms,host": {"host", "vms"},
		"--skip=" + strings.Join(docsOrder[1:], ","): {"bootstrap-ssh-host"},
		"--from=backup":                      {"backup", "status"},
		"--from=vlans --only=vlans,vms,host": {"vlans", "vms"},
	}
	for flags, want := range cases {
		var from, only, skip string
		for _, f := range strings.Fields(flags) {
			k, v, _ := strings.Cut(f, "=")
			switch k {
			case "--from":
				from = v
			case "--only":
				only = v
			case "--skip":
				skip = v
			}
		}
		got, err := selectStages(upStages(), from, only, skip)
		if err != nil {
			t.Errorf("%s: %v", flags, err)
			continue
		}
		var names []string
		for _, s := range got {
			names = append(names, s.name)
		}
		if !reflect.DeepEqual(names, want) {
			t.Errorf("%s: %q, want %q", flags, names, want)
		}
	}
	for _, args := range [][]string{{"--only", "vmss"}, {"--skip", "nope"}, {"--from", "hots"}, {"--skip", strings.Join(docsOrder, ",")}} {
		if code := l.Run("", append([]string{"up", "--dry-run"}, args...)...); code != 2 {
			t.Errorf("%v: exit %d", args, code)
		}
	}
	l.Run("", "up", "--only", "vmss", "--dry-run")
	if !strings.Contains(l.Output(), "Did you mean: vms") {
		t.Errorf("no suggestion:\n%s", l.Output())
	}
}

func TestUpServices(t *testing.T) {
	l := testlab.New(t)
	testlab.FakeTools(l)
	l.SetCheckOutput(testlab.RecapNoChanges)
	if code := l.Run("", "up", "pihole", "homepage", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	want := []string{"vm HOST=apps ARGS=--check --diff --tags pihole", "vm HOST=apps ARGS=--check --diff --tags homepage"}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}

	l.ResetCalls()
	l.SetCheckOutput(testlab.RecapChanges)
	if code := l.Run("y\n", "up", "gateway", "iptv"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.Output())
	}
	want = []string{"vm HOST=apps ARGS=--check --diff --tags caddy", "vm HOST=apps ARGS=--tags caddy",
		"vm HOST=ragnarok ARGS=--check --diff --tags iptv", "vm HOST=ragnarok ARGS=--tags iptv"}
	if got := l.MakeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}

	// A risky target needs its name typed, even with --yes.
	l.ResetCalls()
	if code := l.Run("", "up", "vlans", "--yes"); code != 1 || len(l.MakeCalls()) != 1 {
		t.Fatalf("risky: exit %d, calls %q", code, l.MakeCalls())
	}
	l.ResetCalls()
	if code := l.Run("vlans\n", "up", "vlans", "--yes"); code != 0 || len(l.MakeCalls()) != 2 {
		t.Fatalf("risky typed: exit %d, calls %q", code, l.MakeCalls())
	}

	// Unknown names are refused before anything runs, with suggestions.
	l.ResetCalls()
	if code := l.Run("", "up", "pihole", "homepge", "--yes"); code != 2 || !strings.Contains(l.Output(), "Did you mean: homepage") || l.MakeCalls() != nil {
		t.Fatalf("unknown: exit %d, calls %q:\n%s", code, l.MakeCalls(), l.Output())
	}
	if code := l.Run("", "up", "pihole", "--only", "vms"); code != 2 {
		t.Errorf("--only with services: exit %d", code)
	}
}
