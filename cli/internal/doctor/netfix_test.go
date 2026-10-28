package doctor

import (
	"net/netip"
	"reflect"
	"strings"
	"testing"

	"github.com/memetics19/anvil/cli/internal/testlab"
)

// Placeholder addresses only (RFC 5737): 198.51.100.0/24 plays the lab, 192.0.2.0/24 the
// Wi-Fi of the place you are at.
const awayNetstat = `Routing tables

Internet:
Destination        Gateway            Flags               Netif Expire
default            192.0.2.1          UGScg                 en0
127                127.0.0.1          UCS                   lo0
192.0.2/24         link#12            UCS                   en0      !
192.0.2.1/32       link#12            UCS                   en0      !
198.51/16          utun100            USc                 utun100
198.51.100/24      link#12            UCS                   en0      !
198.51.100.1/32    link#12            UCS                   en0      !
198.51.100.10      link#12            UHLWIi                en0
198.51.100.31/32   link#12            UCS                   en0      !
`

const awayIfconfig = `en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	ether 00:00:5e:00:53:01
	inet 192.0.2.20 netmask 0xffffff00 broadcast 192.0.2.255
	inet 198.51.100.31 netmask 0xffffff00 broadcast 198.51.100.255
	status: active
`

// stubNet replaces the system calls. sudo calls are recorded, and each one also takes
// the alias and the routes away from what netstat and ifconfig show next.
func stubNet(t *testing.T, routes, ifc, iface string, ping bool) *[][]string {
	t.Helper()
	oldAddrs, oldIface, oldNS, oldIfc, oldSudo, oldPing, oldOS := labAddrs, routeIface, netstatRoutes, ifconfigIface, runSudo, pingOK, goos
	t.Cleanup(func() {
		labAddrs, routeIface, netstatRoutes, ifconfigIface, runSudo, pingOK, goos =
			oldAddrs, oldIface, oldNS, oldIfc, oldSudo, oldPing, oldOS
	})
	goos = "darwin"
	labAddrs = func() []netip.Addr { return []netip.Addr{netip.MustParseAddr("198.51.100.10")} }
	routeIface = func(netip.Addr) string { return iface }
	netstatRoutes = func() string { return routes }
	ifconfigIface = func(string) string { return ifc }
	pingOK = func(string) bool { return ping }
	var ran [][]string
	runSudo = func(args ...string) error {
		ran = append(ran, args)
		// After the fix the lab address goes through the VPN.
		iface = "utun100"
		return nil
	}
	return &ran
}

func TestParseNetstat(t *testing.T) {
	rs := parseNetstat(awayNetstat)
	got := map[string]string{}
	for _, r := range rs {
		got[r.prefix.String()] = r.iface
	}
	want := map[string]string{
		"127.0.0.0/8":      "lo0",
		"192.0.2.0/24":     "en0",
		"192.0.2.1/32":     "en0",
		"198.51.0.0/16":    "utun100",
		"198.51.100.0/24":  "en0",
		"198.51.100.1/32":  "en0",
		"198.51.100.10/32": "en0",
		"198.51.100.31/32": "en0",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseNetstat:\n got %v\nwant %v", got, want)
	}
}

func TestParseInet(t *testing.T) {
	got := parseInet(awayIfconfig)
	want := []netip.Prefix{netip.MustParsePrefix("192.0.2.20/24"), netip.MustParsePrefix("198.51.100.31/24")}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseInet: got %v, want %v", got, want)
	}
}

