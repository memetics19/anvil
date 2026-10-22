package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const statusUsage = `usage: anvil status

A read-only dashboard. It marks the problems and ends with a count of them:

  vault         sealed or unsealed
  site source   vault or keychain, and whether the Keychain copy is stale
  git           the branch, ahead or behind its upstream (as of the last fetch)
  gateway       each gateway name in site.services, with the HTTP status of
                https://<name>.<gateway domain>/ (000: no connection)
  pi-hole       whether it answers DNS on the apps VM's home address
  backups       the age of the newest file of each kind in ~/homelab-backups

A problem is Vault not unsealed, a gateway name with 000 or a 5xx, Pi-hole not
answering, or a backup that is missing or over 36h old. The exit code is 0 either way.

It prints names only: no secrets, no addresses, no domain.
`

func init() {
	register(command{"status", "a read-only dashboard of the lab", statusUsage, cmdStatus, 11})
}

// statusScript sources env.sh once and hands anvil what it needs as JSON on a pipe.
// env.sh's messages hold no values. The site dict stays inside anvil.
const statusScript = `t=$(mktemp) || exit 1
trap 'rm -f "$t"' EXIT
source scripts/env.sh >/dev/null 2>"$t"
envrc=$?
stale=false
grep -q 'is stale' "$t" && stale=true
used=${HOMELAB_SITE_USED:-}
vs=$(VAULT_CLIENT_TIMEOUT=5 VAULT_MAX_RETRIES=0 vault status -format=json 2>/dev/null)
vrc=$?
site=${TF_VAR_site_json:-}
if [ -z "$site" ] && [ "$envrc" -eq 0 ]; then
  HOMELAB_SITE_SOURCE=keychain source scripts/env.sh >/dev/null 2>&1
  site=${TF_VAR_site_json:-}
fi
jq -n --arg used "$used" --argjson stale "$stale" --argjson envrc "$envrc" \
  --argjson vrc "$vrc" --arg vault "$vs" --arg site "$site" \
  '{used: $used, stale: $stale, envrc: $envrc, vrc: $vrc, vault: $vault, site: $site}'
`

type statusData struct {
	Used  string `json:"used"`
	Stale bool   `json:"stale"`
	EnvRC int    `json:"envrc"`
	VRC   int    `json:"vrc"`
	Vault string `json:"vault"`
	Site  string `json:"site"`
}

type siteDict struct {
	Domain  string `json:"domain"`
	Gateway struct {
		Subdomain string `json:"subdomain"`
	} `json:"gateway"`
	Services []struct {
		Name    string `json:"name"`
		Enabled any    `json:"enabled"`
	} `json:"services"`
	Hosts struct {
		Apps struct {
			HomeIP string `json:"home_ip"`
		} `json:"apps"`
	} `json:"hosts"`
}

// gatewayDomain is ansible/inventory/group_vars/all/gateway.yml in Go.
func (s siteDict) gatewayDomain() string {
	if s.Gateway.Subdomain != "" {
		return s.Gateway.Subdomain + "." + s.Domain
	}
	return s.Domain
}

func (s siteDict) gatewayNames() []string {
	var names []string
	for _, svc := range s.Services {
		if svc.Name == "" {
			continue
		}
		switch e := svc.Enabled.(type) {
		case bool:
			if !e {
				continue
			}
		case string:
			if strings.EqualFold(e, "false") || strings.EqualFold(e, "no") {
				continue
			}
		}
		names = append(names, svc.Name)
	}
	return names
}

// httpStatus is the status code of GET url, or 0 without an answer. Redirects are not
// followed: their code is the answer. The error is dropped, because it names the host.
func httpStatus(url string) int {
	client := &http.Client{
		Timeout:       8 * time.Second,
		Transport:     &http.Transport{Proxy: nil, TLSHandshakeTimeout: 5 * time.Second},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := client.Get(url)
	if err != nil {
		return 0
	}
	resp.Body.Close()
	return resp.StatusCode
}

// dnsAnswers asks server (port 53) for name. An answer of "no such host" counts.
func dnsAnswers(server, name string) bool {
	r := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
		d := net.Dialer{Timeout: 3 * time.Second}
		return d.DialContext(ctx, network, net.JoinHostPort(server, "53"))
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := r.LookupHost(ctx, name)
	var de *net.DNSError
	return err == nil || (errors.As(err, &de) && de.IsNotFound)
}

// checks reach the network. Tests replace them.
var (
	statusHTTP = httpStatus
	statusDNS  = dnsAnswers
)

func ago(d time.Duration) string {
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	}
	return fmt.Sprintf("%dd ago", int(d.Hours()/24))
}

func gitState(r *runner) string {
	branch, code := r.quiet("git rev-parse --abbrev-ref HEAD 2>/dev/null")
	if code != 0 {
		return "not a git checkout"
	}
	branch = strings.TrimSpace(branch)
	// Its upstream, else origin/<branch>, else origin's default branch.
	up := ""
	for _, ref := range []string{"@{upstream}", "origin/" + branch, "origin/HEAD"} {
		if out, code := r.quiet("git rev-parse --abbrev-ref " + shellQuote(ref) + " 2>/dev/null"); code == 0 {
			up = strings.TrimSpace(out)
			break
		}
	}
	if up == "" {
		return branch + ", no upstream and no origin"
	}
	counts, _ := r.quiet("git rev-list --left-right --count " + shellQuote("HEAD..."+up) + " 2>/dev/null")
	f := strings.Fields(counts)
	if len(f) != 2 {
		return branch
	}
	return fmt.Sprintf("%s, %s ahead and %s behind %s (as of the last fetch)", branch, f[0], f[1], up)
}

