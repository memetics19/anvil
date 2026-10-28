package lab

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/doctor"
	"github.com/memetics19/anvil/cli/internal/run"
)

// The endpoints a run needs, checked before make starts, so an unreachable lab gives a
// plain message instead of a raw Terraform or Ansible error. Addresses are never printed.
const (
	msgStateStore = "Terraform state store (Ceph S3 on the Proxmox host) is not reachable from this machine. " +
		"Check you're on the home or lab network, or connected to the VPN, then rerun."
	msgVault = "Vault (in the secrets enclave) is not reachable from this machine. " +
		"Check you're on the home or lab network, or connected to the VPN, then rerun."
	// msgLocalNetwork: macOS 15 and later give a binary started from a terminal app without
	// the Local Network permission "no route to host" for LAN addresses. terraform, vault
	// and anvil itself are such binaries. /usr/bin/ssh (so Ansible) and /sbin/ping are not.
	msgLocalNetwork = "macOS is blocking local network access for this terminal app. Open System Settings, " +
		"Privacy & Security, Local Network, and turn it on for your terminal (Terminal, iTerm, Warp, " +
		"Ghostty or your editor), then rerun."
	// msgMaybeLocalNetwork is added when anvil cannot tell the two causes apart.
	msgMaybeLocalNetwork = "If you are on that network, macOS may be blocking local network access for this " +
		"terminal app: open System Settings, Privacy & Security, Local Network, and turn it on for your " +
		"terminal (Terminal, iTerm, Warp, Ghostty or your editor), then rerun."
)

// reachTries and reachPause: an endpoint gets this many tries, this far apart. Tests
// shorten the pause. stateStorePort is the S3 port the Makefile's tf-init uses.
var (
	reachTries     = 3
	reachPause     = 3 * time.Second
	stateStorePort = "7480"
)

// canReach checks the endpoints of one make target before it runs. a.Reach replaces the
// real check in tests.
func canReach(a *app.App, r *run.Runner, makeTarget string) bool {
	if a.Reach != nil {
		return a.Reach(a, r, makeTarget)
	}
	return reachable(a, r, needsOf(makeTarget))
}

// needs says which endpoints a run uses.
type needs struct{ state, vault bool }

// needsOf is what one make target needs. Every target reads the site dict, which comes
// from Vault once Vault holds the root token (scripts/site-source.sh). Terraform also
// needs its state store.
func needsOf(makeTarget string) needs {
	n := needs{vault: true}
	switch makeTarget {
	case "tf-init":
		return needs{state: true}
	case "tf-plan", "tf-apply":
		n.state = true
	}
	return n
}

// reachScript prints PVE_IP, VAULT_ADDR, and yes when the run reads the site dict from
// Vault. anvil keeps them to itself.
const reachScript = `source scripts/env.sh >/dev/null 2>&1 || exit 90
printf '%s\n%s\n' "${PVE_IP:-}" "${VAULT_ADDR:-}"
if [ -n "${VAULT_TOKEN:-}" ] && [ "${HOMELAB_SITE_SOURCE:-}" != keychain ]; then echo yes; fi`

// retry runs ok up to reachTries times, reachPause apart.
func retry(ok func() bool) bool {
	for i := 0; i < reachTries; i++ {
		if i > 0 {
			time.Sleep(reachPause)
		}
		if ok() {
			return true
		}
	}
	return false
}

// The parts of the check that touch the system. Tests replace them.
var (
	dialTCP = func(addr string) error {
		c, err := net.DialTimeout("tcp", addr, 3*time.Second)
		if err == nil {
			c.Close()
		}
		return err
	}
	// pingOK asks /sbin/ping, which macOS lets through, whether host answers.
	pingOK = doctor.Ping
	goos   = runtime.GOOS
)

// unreachable is the message for an endpoint that did not answer. On macOS, "no route to
// host" while ping reaches the host is the Local Network permission. When ping does not
// answer either, it may still be, so the message has both hints.
func unreachable(base, addr string, err error) string {
	if goos != "darwin" || !errors.Is(err, syscall.EHOSTUNREACH) {
		return base
	}
	host, _, splitErr := net.SplitHostPort(addr)
	if splitErr == nil && pingOK(host) {
		return msgLocalNetwork
	}
	return base + " " + msgMaybeLocalNetwork
}

// hostPort is the host and port of a Vault address, or "".
func hostPort(addr string) string {
	u, err := url.Parse(addr)
	if err != nil || u.Hostname() == "" {
		return ""
	}
	port := u.Port()
	if port == "" {
		port = "8200"
	}
	return net.JoinHostPort(u.Hostname(), port)
}

// reachable checks the endpoints n names, and prints the plain message for the first
// that does not answer. A dry run checks nothing. An endpoint that answered once in this
// run is not checked again.
func reachable(a *app.App, r *run.Runner, n needs) bool {
	if r.DryRun || (!n.state && !n.vault) {
		return true
	}
	if a.Reached == nil {
		a.Reached = map[string]bool{}
	}
	if (!n.state || a.Reached["state"]) && (!n.vault || a.Reached["vault"]) {
		return true
	}
	out, code := r.Quiet(reachScript)
	if code != 0 {
		// env.sh failed (no Keychain pve-ip). make reports that itself.
		return true
	}
	lines := append(strings.Split(out, "\n"), "", "", "")
	pve, vaultAddr := strings.TrimSpace(lines[0]), strings.TrimSpace(lines[1])
	vaultInUse := strings.TrimSpace(lines[2]) == "yes"
	if n.state && !a.Reached["state"] && pve != "" {
		// A Go dial from anvil is a third-party binary like terraform, so macOS treats it
		// the same way.
		addr := net.JoinHostPort(pve, stateStorePort)
		var err error
		if !retry(func() bool { err = dialTCP(addr); return err == nil }) {
			fmt.Fprintln(a.Stderr, "anvil: "+a.Pal().Fail(unreachable(msgStateStore, addr, err)))
			return false
		}
		a.Reached["state"] = true
	}
	if n.vault && !a.Reached["vault"] && vaultInUse {
		// The vault binary, as the stages use it.
		if !retry(func() bool { return doctor.VaultReachable(r) }) {
			msg := msgVault
			if addr := hostPort(vaultAddr); addr != "" {
				msg = unreachable(msgVault, addr, dialTCP(addr))
			}
			fmt.Fprintln(a.Stderr, "anvil: "+a.Pal().Fail(msg))
			return false
		}
		a.Reached["vault"] = true
	}
	return true
}
