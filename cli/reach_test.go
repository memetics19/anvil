package main

import (
	"net"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

// freePort returns a local port with nothing listening on it.
func freePort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	ln.Close()
	return port
}

func TestUnreachableEndpointsStopBeforeMake(t *testing.T) {
	l := newTestLab(t)
	fakeTools(l)
	l.realReach = true
	l.write("scripts/env.sh", "export PVE_IP=127.0.0.1\n")
	oldPort, oldPause := stateStorePort, reachPause
	t.Cleanup(func() { stateStorePort, reachPause = oldPort, oldPause })
	reachPause = 10 * time.Millisecond

	// The state store is closed: no Terraform runs, from check tf or from up's tf-init.
	stateStorePort = freePort(t)
	for _, args := range [][]string{{"check", "tf"}, {"up", "--only", "tf-init", "--yes"}} {
		l.resetCalls()
		if code := l.run("", args...); code == 0 || l.makeCalls() != nil {
			t.Fatalf("%v: exit %d, calls %q", args, code, l.makeCalls())
		}
		if !strings.Contains(l.output(), msgStateStore) || strings.Contains(l.output(), "127.0.0.1") {
			t.Errorf("%v output:\n%s", args, l.output())
		}
	}

	// Open: the same commands run.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	_, stateStorePort, _ = net.SplitHostPort(ln.Addr().String())
	l.resetCalls()
	l.setCheckOutput("No changes.\n")
	if code := l.run("", "check", "tf"); code != 0 || len(l.makeCalls()) != 1 {
		t.Fatalf("open: exit %d, calls %q:\n%s", code, l.makeCalls(), l.output())
	}

	// Vault is in use (VAULT_TOKEN is set) and does not answer: nothing runs.
	l.env["FAKE_VAULT_RC"], l.env["FAKE_VAULT_JSON"] = "1", ""
	l.resetCalls()
	if code := l.run("", "check", "apps"); code == 0 || l.makeCalls() != nil || !strings.Contains(l.output(), msgVault) {
		t.Fatalf("vault closed: exit %d, calls %q:\n%s", code, l.makeCalls(), l.output())
	}
	// Without the root token the site comes from the Keychain, so Vault is not needed.
	delete(l.env, "VAULT_TOKEN")
	l.setCheckOutput(recapNoChanges)
	if code := l.run("", "check", "apps"); code != 0 {
		t.Fatalf("no token: exit %d:\n%s", code, l.output())
	}
	l.env["VAULT_TOKEN"] = sentinelEnv
	delete(l.env, "FAKE_VAULT_RC")
	delete(l.env, "FAKE_VAULT_JSON")
	l.resetCalls()
	if code := l.run("", "check", "apps"); code != 0 || len(l.makeCalls()) != 1 {
		t.Fatalf("vault open: exit %d, calls %q:\n%s", code, l.makeCalls(), l.output())
	}
}

func TestLocalNetworkPermissionHint(t *testing.T) {
	oldDial, oldPing, oldOS := dialTCP, pingOK, goos
	t.Cleanup(func() { dialTCP, pingOK, goos = oldDial, oldPing, oldOS })
	noRoute := &net.OpError{Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", syscall.EHOSTUNREACH)}
	refused := &net.OpError{Op: "dial", Net: "tcp", Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)}
	var pinged string
	cases := []struct {
		os   string
		err  error
		ping bool
		want string
	}{
		// macOS, no route, but ping answers: the Local Network permission.
		{"darwin", noRoute, true, msgLocalNetwork},
		// macOS, no route, and ping does not answer either: both hints.
		{"darwin", noRoute, false, msgStateStore + " " + msgMaybeLocalNetwork},
		// Refused is the endpoint itself, not the permission.
		{"darwin", refused, true, msgStateStore},
		// Linux has no such permission.
		{"linux", noRoute, true, msgStateStore},
	}
	for _, tc := range cases {
		goos = tc.os
		pingOK = func(h string) bool { pinged = h; return tc.ping }
		if got := unreachable(msgStateStore, "192.0.2.10:7480", tc.err); got != tc.want {
			t.Errorf("%s %v ping=%v:\n got %q\nwant %q", tc.os, tc.err, tc.ping, got, tc.want)
		}
	}
	if pinged != "192.0.2.10" {
		t.Errorf("pinged %q", pinged)
	}

	// Through anvil: the dial fails with no route, ping answers. Vault too, from VAULT_ADDR.
	l := newTestLab(t)
	fakeTools(l)
	l.realReach = true
	l.write("scripts/env.sh", "export PVE_IP=192.0.2.10 VAULT_ADDR=https://192.0.2.20:8200\n")
	oldPause := reachPause
	t.Cleanup(func() { reachPause = oldPause })
	reachPause = time.Millisecond
	goos = "darwin"
	var dialed []string
	dialTCP = func(addr string) error { dialed = append(dialed, addr); return noRoute }
	pingOK = func(string) bool { return true }
	if code := l.run("", "check", "tf"); code == 0 || l.makeCalls() != nil || !strings.Contains(l.output(), msgLocalNetwork) {
		t.Fatalf("state store: exit %d, calls %q:\n%s", code, l.makeCalls(), l.output())
	}
	if len(dialed) != 3 || dialed[0] != "192.0.2.10:7480" {
		t.Errorf("dialed %q", dialed)
	}
	l.env["FAKE_VAULT_RC"], l.env["FAKE_VAULT_JSON"] = "1", ""
	dialed = nil
	if code := l.run("", "check", "apps"); code == 0 || !strings.Contains(l.output(), msgLocalNetwork) || !contains(dialed, "192.0.2.20:8200") {
		t.Fatalf("vault: exit %d, dialed %q:\n%s", code, dialed, l.output())
	}
	if strings.Contains(l.output(), "192.0.2") {
		t.Errorf("printed an address:\n%s", l.output())
	}
}
