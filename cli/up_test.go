package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
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
	l := newTestLab(t)
	if code := l.run("", "up", "--dry-run"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	out := l.output()
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
	if strings.Contains(out, sentinelEnv) || strings.Contains(out, sentinelSource) {
		t.Errorf("printed a value:\n%s", out)
	}
	if l.makeCalls() != nil {
		t.Errorf("a dry run ran make: %q", l.makeCalls())
	}

	l.run("", "up", "--only", "vms", "--dry-run")
	if out := l.output(); !strings.Contains(out, "1 of 24 stages") || !strings.Contains(out, "make vms ARGS='--check --diff'") || strings.Contains(out, ". host ") {
		t.Errorf("--only vms:\n%s", out)
	}
}

func TestUpSkipsApplyWhenChecksShowNoChanges(t *testing.T) {
	l := newTestLab(t)
	fakeTools(l)
	l.setCheckOutput(recapNoChanges)
	if code := l.run("", "up", "--only", "host,enclave,vms", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	want := []string{"host ARGS=--skip-tags homepage --check --diff", "enclave ARGS=--check --diff", "vms ARGS=--check --diff"}
	if got := l.makeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}

	l.resetCalls()
	l.setCheckOutput(recapChanges)
	if code := l.run("", "up", "--only", "host,vms", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	want = []string{"host ARGS=--skip-tags homepage --check --diff", "host ARGS=--skip-tags homepage", "vms ARGS=--check --diff", "vms"}
	if got := l.makeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
}

func TestUpAsksOnce(t *testing.T) {
	l := newTestLab(t)
	fakeTools(l)
	l.setCheckOutput(recapChanges)
	if code := l.run("y\n", "up", "--only", "vms"); code != 1 || l.makeCalls() != nil {
		t.Fatalf("y is not up: exit %d, calls %q", code, l.makeCalls())
	}
	// One "up" covers every stage, risky ones included.
	if code := l.run("up\n", "up", "--only", "vlans,vms"); code != 0 || len(l.makeCalls()) != 4 {
		t.Fatalf("exit %d, calls %q: %s", code, l.makeCalls(), l.output())
	}
}

func TestUpStopsOnFailureAndResumes(t *testing.T) {
	l := newTestLab(t)
	fakeTools(l)
	l.setCheckOutput(recapNoChanges)
	l.env["FAKE_RC"] = "5"
	if code := l.run("", "up", "--only", "host,vms", "--yes"); code != 5 {
		t.Fatalf("exit %d, want 5", code)
	}
	if !strings.Contains(l.output(), "anvil up --from host") || len(l.makeCalls()) != 1 {
		t.Fatalf("calls %q, output:\n%s", l.makeCalls(), l.output())
	}
	delete(l.env, "FAKE_RC")
	l.resetCalls()
	if code := l.run("", "up", "--from", "vms", "--skip", "handsteps,backup", "--yes"); code != 0 {
		t.Fatalf("resume: exit %d: %s", code, l.output())
	}
	if got := l.makeCalls(); !reflect.DeepEqual(got, []string{"vms ARGS=--check --diff"}) {
		t.Fatalf("resume calls %q", got)
	}
	if !strings.Contains(l.output(), "STATUS-RAN") {
		t.Errorf("status did not run:\n%s", l.output())
	}
	st := readState(t, l)
	if !reflect.DeepEqual(st.Completed, []string{"vms", "status"}) {
		t.Errorf("state completed %q", st.Completed)
	}
}

func readState(t *testing.T, l *testLab) upState {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(l.root, stateFile))
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
	l := newTestLab(t)
	fakeTools(l)

	// Already done: the Keychain has the items.
	if code := l.run("", "up", "--only", "vault-init", "--yes"); code != 0 || !strings.Contains(l.output(), "already done") {
		t.Fatalf("done: exit %d:\n%s", code, l.output())
	}

	// Not done, --yes: stop with a resume hint instead of waiting.
	l.env["FAKE_MISSING_ITEM"] = "vault-init-json"
	if code := l.run("", "up", "--only", "vault-init,vault-unseal", "--yes"); code != exitNeedsYou {
		t.Fatalf("--yes: exit %d", code)
	}
	if out := l.output(); !strings.Contains(out, "scripts/vault-init.sh") || !strings.Contains(out, "anvil up --from vault-init") {
		t.Errorf("--yes output:\n%s", out)
	}
	if l.makeCalls() != nil {
		t.Errorf("ran past the pause: %q", l.makeCalls())
	}

	// Not done, interactive: Enter, but the item is still missing.
	if code := l.run("up\n\n", "up", "--only", "vault-init,vault-unseal"); code != exitNeedsYou || !strings.Contains(l.output(), "still not done") {
		t.Fatalf("still missing: exit %d:\n%s", code, l.output())
	}
	// q stops.
	if code := l.run("up\nq\n", "up", "--only", "vault-init"); code != exitNeedsYou {
		t.Fatalf("q: exit %d", code)
	}

	// handsteps has no probe: Enter acknowledges it once, and the state keeps that.
	delete(l.env, "FAKE_MISSING_ITEM")
	if code := l.run("up\n\n", "up", "--only", "handsteps,backup"); code != 0 {
		t.Fatalf("handsteps: exit %d:\n%s", code, l.output())
	}
	if !contains(readState(t, l).Acknowledged, "handsteps") || !reflect.DeepEqual(l.makeCalls(), []string{"backup"}) {
		t.Fatalf("state %+v, calls %q", readState(t, l), l.makeCalls())
	}
	if code := l.run("", "up", "--only", "handsteps", "--yes"); code != 0 || !strings.Contains(l.output(), "already done") {
		t.Fatalf("acknowledged handsteps: exit %d:\n%s", code, l.output())
	}
}

