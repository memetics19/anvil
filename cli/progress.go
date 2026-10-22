package main

import (
	"fmt"
	"io"
	"strings"
	"time"
)

// outcome is what one stage of anvil up did.
type outcome int

const (
	// outUnchanged: the check showed no changes, or the stage only reads.
	outUnchanged outcome = iota
	// outApplied: the real run ran, or a person did the step.
	outApplied
	// outSkipped: already done, or declined.
	outSkipped
	outFailed
	// outStopped: a step that needs a person stopped the run.
	outStopped
	// outNotRun: an earlier stage stopped the run.
	outNotRun
)

func (o outcome) String() string {
	return [...]string{"unchanged", "applied", "skipped", "failed", "stopped", "not run"}[o]
}

func (o outcome) paint(p palette, s string) string {
	switch o {
	case outUnchanged:
		return p.ok(s)
	case outApplied:
		return p.paint("36", s)
	case outFailed:
		return p.fail(s)
	case outStopped:
		return p.warn(s)
	}
	return p.dim(s)
}

type stageResult struct {
	name string
	out  outcome
	dur  time.Duration
}

// since is the clock for stage times. Tests fix it.
var since = time.Since

// fmtDur is a short duration: 0.4s, 12.3s, 4m05s, 1h02m.
func fmtDur(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%.1fs", d.Seconds())
	case d < time.Hour:
		return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
}

// stageHeader is the line before a stage: stage 3/24: host-network.
func stageHeader(w io.Writer, p palette, i, n int, name string) {
	fmt.Fprintf(w, "\n%s\n", p.bold(fmt.Sprintf("stage %d/%d: %s", i, n, name)))
}

// stageFooter is the line after a stage: its outcome and time.
func stageFooter(w io.Writer, p palette, i, n int, r stageResult) {
	fmt.Fprintf(w, "stage %d/%d: %s %s in %s\n", i, n, r.name, r.out.paint(p, r.out.String()), fmtDur(r.dur))
}

// printSummary is the table at the end of anvil up: every stage, its outcome and time.
func printSummary(w io.Writer, p palette, rs []stageResult, total time.Duration) {
	width := len("total")
	for _, r := range rs {
		width = max(width, len(r.name))
	}
	fmt.Fprintf(w, "\n%s\n", p.bold("anvil up: summary"))
	counts := map[outcome]int{}
	for _, r := range rs {
		counts[r.out]++
		dur := ""
		if r.out != outNotRun {
			dur = fmtDur(r.dur)
		}
		line := fmt.Sprintf("  %-*s  %s  %s", width, r.name, r.out.paint(p, fmt.Sprintf("%-9s", r.out)), dur)
		fmt.Fprintln(w, strings.TrimRight(line, " "))
	}
	var parts []string
	for o := outUnchanged; o <= outNotRun; o++ {
		if counts[o] > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", counts[o], o))
		}
	}
	fmt.Fprintf(w, "  %-*s  %-9s  %s  (%s)\n", width, "total", "", fmtDur(total), strings.Join(parts, ", "))
}
