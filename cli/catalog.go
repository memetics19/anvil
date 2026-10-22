package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// The services come from the code, so the list cannot drift: every role tag (and task
// tag) in ansible/playbooks/vms.yml is a service, on the hosts of its play, resolved
// through ansible/inventory/hosts.yml.
const (
	playbookPath  = "ansible/playbooks/vms.yml"
	inventoryPath = "ansible/inventory/hosts.yml"
)

// serviceAliases are friendlier names for some role tags. catalog_test.go checks that
// each one points at a tag that exists.
var serviceAliases = map[string]string{
	"gateway":   "caddy",
	"pi-hole":   "pihole",
	"dashboard": "homepage",
	"unbound":   "pihole",
}

type service struct {
	name  string
	roles []string
	hosts []string
}

func (s service) target(host string) (target, error) {
	t := target{name: s.name, tags: s.name, checkArgs: checkDiff, summarize: ansibleSummary,
		help: fmt.Sprintf("tag %s (%s) on %s", s.name, strings.Join(s.roles, ", "), strings.Join(s.hosts, ", "))}
	switch {
	case host != "":
		if !contains(s.hosts, host) {
			return target{}, fmt.Errorf("%s runs on %s, not %s", s.name, strings.Join(s.hosts, ", "), host)
		}
		t.make, t.host = "vm", host
	case len(s.hosts) == 1:
		t.make, t.host = "vm", s.hosts[0]
	default:
		t.make = "vms"
	}
	return t, nil
}

type catalog struct {
	vms      []string
	services []service
}

// tagList is a YAML tags field: a list, or a comma separated string.
type tagList []string

func (t *tagList) UnmarshalYAML(n *yaml.Node) error {
	if n.Kind == yaml.ScalarNode {
		for _, s := range strings.Split(n.Value, ",") {
			if s = strings.TrimSpace(s); s != "" {
				*t = append(*t, s)
			}
		}
		return nil
	}
	var l []string
	if err := n.Decode(&l); err != nil {
		return err
	}
	*t = l
	return nil
}

// roleEntry is a play's role: a bare name, or a mapping with role and tags.
type roleEntry struct {
	Role string
	Tags tagList
}

func (r *roleEntry) UnmarshalYAML(n *yaml.Node) error {
	if n.Kind == yaml.ScalarNode {
		r.Role = n.Value
		return nil
	}
	var m struct {
		Role string  `yaml:"role"`
		Name string  `yaml:"name"`
		Tags tagList `yaml:"tags"`
	}
	if err := n.Decode(&m); err != nil {
		return err
	}
	r.Role, r.Tags = m.Role, m.Tags
	if r.Role == "" {
		r.Role = m.Name
	}
	return nil
}

type play struct {
	Name  string      `yaml:"name"`
	Hosts string      `yaml:"hosts"`
	Roles []roleEntry `yaml:"roles"`
	Tasks []struct {
		Tags tagList `yaml:"tags"`
	} `yaml:"tasks"`
}

type invGroup struct {
	Hosts    map[string]any       `yaml:"hosts"`
	Children map[string]*invGroup `yaml:"children"`
}

// inventory maps each group to its hosts, children included.
type inventory map[string]map[string]bool

func loadInventory(path string) (inventory, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var top map[string]*invGroup
	if err := yaml.Unmarshal(b, &top); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	direct := map[string]map[string]bool{}
	children := map[string][]string{}
	var walk func(name string, g *invGroup)
	walk = func(name string, g *invGroup) {
		if direct[name] == nil {
			direct[name] = map[string]bool{}
		}
		if g == nil {
			return
		}
		for h := range g.Hosts {
			direct[name][h] = true
		}
		for c, cg := range g.Children {
			children[name] = append(children[name], c)
			walk(c, cg)
		}
	}
	for name, g := range top {
		walk(name, g)
	}
	inv := inventory{}
	var resolve func(name string, seen map[string]bool) map[string]bool
	resolve = func(name string, seen map[string]bool) map[string]bool {
		out := map[string]bool{}
		if seen[name] {
			return out
		}
		seen[name] = true
		for h := range direct[name] {
			out[h] = true
		}
		for _, c := range children[name] {
			for h := range resolve(c, seen) {
				out[h] = true
			}
		}
		return out
	}
	for name := range direct {
		inv[name] = resolve(name, map[string]bool{})
	}
	return inv, nil
}