func TestFindShadowAway(t *testing.T) {
	stubNet(t, awayNetstat, awayIfconfig, "en0", false)
	s := findShadow()
	if s == nil {
		t.Fatal("findShadow: nothing found")
	}
	want := [][]string{
		{"ifconfig", "en0", "-alias", "198.51.100.31"},
		{"/sbin/route", "-n", "delete", "-net", "198.51.100.0/24"},
		{"/sbin/route", "-n", "delete", "-host", "198.51.100.1"},
		{"/sbin/route", "-n", "delete", "-host", "198.51.100.10"},
		{"/sbin/route", "-n", "delete", "-host", "198.51.100.31"},
	}
	if got := s.commands(); !reflect.DeepEqual(got, want) {
		t.Errorf("commands:\n got %v\nwant %v", got, want)
	}
	// The Wi-Fi's own address and network are never touched.
	for _, c := range s.commands() {
		if strings.Contains(strings.Join(c, " "), "192.0.2.") {
			t.Errorf("touches the Wi-Fi: %v", c)
		}
	}
	// Only counts and the interface: no address in what doctor prints.
	if d := s.describe(); strings.Contains(d, "198.51") || d != "1 lab address alias(es) and 4 lab route(s) on en0 hide the VPN's route to the lab" {
		t.Errorf("describe: %q", d)
	}
}

func TestFindShadowNothingToFix(t *testing.T) {
	home := strings.ReplaceAll(awayIfconfig, "inet 192.0.2.20 netmask 0xffffff00 broadcast 192.0.2.255\n\t", "")
	cases := []struct {
		name, routes, ifc, iface string
		ping                     bool
	}{
		{"through the VPN", awayNetstat, awayIfconfig, "utun100", false},
		{"the direct route answers", awayNetstat, awayIfconfig, "en0", true},
		{"a cable into the lab", awayNetstat, home, "en0", false},
		{"no VPN route", strings.ReplaceAll(awayNetstat, "198.51/16          utun100            USc                 utun100\n", ""), awayIfconfig, "en0", false},
		{"no route at all", awayNetstat, awayIfconfig, "", false},
	}
	for _, tc := range cases {
		stubNet(t, tc.routes, tc.ifc, tc.iface, tc.ping)
		if s := findShadow(); s != nil {
			t.Errorf("%s: found %s", tc.name, s.describe())
		}
	}
}

func TestDoctorNetworkLine(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)
	stubNet(t, awayNetstat, awayIfconfig, "en0", false)
	l.Run("", "doctor")
	out := l.Output()
	if !strings.Contains(out, "network\n  FAIL  1 lab address alias(es) and 4 lab route(s) on en0 hide the VPN's route to the lab. Fix: anvil doctor --fix") {
		t.Errorf("doctor:\n%s", out)
	}
	if strings.Contains(out, "198.51") {
		t.Errorf("doctor printed an address:\n%s", out)
	}

	goos = "linux"
	l.Run("", "doctor")
	if strings.Contains(l.Output(), "network") {
		t.Errorf("doctor on Linux has a network line:\n%s", l.Output())
	}
}

func TestDoctorFix(t *testing.T) {
	l := newTestLab(t)
	testlab.FakeTools(l)

	ran := stubNet(t, awayNetstat, awayIfconfig, "en0", false)
	l.Run("n\n", "doctor", "--fix")
	if len(*ran) != 0 || !strings.Contains(l.Output(), "Nothing changed.") {
		t.Errorf("declined: ran %v\n%s", *ran, l.Output())
	}

	ran = stubNet(t, awayNetstat, awayIfconfig, "en0", false)
	l.Run("y\n", "doctor", "--fix")
	out := l.Output()
	if len(*ran) != 5 || (*ran)[0][0] != "ifconfig" {
		t.Errorf("accepted: ran %v", *ran)
	}
	for _, want := range []string{"Remove them now (5 sudo commands)?", "doctor --fix: done, the lab is reached through the VPN", "ok    no stale lab route hides the VPN"} {
		if !strings.Contains(out, want) {
			t.Errorf("want %q in:\n%s", want, out)
		}
	}

	ran = stubNet(t, awayNetstat, awayIfconfig, "utun100", false)
	l.Run("", "doctor", "--fix")
	if len(*ran) != 0 || !strings.Contains(l.Output(), "doctor --fix: nothing to fix") {
		t.Errorf("nothing to fix: ran %v\n%s", *ran, l.Output())
	}

	// init has no --fix.
	if code := l.Run("", "init", "--fix"); code != 2 {
		t.Errorf("init --fix: exit %d, want 2", code)
	}
}