// staleAfter: a backup older than this is a problem. make backup runs daily.
const staleAfter = 36 * time.Hour

type backupAge struct {
	kind  string
	age   time.Duration
	found bool
}

func (b backupAge) String() string {
	if !b.found {
		return "none"
	}
	return ago(b.age)
}

func (b backupAge) stale() bool { return !b.found || b.age > staleAfter }

func backupAges(home string, now time.Time) []backupAge {
	dir := filepath.Join(home, "homelab-backups")
	var out []backupAge
	for _, k := range [][2]string{{"tfstate", "tfstate-*.json.age"}, {"vault", "vault-*.snap"}, {"vaultwarden", "vaultwarden-*.tar.age"}} {
		files, _ := filepath.Glob(filepath.Join(dir, k[1]))
		var newest time.Time
		for _, f := range files {
			if fi, err := os.Stat(f); err == nil && fi.ModTime().After(newest) {
				newest = fi.ModTime()
			}
		}
		b := backupAge{kind: k[0], found: !newest.IsZero()}
		if b.found {
			b.age = now.Sub(newest)
		}
		out = append(out, b)
	}
	return out
}

// gatewayNote is the problem a gateway status code shows, or "".
func gatewayNote(code int) string {
	switch {
	case code == 0:
		return "no connection"
	case code >= 500:
		return "server error"
	}
	return ""
}

// printStatus prints the dashboard and marks the problems: Vault not unsealed, a gateway
// name with no connection or a 5xx, Pi-hole not answering, a backup over 36h old. It
// never prints a value from the site dict other than the gateway names.
func printStatus(a *app, r *runner) int {
	w := a.stdout
	p := a.pal()
	var problems []string
	row := func(indent bool, name, value string, problem bool) {
		format := "%-13s %s\n"
		if indent {
			format = "  %-11s %s\n"
		}
		if problem {
			value = p.fail(value)
		}
		fmt.Fprintf(w, format, name, value)
	}
	raw, code := r.quiet(statusScript)
	var d statusData
	if code != 0 || json.Unmarshal([]byte(raw), &d) != nil {
		fmt.Fprintln(a.stderr, "anvil: status could not run scripts/env.sh and vault (is jq installed?)")
		return 1
	}
	v := parseVaultStatus(d.Vault, d.VRC)
	if d.EnvRC != 0 {
		v = vaultState{}
	}
	vf := vaultFinding(v)
	if vf.lv == lvFail {
		problems = append(problems, "vault")
		row(false, "vault", v.String()+". Fix: "+vf.fix, true)
	} else {
		row(false, "vault", p.ok(v.String()), false)
	}

	src := d.Used
	switch {
	case d.EnvRC != 0:
		src = "unknown, scripts/env.sh failed (Keychain pve-ip)"
	case src == "":
		src = "none: Vault is sealed or unreachable, and the run would stop (HOMELAB_SITE_SOURCE=keychain overrides)"
	case src == "vault" && d.Stale:
		src = "vault, the Keychain copy is stale (scripts/site-to-keychain.sh --yes)"
	case src == "vault":
		src = "vault, the Keychain copy is current"
	}
	row(false, "site source", src, false)
	row(false, "git", gitState(r), false)

	var site siteDict
	haveSite := d.Site != "" && json.Unmarshal([]byte(d.Site), &site) == nil && site.Domain != ""
	if !haveSite {
		row(false, "gateway", "unknown, no site dict", false)
		row(false, "pi-hole", "unknown, no site dict", false)
	} else {
		names := site.gatewayNames()
		codes := make([]int, len(names))
		var wg sync.WaitGroup
		for i, n := range names {
			wg.Add(1)
			go func() {
				defer wg.Done()
				codes[i] = statusHTTP("https://" + n + "." + site.gatewayDomain() + "/")
			}()
		}
		wg.Wait()
		row(false, "gateway", "HTTPS status per name (000: no connection)", false)
		for i, n := range names {
			note := gatewayNote(codes[i])
			if note == "" {
				row(true, n, fmt.Sprintf("%03d", codes[i]), false)
				continue
			}
			problems = append(problems, "gateway "+n)
			row(true, n, fmt.Sprintf("%03d  %s", codes[i], note), true)
		}
		pihole, bad := "unknown, site.hosts.apps.home_ip is not set", false
		if ip := site.Hosts.Apps.HomeIP; ip != "" {
			pihole, bad = "not answering", true
			probe := site.gatewayDomain()
			if len(names) > 0 {
				probe = names[0] + "." + probe
			}
			if statusDNS(ip, probe) {
				pihole, bad = "answering", false
			}
		}
		if bad {
			problems = append(problems, "pi-hole")
		}
		row(false, "pi-hole", pihole, bad)
	}

	row(false, "backups", "newest in ~/homelab-backups", false)
	for _, b := range backupAges(a.getenv("HOME"), time.Now()) {
		if b.stale() {
			problems = append(problems, "backup "+b.kind)
			row(true, b.kind, b.String()+", stale (over 36h)", true)
			continue
		}
		row(true, b.kind, b.String(), false)
	}
	if len(problems) == 0 {
		fmt.Fprintln(w, p.ok("status: no problems"))
	} else {
		fmt.Fprintln(w, p.fail(fmt.Sprintf("status: %d problem(s): %s", len(problems), strings.Join(problems, ", "))))
	}
	return 0
}

func cmdStatus(a *app, args []string) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	if _, code, ok := a.flags(fs, statusUsage, args); !ok {
		return code
	}
	r, ok := a.runner(false)
	if !ok {
		return 1
	}
	return printStatus(a, r)
}
