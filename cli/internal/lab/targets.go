package lab

import (
	"errors"
	"fmt"
	"slices"
	"strings"

	"github.com/memetics19/anvil/cli/internal/run"
)

const checkDiff = "--check --diff"

// Target is something anvil can check and apply: a make target, one VM, or a service
// (a role tag in ansible/playbooks/vms.yml).
type Target struct {
	Name string
	// help says what the target touches.
	help string
	make string
	host string
	// tags are baked in, for a service.
	tags string
	// args are given to both the check and the real run.
	args string
	// checkMake runs the check instead of make (tf-plan). Empty: make.
	checkMake string
	// checkArgs make the run a dry run.
	checkArgs string
	// applyMake runs the real run instead of make (tf-apply). Empty: make.
	applyMake string
	// applyArgs turn the dry run into the real run (the switch).
	applyArgs string
	// risky targets need their name typed before the real run.
	risky bool
	// summarize reads the check's output.
	summarize func(string) Summary
	// needsHost: make vm needs HOST.
	needsHost bool
}

// labTargets are the make targets that check and apply know, in the order of
// docs/setup.md. Extra ARGS from the user go after these.
func labTargets() []Target {
	ans := func(name, help string, risky bool) Target {
		return Target{Name: name, help: help, make: name, checkArgs: checkDiff, risky: risky, summarize: ansibleSummary}
	}
	return []Target{
		ans("bootstrap-ssh", "the operator SSH key on the Proxmox host and the guests", false),
		ans("host", "the Proxmox host base: repositories, packages, time, /etc/hosts, API tokens", false),
		ans("host-network", "the Proxmox host's /etc/network/interfaces, with a timed rollback", true),
		ans("ceph", "Ceph, the S3 gateway, its bucket and users. The first real run wipes the OSD disk", false),
		{Name: "tf", help: "Terraform: the VMs and SDN, through the plan guard (tf-plan, then tf-apply)",
			make: "tf-plan", checkMake: "tf-plan", applyMake: "tf-apply", risky: true, summarize: tfSummary},
		ans("vault", "the Vault server. A restart seals it, and the role refuses one unless allowed", false),
		ans("enclave", "the secrets enclave: its firewall and SDN apply (timed rollbacks), apt cache, NTP", true),
		ans("vlans", "VLANs 10, 20 and 30: the segments firewall, gateway addresses (timed rollback), DHCP, NTP", true),
		ans("cluster", "the Proxmox cluster: the main host creates it, site.cluster.members join", true),
		{Name: "switch", help: "the Cisco switch's ports and VLANs (the check prints the planned commands)",
			make: "switch", applyArgs: "-e network_switch_apply=true", risky: true, summarize: switchSummary},
		ans("vms", "every guest play in ansible/playbooks/vms.yml", false),
		{Name: "vm", help: "one VM, every guest play for it", make: "vm", checkArgs: checkDiff, summarize: ansibleSummary, needsHost: true},
	}
}

// targetAliases are other names for lab targets.
var targetAliases = map[string]string{"tf-plan": "tf", "tf-apply": "tf", "terraform": "tf"}

// TargetNames are the lab targets and their aliases, sorted: what check, apply and up
// accept without a catalog.
func TargetNames() []string {
	set := map[string]bool{}
	for _, t := range labTargets() {
		set[t.Name] = true
	}
	for k := range targetAliases {
		set[k] = true
	}
	return sortedKeys(set)
}

func (t Target) argsFor(check bool, tags, extra string) string {
	mode := t.applyArgs
	if check {
		mode = t.checkArgs
	}
	tagArgs := ""
	if t.tags != "" {
		tagArgs = "--tags " + t.tags
	}
	userTags := ""
	if tags != "" {
		userTags = "--tags " + tags
	}
	return joinNonEmpty(" ", t.args, mode, tagArgs, userTags, extra)
}

func (t Target) cmd(mk string, check bool, tags, extra string) run.MakeCmd {
	return run.NewMake(mk, "HOST", t.host, "ARGS", t.argsFor(check, tags, extra))
}

// checkCmd is the dry run.
func (t Target) checkCmd(tags, extra string) run.MakeCmd {
	mk := t.make
	if t.checkMake != "" {
		mk = t.checkMake
	}
	return t.cmd(mk, true, tags, extra)
}

// applyCmd is the real run. For tf it takes no ARGS: tf-apply applies the saved plan.
func (t Target) applyCmd(tags, extra string) run.MakeCmd {
	if t.applyMake != "" {
		return run.NewMake(t.applyMake)
	}
	return t.cmd(t.make, false, tags, extra)
}

// forbiddenArgs are never passed: anvil adds no force flag, and the plan guard refuses
// a targeted plan.
var forbiddenArgs = []string{"--force", "-target"}

func checkExtraArgs(extra string) error {
	for _, f := range strings.Fields(extra) {
		for _, bad := range forbiddenArgs {
			if f == bad || strings.HasPrefix(f, bad+"=") {
				return fmt.Errorf("--args may not contain %s", bad)
			}
		}
	}
	return nil
}

// Resolve finds a target by name. host narrows a VM-wide or multi-host target to one VM.
func (c *Catalog) Resolve(name, host string) (Target, error) {
	if name == "" {
		return Target{}, errors.New("no target")
	}
	if a, ok := targetAliases[name]; ok {
		name = a
	}
	for _, t := range labTargets() {
		if t.Name != name {
			continue
		}
		switch {
		case t.needsHost && host == "":
			return Target{}, fmt.Errorf("%s needs --host <vm> (one of %s)", name, strings.Join(c.vms, ", "))
		case t.needsHost || (t.Name == "vms" && host != ""):
			if !slices.Contains(c.vms, host) {
				return Target{}, fmt.Errorf("unknown VM %q (one of %s)", host, strings.Join(c.vms, ", "))
			}
			return c.vmTarget(host), nil
		case host != "":
			return Target{}, fmt.Errorf("%s takes no --host", name)
		}
		return t, nil
	}
	if slices.Contains(c.vms, name) {
		if host != "" && host != name {
			return Target{}, fmt.Errorf("--host %s does not match the VM %s", host, name)
		}
		return c.vmTarget(name), nil
	}
	if s, ok := c.service(name); ok {
		return s.target(host)
	}
	return Target{}, c.unknown(name)
}

func (c *Catalog) vmTarget(vm string) Target {
	return Target{Name: vm, help: "every guest play for the VM " + vm, make: "vm", host: vm,
		checkArgs: checkDiff, summarize: ansibleSummary}
}
