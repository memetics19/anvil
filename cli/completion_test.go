package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestCompletionScriptsHoldTheNames(t *testing.T) {
	l := newTestLab(t)
	for _, sh := range []string{"bash", "zsh", "fish"} {
		if code := l.run("", "completion", sh); code != 0 {
			t.Fatalf("%s: exit %d:\n%s", sh, code, l.output())
		}
		out := l.out.String()
		// Services from the playbook, an alias, a VM, a lab target, commands, stages, flags.
		for _, want := range []string{"pihole", "caddy", "homepage", "gateway", "apps", "vlans",
			"doctor", "fetch", "completion", "vault-unseal", "dry-run", "no-color", "anvil completion names"} {
			if !strings.Contains(out, want) {
				t.Errorf("%s: missing %q", sh, want)
			}
		}
	}
	l.run("", "completion", "names")
	names := strings.Split(strings.TrimSpace(l.out.String()), "\n")
	for _, want := range []string{"pihole", "arr_stack", "apps", "tf"} {
		if !contains(names, want) {
			t.Errorf("names: missing %q in %q", want, names)
		}
	}
	if code := l.run("", "completion", "tcsh"); code != 2 {
		t.Errorf("tcsh: exit %d", code)
	}

	// Without a repo: the lab targets only, and no error.
	l.cwd(t.TempDir())
	if code := l.run("", "completion", "names"); code != 0 || !strings.Contains(l.out.String(), "vlans\n") || strings.Contains(l.out.String(), "pihole") {
		t.Errorf("no repo: exit %d:\n%s", code, l.output())
	}
}

func TestCompletionFlagsComeFromUsage(t *testing.T) {
	c, _ := findCommand("check")
	if got, want := commandFlags(c), []string{"--args", "--dry-run", "--help", "--host", "--no-color", "--tags"}; !reflect.DeepEqual(got, want) {
		t.Errorf("check flags %q, want %q", got, want)
	}
	c, _ = findCommand("up")
	if got := commandFlags(c); !contains(got, "--from") || !contains(got, "--yes") || contains(got, "--check") {
		t.Errorf("up flags %q", got)
	}
}

// completionScript writes anvil completion <sh> to a file.
func completionScript(t *testing.T, sh string) string {
	l := newTestLab(t)
	if code := l.run("", "completion", sh); code != 0 {
		t.Fatalf("exit %d", code)
	}
	p := filepath.Join(t.TempDir(), "anvil."+sh)
	if err := os.WriteFile(p, l.out.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestZshCompletionWorks sources the script in a real zsh, checks compdef registered it,
// and calls it the way the completion system does, with compadd recording the matches.
func TestZshCompletionWorks(t *testing.T) {
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("no zsh")
	}
	script := completionScript(t, "zsh")
	dir := t.TempDir()
	prog := `autoload -U compinit && compinit -u -d "$DIR/zcompdump"
source "$SCRIPT" || exit 9
[[ $_comps[anvil] == _anvil ]] || { echo "not registered: $_comps[anvil]"; exit 8 }
compadd() { print -r -- "compadd $*" }
_describe() { print -r -- "describe ${(P)2}" }
complete() { words=("$@"); CURRENT=$#; print -r -- "== $*"; _anvil }
complete anvil ''
complete anvil up ''
complete anvil up --from ''
complete anvil check --
complete anvil completion ''
anvil() { [[ $1 == completion && $2 == names ]] && print -l livename }
complete anvil apply ''
`
	cmd := exec.Command(zsh, "-f", "-c", prog)
	cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + dir, "DIR=" + dir, "SCRIPT=" + script}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("zsh: %v\n%s", err, out)
	}
	got := string(out)
	sections := strings.Split(got, "== ")
	if len(sections) != 7 {
		t.Fatalf("zsh output:\n%s", got)
	}
	for i, want := range []string{"",
		"describe up:build or converge",  // commands with their summaries
		"compadd -- ",                    // up: names, from the script (no anvil on PATH)
		"compadd -- bootstrap-ssh-host",  // --from: stages
		"compadd -- --args --dry-run",    // check's flags
		"compadd -- bash zsh fish names", // completion's shells
		"compadd -- livename",            // names from anvil at completion time
	} {
		if !strings.Contains(sections[i], want) {
			t.Errorf("section %d: missing %q in %q", i, want, sections[i])
		}
	}
	if !strings.Contains(sections[2], " pihole ") || !strings.Contains(sections[2], " caddy ") {
		t.Errorf("up: no service names in %q", sections[2])
	}
}

func TestBashCompletionWorks(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash")
	}
	script := completionScript(t, "bash")
	prog := `source "$SCRIPT" || exit 9
complete -p anvil | grep -q _anvil || exit 8
c() { COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); COMPREPLY=(); _anvil; echo "== ${COMPREPLY[*]}"; }
c anvil do
c anvil up pi
c anvil up --only vault-
c anvil apply --y
`
	cmd := exec.Command(bash, "--norc", "--noprofile", "-c", prog)
	cmd.Env = []string{"PATH=/usr/bin:/bin", "SCRIPT=" + script}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bash: %v\n%s", err, out)
	}
	want := "== doctor\n== pi-hole pihole\n== vault-init vault-unseal vault-policies\n== --yes\n"
	if string(out) != want {
		t.Errorf("bash completions:\n%s\nwant:\n%s", out, want)
	}
}

func TestFishCompletionParses(t *testing.T) {
	fish, err := exec.LookPath("fish")
	if err != nil {
		t.Skip("no fish")
	}
	if out, err := exec.Command(fish, "--no-execute", completionScript(t, "fish")).CombinedOutput(); err != nil {
		t.Fatalf("fish: %v\n%s", err, out)
	}
}