func TestUpOnlyAndSkip(t *testing.T) {
	l := newTestLab(t)
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
		if code := l.run("", append([]string{"up", "--dry-run"}, args...)...); code != 2 {
			t.Errorf("%v: exit %d", args, code)
		}
	}
	l.run("", "up", "--only", "vmss", "--dry-run")
	if !strings.Contains(l.output(), "Did you mean: vms") {
		t.Errorf("no suggestion:\n%s", l.output())
	}
}

func TestUpServices(t *testing.T) {
	l := newTestLab(t)
	fakeTools(l)
	l.setCheckOutput(recapNoChanges)
	if code := l.run("", "up", "pihole", "homepage", "--yes"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	want := []string{"vm HOST=apps ARGS=--check --diff --tags pihole", "vm HOST=apps ARGS=--check --diff --tags homepage"}
	if got := l.makeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}

	l.resetCalls()
	l.setCheckOutput(recapChanges)
	if code := l.run("y\n", "up", "gateway", "iptv"); code != 0 {
		t.Fatalf("exit %d: %s", code, l.output())
	}
	want = []string{"vm HOST=apps ARGS=--check --diff --tags caddy", "vm HOST=apps ARGS=--tags caddy",
		"vm HOST=ragnarok ARGS=--check --diff --tags iptv", "vm HOST=ragnarok ARGS=--tags iptv"}
	if got := l.makeCalls(); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}

	// A risky target needs its name typed, even with --yes.
	l.resetCalls()
	if code := l.run("", "up", "vlans", "--yes"); code != 1 || len(l.makeCalls()) != 1 {
		t.Fatalf("risky: exit %d, calls %q", code, l.makeCalls())
	}
	l.resetCalls()
	if code := l.run("vlans\n", "up", "vlans", "--yes"); code != 0 || len(l.makeCalls()) != 2 {
		t.Fatalf("risky typed: exit %d, calls %q", code, l.makeCalls())
	}

	// Unknown names are refused before anything runs, with suggestions.
	l.resetCalls()
	if code := l.run("", "up", "pihole", "homepge", "--yes"); code != 2 || !strings.Contains(l.output(), "Did you mean: homepage") || l.makeCalls() != nil {
		t.Fatalf("unknown: exit %d, calls %q:\n%s", code, l.makeCalls(), l.output())
	}
	if code := l.run("", "up", "pihole", "--only", "vms"); code != 2 {
		t.Errorf("--only with services: exit %d", code)
	}
}
