package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// summary is what a check run says about the real run.
type summary struct {
	// known is false when the output had nothing anvil could read.
	known   bool
	changes bool
	lines   []string
}

func (s summary) String() string {
	if !s.known {
		return "no summary found in the output; treating it as changes"
	}
	verdict := "no changes"
	if s.changes {
		verdict = "changes"
	}
	if len(s.lines) == 0 {
		return verdict
	}
	return verdict + ": " + strings.Join(s.lines, ", ")
}

var (
	ansi   = regexp.MustCompile("\x1b\\[[0-9;]*m")
	recap  = regexp.MustCompile(`(?m)^(\S+)\s*:\s*ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)`)
	tfPlan = regexp.MustCompile(`Plan: (\d+) to add, (\d+) to change, (\d+) to destroy`)
)

// ansibleSummary reads the PLAY RECAP lines. Several playbooks (make vlans) add up.
func ansibleSummary(out string) summary {
	out = ansi.ReplaceAllString(out, "")
	changed := map[string]int{}
	var order []string
	s := summary{}
	for _, m := range recap.FindAllStringSubmatch(out, -1) {
		s.known = true
		host := m[1]
		c, _ := strconv.Atoi(m[3])
		u, _ := strconv.Atoi(m[4])
		f, _ := strconv.Atoi(m[5])
		if _, seen := changed[host]; !seen {
			order = append(order, host)
		}
		changed[host] += c
		if c > 0 || u > 0 || f > 0 {
			s.changes = true
		}
	}
	for _, h := range order {
		s.lines = append(s.lines, fmt.Sprintf("%s changed=%d", h, changed[h]))
	}
	return s
}

// tfSummary reads terraform plan's verdict.
func tfSummary(out string) summary {
	out = ansi.ReplaceAllString(out, "")
	if m := tfPlan.FindStringSubmatch(out); m != nil {
		return summary{known: true, changes: true, lines: []string{fmt.Sprintf("%s to add, %s to change, %s to destroy", m[1], m[2], m[3])}}
	}
	if strings.Contains(out, "Changes to Outputs:") {
		return summary{known: true, changes: true, lines: []string{"outputs change"}}
	}
	if strings.Contains(out, "No changes.") {
		return summary{known: true}
	}
	return summary{}
}

// switchSummary reads the switch role's dry run (ansible/roles/network_switch).
func switchSummary(out string) summary {
	out = ansi.ReplaceAllString(out, "")
	if strings.Contains(out, "nothing to change") {
		return summary{known: true}
	}
	if strings.Contains(out, "Dry run, nothing sent") {
		return summary{known: true, changes: true, lines: []string{"planned switch commands above"}}
	}
	return summary{}
}