// hosts resolves a play's host pattern (names joined by ':') to host names.
func (inv inventory) hosts(pattern string) ([]string, error) {
	set := map[string]bool{}
	for _, p := range strings.Split(pattern, ":") {
		p = strings.TrimSpace(p)
		switch {
		case p == "":
		case strings.ContainsAny(p, "!&*"):
			return nil, fmt.Errorf("host pattern %q is not supported", pattern)
		case inv[p] != nil:
			for h := range inv[p] {
				set[h] = true
			}
		default:
			known := false
			for _, g := range inv {
				if g[p] {
					known = true
				}
			}
			if !known {
				return nil, fmt.Errorf("host or group %q is not in the inventory", p)
			}
			set[p] = true
		}
	}
	return sortedKeys(set), nil
}

func loadCatalog(root string) (*catalog, error) {
	inv, err := loadInventory(filepath.Join(root, inventoryPath))
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(root, playbookPath))
	if err != nil {
		return nil, err
	}
	var plays []play
	if err := yaml.Unmarshal(b, &plays); err != nil {
		return nil, fmt.Errorf("%s: %w", playbookPath, err)
	}
	hostsOf := map[string]map[string]bool{}
	rolesOf := map[string][]string{}
	vms := map[string]bool{}
	add := func(tag, role string, hosts []string) {
		if tag == "always" || tag == "never" {
			return
		}
		if hostsOf[tag] == nil {
			hostsOf[tag] = map[string]bool{}
		}
		for _, h := range hosts {
			hostsOf[tag][h] = true
		}
		if role != "" && !contains(rolesOf[tag], role) {
			rolesOf[tag] = append(rolesOf[tag], role)
		}
	}
	for _, p := range plays {
		hosts, err := inv.hosts(p.Hosts)
		if err != nil {
			return nil, fmt.Errorf("%s, play %q: %w", playbookPath, p.Name, err)
		}
		for _, h := range hosts {
			vms[h] = true
		}
		for _, r := range p.Roles {
			for _, t := range r.Tags {
				add(t, r.Role, hosts)
			}
		}
		for _, t := range p.Tasks {
			for _, tag := range t.Tags {
				add(tag, "", hosts)
			}
		}
	}
	c := &catalog{vms: sortedKeys(vms)}
	for _, tag := range sortedKeys(hostsOf) {
		roles := rolesOf[tag]
		if len(roles) == 0 {
			roles = []string{"tasks"}
		}
		c.services = append(c.services, service{name: tag, roles: roles, hosts: sortedKeys(hostsOf[tag])})
	}
	return c, nil
}

func normalize(name string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(name)), "-", "_")
}

// service finds a service by tag, role name or alias.
func (c *catalog) service(name string) (service, bool) {
	if a, ok := serviceAliases[strings.ToLower(name)]; ok {
		name = a
	}
	n := normalize(name)
	for _, s := range c.services {
		if s.name == n {
			return s, true
		}
	}
	var byRole []service
	for _, s := range c.services {
		if contains(s.roles, n) {
			byRole = append(byRole, s)
		}
	}
	if len(byRole) > 0 {
		// A role with several tags (enclave_guest: base, enclave): its most specific tag,
		// the one on the fewest hosts.
		sort.SliceStable(byRole, func(i, j int) bool { return len(byRole[i].hosts) < len(byRole[j].hosts) })
		return byRole[0], true
	}
	return service{}, false
}

// names is every name resolve accepts.
func (c *catalog) names() []string {
	set := map[string]bool{}
	for _, t := range labTargets() {
		set[t.name] = true
	}
	for a := range targetAliases {
		set[a] = true
	}
	for _, v := range c.vms {
		set[v] = true
	}
	for _, s := range c.services {
		set[s.name] = true
		for _, r := range s.roles {
			if r != "tasks" {
				set[r] = true
			}
		}
	}
	for a := range serviceAliases {
		set[a] = true
	}
	return sortedKeys(set)
}

func (c *catalog) unknown(name string) error {
	var near []string
	n := normalize(name)
	for _, cand := range c.names() {
		cn := normalize(cand)
		if levenshtein(n, cn) <= 2 || commonPrefix(n, cn) >= 5 ||
			(len(n) >= 3 && (strings.Contains(cn, n) || strings.Contains(n, cn) && len(cn) >= 3)) {
			near = append(near, cand)
		}
	}
	msg := fmt.Sprintf("unknown target or service %q", name)
	if len(near) > 0 {
		msg += ". Did you mean: " + strings.Join(near, ", ") + "?"
	}
	return fmt.Errorf("%s (anvil services lists them all)", msg)
}

func commonPrefix(a, b string) int {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] {
		i++
	}
	return i
}

func levenshtein(a, b string) int {
	prev := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		cur := make([]int, len(b)+1)
		cur[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
		}
		prev = cur
	}
	return prev[len(b)]
}
