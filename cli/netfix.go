package main

// The Mac's own routing, for anvil doctor. Away from home on the VPN, a lab address added
// by hand to the Wi-Fi (an alias) and the routes it left behind are more specific than the
// VPN's route, so lab traffic goes into the wrong network and nothing in the lab answers.
// doctor finds that, and doctor --fix removes those entries with sudo. Addresses are never
// printed: only counts and interface names.

import (
	"bufio"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
)

// The parts that touch the system. Tests replace them.
var (
	// labAddrs: the Proxmox host and Vault, from the Keychain (service homelab).
	labAddrs = func() []netip.Addr {
		var out []netip.Addr
		for _, acct := range []string{"pve-ip", "vault-ip"} {
			b, err := exec.Command("security", "find-generic-password", "-s", "homelab", "-a", acct, "-w").Output()
			if err != nil {
				continue
			}
			if a, err := netip.ParseAddr(strings.TrimSpace(string(b))); err == nil && a.Is4() {
				out = append(out, a)
			}
		}
		return out
	}
	// routeIface: the interface the Mac would use for addr (route -n get).
	routeIface = func(a netip.Addr) string {
		b, _ := exec.Command("/sbin/route", "-n", "get", a.String()).Output()
		for _, l := range strings.Split(string(b), "\n") {
			if k, v, ok := strings.Cut(strings.TrimSpace(l), ":"); ok && k == "interface" {
				return strings.TrimSpace(v)
			}
		}
		return ""
	}
	netstatRoutes = func() string {
		b, _ := exec.Command("/usr/sbin/netstat", "-rn", "-f", "inet").Output()
		return string(b)
	}
	ifconfigIface = func(iface string) string {
		b, _ := exec.Command("/sbin/ifconfig", iface).Output()
		return string(b)
	}
	// runSudo runs one command with sudo, on the terminal (sudo asks for the password).
	runSudo = func(args ...string) error {
		cmd := exec.Command("sudo", args...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return cmd.Run()
	}
)

type route struct {
	prefix netip.Prefix
	flags  string
	iface  string
}

// parseNetstat reads macOS `netstat -rn -f inet`. Destinations are abbreviated there:
// "192.0.2/24" is 192.0.2.0/24, a full address without a mask is a host route.
func parseNetstat(out string) []route {
	var rs []route
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 4 || f[0] == "default" || f[0] == "Destination" {
			continue
		}
		p, ok := parseDest(f[0])
		if !ok {
			continue
		}
		rs = append(rs, route{prefix: p, flags: f[2], iface: f[3]})
	}
	return rs
}

func parseDest(d string) (netip.Prefix, bool) {
	addr, bits, hasMask := strings.Cut(d, "/")
	parts := strings.Split(addr, ".")
	if len(parts) == 0 || len(parts) > 4 {
		return netip.Prefix{}, false
	}
	// Without a mask, a short destination covers its octets ("127" is 127.0.0.0/8) and a
	// full one is a host.
	n := 8 * len(parts)
	for len(parts) < 4 {
		parts = append(parts, "0")
	}
	a, err := netip.ParseAddr(strings.Join(parts, "."))
	if err != nil || !a.Is4() {
		return netip.Prefix{}, false
	}
	if hasMask {
		if _, err := fmt.Sscanf(bits, "%d", &n); err != nil || n < 0 || n > 32 {
			return netip.Prefix{}, false
		}
	}
	p, err := a.Prefix(n)
	return p, err == nil
}

// parseInet lists the IPv4 addresses on an interface (ifconfig), primary first.
func parseInet(out string) []netip.Prefix {
	var ps []netip.Prefix
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) < 4 || f[0] != "inet" || f[2] != "netmask" {
			continue
		}
		a, err := netip.ParseAddr(f[1])
		if err != nil {
			continue
		}
		var m uint32
		if _, err := fmt.Sscanf(f[3], "0x%x", &m); err != nil {
			continue
		}
		ones, _ := net.IPMask{byte(m >> 24), byte(m >> 16), byte(m >> 8), byte(m)}.Size()
		if p, err := a.Prefix(ones); err == nil {
			ps = append(ps, netip.PrefixFrom(a, p.Bits()))
		}
	}
	return ps
}

// shadow is what hides the VPN route on one interface: aliases in the lab range and
// the routes there that are not the VPN's.
type shadow struct {
	iface   string
	aliases []netip.Addr
	routes  []route
}

// isVPN: NetBird and other WireGuard clients on macOS are utun interfaces.
func isVPN(iface string) bool { return strings.HasPrefix(iface, "utun") }

