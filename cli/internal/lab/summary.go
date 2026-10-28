package lab

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Summary is what a check run says about the real run.
type Summary struct {
	// Known is false when the output had nothing anvil could read.
	Known   bool
	Changes bool
	Lines   []string
}

func (s Summary) String() string {
	if !s.Known {
		return "no summary found in the output; treating it as changes"
	}
	verdict := "no changes"
	if s.Changes {
		verdict = "changes"
	}
	if len(s.Lines) == 0 {
		return verdict
	}
	return verdict + ": " + strings.Join(s.Lines, ", ")
}

var (
	ansi   = regexp.MustCompile("\x1b\\[[0-9;]*m")
	recap  = regexp.MustCompile(`(?m)^(\S+)\s*:\s*ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)`)
	tfPlan = regexp.MustCompile(`Plan: (\d+) to add, (\d+) to change, (\d+) to destroy`)
)

// ansibleSummary reads the PLAY RECAP lines. Several playbooks (make vlans) add up.
func ansibleSummary(out string) Summary {
	out = ansi.ReplaceAllString(out, "")
	changed := map[string]int{}
	var order []string
	s := Summary{}
	for _, m := range recap.FindAllStringSubmatch(out, -1) {
		s.Known = true
		host := m[1]
		c, _ := strconv.Atoi(m[3])
		u, _ := strconv.Atoi(m[4])
		f, _ := strconv.Atoi(m[5])
		if _, seen := changed[host]; !seen {
			order = append(order, host)
		}
		changed[host] += c
		if c > 0 || u > 0 || f > 0 {
			s.Changes = true
		}
	}
	for _, h := range order {
		s.Lines = append(s.Lines, fmt.Sprintf("%s changed=%d", h, changed[h]))
	}
	return s
}

// tfSummary reads terraform plan's verdict.
func tfSummary(out string) Summary {
	out = ansi.ReplaceAllString(out, "")
	if m := tfPlan.FindStringSubmatch(out); m != nil {
		return Summary{Known: true, Changes: true, Lines: []string{fmt.Sprintf("%s to add, %s to change, %s to destroy", m[1], m[2], m[3])}}
	}
	if strings.Contains(out, "Changes to Outputs:") {
		return Summary{Known: true, Changes: true, Lines: []string{"outputs change"}}
	}
	if strings.Contains(out, "No changes.") {
		return Summary{Known: true}
	}
	return Summary{}
}

// switchSummary reads the switch role's dry run (ansible/roles/network_switch).
func switchSummary(out string) Summary {
	out = ansi.ReplaceAllString(out, "")
	if strings.Contains(out, "nothing to change") {
		return Summary{Known: true}
	}
	if strings.Contains(out, "Dry run, nothing sent") {
		return Summary{Known: true, Changes: true, Lines: []string{"planned switch commands above"}}
	}
	return Summary{}
}
