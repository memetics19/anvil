package main

import (
	"fmt"
	"net"
	"strings"
	"time"
)

// The endpoints a run needs, checked before make starts, so an unreachable lab gives a
// plain message instead of a raw Terraform or Ansible error. Addresses are never printed.
const (
	msgStateStore = "Terraform state store (Ceph S3 on the Proxmox host) is not reachable from this machine. " +
		"Check you're on the home or lab network, or connected to the VPN, then rerun."
	msgVault = "Vault (in the secrets enclave) is not reachable from this machine. " +
		"Check you're on the home or lab network, or connected to the VPN, then rerun."
)

// reachTries and reachPause: an endpoint gets this many tries, this far apart. Tests
// shorten the pause. stateStorePort is the S3 port the Makefile's tf-init uses.
var (
	reachTries     = 3
	reachPause     = 3 * time.Second
	stateStorePort = "7480"
)

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

// reachScript prints PVE_IP, and yes when the run reads the site dict from Vault.
const reachScript = `source scripts/env.sh >/dev/null 2>&1 || exit 90
printf '%s\n' "${PVE_IP:-}"
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

func tcpOpen(addr string) bool {
	c, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// reachable checks the endpoints n names, and prints the plain message for the first
// that does not answer. A dry run checks nothing. An endpoint that answered once in this
// run is not checked again.
func reachable(a *app, r *runner, n needs) bool {
	if r.dryRun || (!n.state && !n.vault) {
		return true
	}
	if a.reached == nil {
		a.reached = map[string]bool{}
	}
	if (!n.state || a.reached["state"]) && (!n.vault || a.reached["vault"]) {
		return true
	}
	out, code := r.quiet(reachScript)
	if code != 0 {
		// env.sh failed (no Keychain pve-ip). make reports that itself.
		return true
	}
	lines := strings.Split(out, "\n")
	pve := strings.TrimSpace(lines[0])
	vaultInUse := len(lines) > 1 && strings.TrimSpace(lines[1]) == "yes"
	if n.state && !a.reached["state"] && pve != "" {
		if !retry(func() bool { return tcpOpen(net.JoinHostPort(pve, stateStorePort)) }) {
			fmt.Fprintln(a.stderr, "anvil: "+msgStateStore)
			return false
		}
		a.reached["state"] = true
	}
	if n.vault && !a.reached["vault"] && vaultInUse {
		if !retry(func() bool { return parseVaultStatus(r.quiet(vaultStatusScript)).reachable }) {
			fmt.Fprintln(a.stderr, "anvil: "+msgVault)
			return false
		}
		a.reached["vault"] = true
	}
	return true
}