// findShadow looks for a lab address that does not answer, that the Mac sends out a
// non-VPN interface while a VPN route also covers it. It returns nothing when every lab
// address goes through the VPN, no VPN route covers them, or the direct route works
// (at home it is right).
func findShadow() *shadow {
	addrs := labAddrs()
	if len(addrs) == 0 {
		return nil
	}
	rs := parseNetstat(netstatRoutes())
	for _, a := range addrs {
		iface := routeIface(a)
		if iface == "" || isVPN(iface) {
			continue
		}
		vpn := false
		for _, r := range rs {
			if isVPN(r.iface) && r.prefix.Contains(a) {
				vpn = true
			}
		}
		if !vpn {
			continue
		}
		// The lab range: the narrowest VPN route that covers a lab address.
		var lab netip.Prefix
		for _, r := range rs {
			if isVPN(r.iface) && r.prefix.Contains(a) && (!lab.IsValid() || r.prefix.Bits() > lab.Bits()) {
				lab = r.prefix
			}
		}
		inets := parseInet(ifconfigIface(iface))
		// A cable into the lab (the interface's own address is in the lab range) or a
		// route that works: that is home, nothing to fix.
		if len(inets) > 0 && lab.Contains(inets[0].Addr()) || pingOK(a.String()) {
			continue
		}
		s := &shadow{iface: iface}
		for i, p := range inets {
			// Never the interface's primary address: that is the network you are on.
			if i > 0 && lab.Contains(p.Addr()) {
				s.aliases = append(s.aliases, p.Addr())
			}
		}
		for _, r := range rs {
			if r.iface == iface && lab.Overlaps(r.prefix) && r.prefix.Bits() > lab.Bits() {
				s.routes = append(s.routes, r)
			}
		}
		if len(s.aliases)+len(s.routes) > 0 {
			return s
		}
	}
	return nil
}

func (s *shadow) describe() string {
	return fmt.Sprintf("%d lab address alias(es) and %d lab route(s) on %s hide the VPN's route to the lab",
		len(s.aliases), len(s.routes), s.iface)
}

// commands removes the aliases first (that also drops the routes they made), then any
// route left: networks with -net, host and cloned routes with -host.
func (s *shadow) commands() [][]string {
	var cmds [][]string
	for _, a := range s.aliases {
		cmds = append(cmds, []string{"ifconfig", s.iface, "-alias", a.String()})
	}
	for _, r := range s.routes {
		if r.prefix.Bits() == 32 {
			cmds = append(cmds, []string{"/sbin/route", "-n", "delete", "-host", r.prefix.Addr().String()})
		} else {
			cmds = append(cmds, []string{"/sbin/route", "-n", "delete", "-net", r.prefix.String()})
		}
	}
	return cmds
}

// networkFinding is doctor's line for the Mac's routing (macOS only).
func networkFinding() []finding {
	if goos != "darwin" {
		return nil
	}
	if s := findShadow(); s != nil {
		return []finding{{group: "network", lv: lvFail, text: s.describe(), fix: "anvil doctor --fix (asks for your password)"}}
	}
	return []finding{{group: "network", lv: lvOK, text: "no stale lab route hides the VPN"}}
}

// fixNetwork removes the entries after asking. It returns doctor's exit code.
func fixNetwork(a *app) int {
	if goos != "darwin" {
		fmt.Fprintln(a.stdout, "doctor --fix: only the Mac's routing has a fix, and this is not macOS")
		return 0
	}
	s := findShadow()
	if s == nil {
		fmt.Fprintln(a.stdout, "doctor --fix: nothing to fix, no stale lab route hides the VPN")
		return 0
	}
	fmt.Fprintln(a.stdout, s.describe()+".")
	fmt.Fprintln(a.stdout, "They only make sense at home. Removing them sends lab traffic through the VPN.")
	fmt.Fprintln(a.stdout, "Nothing in the lab changes. At home the VPN still reaches the lab.")
	if !askYesNo(a.stdin, a.stdout, fmt.Sprintf("Remove them now (%d sudo commands)?", len(s.commands()))) {
		fmt.Fprintln(a.stdout, "Nothing changed.")
		return 1
	}
	for _, c := range s.commands() {
		// A route may already be gone (an alias takes its routes with it): not an error.
		_ = runSudo(c...)
	}
	if left := findShadow(); left != nil {
		fmt.Fprintln(a.stdout, "doctor --fix: still found: "+left.describe())
		return 1
	}
	fmt.Fprintln(a.stdout, "doctor --fix: done, the lab is reached through the VPN")
	return 0
}
