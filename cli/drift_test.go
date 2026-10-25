package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

type ntfyMsg struct{ title, tags, auth, body string }

// fakeNtfy records what anvil drift posts.
func fakeNtfy(t *testing.T, l *testLab) *[]ntfyMsg {
	t.Helper()
	var mu sync.Mutex
	var got []ntfyMsg
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, ntfyMsg{r.Header.Get("Title"), r.Header.Get("Tags"), r.Header.Get("Authorization"), string(b)})
		mu.Unlock()
	}))
	t.Cleanup(srv.Close)
	l.env["ANVIL_NTFY_URL"] = srv.URL + "/lab"
	l.env["ANVIL_NTFY_TOKEN"] = "tk_" + sentinelEnv
	return &got
}

const tfNoChanges = "No changes. Your infrastructure matches the configuration.\n"

func TestDriftQuietWhenNothingChanged(t *testing.T) {
	l := newTestLab(t)
	got := fakeNtfy(t, l)
	l.setCheckOutput(recapNoChanges + tfNoChanges)
	if code := l.run("", "drift"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.output())
	}
	if want := []string{"host ARGS=--check --diff", "vms ARGS=--check --diff", "tf-plan"}; strings.Join(l.makeCalls(), "|") != strings.Join(want, "|") {
		t.Errorf("make calls %q", l.makeCalls())
	}
	if len(*got) != 0 {
		t.Errorf("sent %v", *got)
	}
	if code := l.run("", "drift", "--always"); code != 0 || len(*got) != 1 || (*got)[0].title != "anvil: no drift" {
		t.Errorf("--always: exit %d, sent %v", code, *got)
	}
}

func TestDriftSendsChanges(t *testing.T) {
	l := newTestLab(t)
	got := fakeNtfy(t, l)
	l.setCheckOutput(recapChanges + "frigate : ok=3 changed=0 unreachable=0 failed=0\nPlan: 1 to add, 0 to change, 0 to destroy.\n")
	if code := l.run("", "drift"); code != 1 {
		t.Fatalf("exit %d, want 1:\n%s", code, l.output())
	}
	if len(*got) != 1 {
		t.Fatalf("sent %v", *got)
	}
	m := (*got)[0]
	if m.title != "anvil: the lab drifted" || m.tags != "warning" || m.auth != "Bearer tk_"+sentinelEnv {
		t.Errorf("message %+v", m)
	}
	for _, want := range []string{"vms: changes: apps changed=2\n", "tf: changes: 1 to add, 0 to change, 0 to destroy"} {
		if !strings.Contains(m.body, want) {
			t.Errorf("want %q in body:\n%s", want, m.body)
		}
	}
	if strings.Contains(m.body, "frigate") {
		t.Errorf("a VM without changes is in the message:\n%s", m.body)
	}
	if strings.Contains(l.output(), sentinelEnv) {
		t.Errorf("the token is in the output:\n%s", l.output())
	}
}

func TestDriftSendsFailures(t *testing.T) {
	l := newTestLab(t)
	got := fakeNtfy(t, l)
	l.env["FAKE_RC"] = "2"
	if code := l.run("", "drift"); code != 1 {
		t.Fatalf("exit %d", code)
	}
	if len(*got) != 1 || (*got)[0].title != "anvil: drift check failed" || !strings.Contains((*got)[0].body, "tf: the check failed (exit 2)") {
		t.Errorf("sent %v", *got)
	}
}

func TestDriftWithoutNtfyOnlyPrints(t *testing.T) {
	l := newTestLab(t)
	l.setCheckOutput(recapChanges + tfNoChanges)
	if code := l.run("", "drift"); code != 1 || !strings.Contains(l.output(), "ntfy is not set up") {
		t.Errorf("exit %d:\n%s", code, l.output())
	}
}

func TestDriftLogKeepsSevenRuns(t *testing.T) {
	l := newTestLab(t)
	l.setCheckOutput(recapNoChanges + tfNoChanges)
	log := filepath.Join(t.TempDir(), "logs", "drift.log")
	for i := 0; i < 9; i++ {
		l.run("", "drift", "--log", log)
	}
	b, err := os.ReadFile(log)
	if err != nil || !strings.Contains(string(b), "anvil drift:\nhost: no changes") {
		t.Fatalf("log: %v\n%s", err, b)
	}
	if fi, _ := os.Stat(log); fi.Mode().Perm() != 0o600 {
		t.Errorf("log mode %v", fi.Mode().Perm())
	}
	if _, err := os.Stat(log + ".7"); err != nil {
		t.Errorf("no .7: %v", err)
	}
	if _, err := os.Stat(log + ".8"); err == nil {
		t.Errorf("kept more than 7")
	}
}

func TestDriftInstall(t *testing.T) {
	l := newTestLab(t)
	home := l.env["HOME"]
	var ran []string
	oldSched, oldOS := runSched, goos
	t.Cleanup(func() { runSched, goos = oldSched, oldOS })
	runSched = func(name string, args ...string) error {
		ran = append(ran, name+" "+strings.Join(args, " "))
		return nil
	}

	goos = "darwin"
	if code := l.run("", "drift", "--install", "--at", "4:05"); code != 0 {
		t.Fatalf("exit %d:\n%s", code, l.output())
	}
	b, err := os.ReadFile(filepath.Join(home, "Library", "LaunchAgents", driftLabel+".plist"))
	if err != nil {
		t.Fatal(err)
	}
	plist := string(b)
	for _, want := range []string{"<string>drift</string><string>--log</string>", "<integer>4</integer>", "<integer>5</integer>",
		"<key>ANVIL_REPO</key><string>" + l.root + "</string>", filepath.Join(home, "Library", "Logs", "anvil", "drift.log")} {
		if !strings.Contains(plist, want) {
			t.Errorf("want %q in plist:\n%s", want, plist)
		}
	}
	if len(ran) != 2 || !strings.HasPrefix(ran[1], "launchctl bootstrap gui/") {
		t.Errorf("ran %q", ran)
	}
	if !strings.Contains(l.output(), "every night at 04:05") {
		t.Errorf("output:\n%s", l.output())
	}

	ran = nil
	goos = "linux"
	if code := l.run("", "drift", "--install"); code != 0 {
		t.Fatalf("linux: exit %d:\n%s", code, l.output())
	}
	tmr, _ := os.ReadFile(filepath.Join(home, ".config", "systemd", "user", "anvil-drift.timer"))
	svc, _ := os.ReadFile(filepath.Join(home, ".config", "systemd", "user", "anvil-drift.service"))
	if !strings.Contains(string(tmr), "OnCalendar=*-*-* 03:30:00\nPersistent=true") || !strings.Contains(string(svc), `drift --log "`) {
		t.Errorf("units:\n%s\n%s", tmr, svc)
	}
	if strings.Join(ran, "|") != "systemctl --user daemon-reload|systemctl --user enable --now anvil-drift.timer" {
		t.Errorf("ran %q", ran)
	}

	if code := l.run("", "drift", "--uninstall"); code != 0 {
		t.Fatalf("uninstall: exit %d", code)
	}
	if _, err := os.Stat(filepath.Join(home, ".config", "systemd", "user", "anvil-drift.timer")); err == nil {
		t.Errorf("the timer is still there")
	}

	if code := l.run("", "drift", "--install", "--at", "25:00"); code != 2 {
		t.Errorf("--at 25:00: exit %d, want 2", code)
	}
}
