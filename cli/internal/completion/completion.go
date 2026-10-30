// Package completion prints anvil's bash, zsh and fish completion scripts (anvil
// completion). The names come from the command registry, the catalog and anvil up's stages.
package completion

import (
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strings"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/lab"
	"github.com/memetics19/anvil/cli/internal/repo"
)

const completionUsage = `usage: anvil completion bash|zsh|fish
       anvil completion names

Prints a shell completion script. It completes the commands, their options, the
targets and services of check, apply and up (from the catalog), the stages after
--from, --only and --skip, and the parts of restore and help.

  bash   source <(anvil completion bash)       or save it in bash-completion's dir
  zsh    source <(anvil completion zsh)        or save it as _anvil in your $fpath
  fish   anvil completion fish | source        or save it in ~/.config/fish/completions

The names are read at completion time with anvil completion names, so they follow the
repo. The script also holds the names known when it was made, for when no repo is found.
The packages install the scripts for you.
`

func init() {
	app.Register(app.Command{Name: "completion", Summary: "print a bash, zsh or fish completion script", Usage: completionUsage, Run: cmdCompletion, Order: 92})
}

// nameCommands take a target or service name.
var nameCommands = []string{"check", "apply", "up"}

// subWords are the fixed first arguments of some commands.
func subWords() map[string][]string {
	var cmds []string
	for _, c := range app.Commands() {
		cmds = append(cmds, c.Name)
	}
	return map[string][]string{
		"help":       cmds,
		"completion": {"bash", "zsh", "fish", "names"},
		"restore":    {"tfstate", "drill", "vault", "vaultwarden"},
		"media":      {"search", "get", "status"},
		"test":       {"unit", "integration", "smoke", "all"},
	}
}

var usageFlag = regexp.MustCompile(`--[a-z][a-z-]*`)

// commandFlags are the options a command's usage lines name, so they cannot drift.
func commandFlags(c app.Command) []string {
	set := map[string]bool{"--help": true, "--no-color": true}
	for _, line := range strings.Split(c.Usage, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "usage: anvil ") || strings.HasPrefix(t, "anvil "+c.Name) {
			for _, f := range usageFlag.FindAllString(t, -1) {
				set[f] = true
			}
		}
	}
	return slices.Sorted(maps.Keys(set))
}

// completionNames is every name check, apply and up accept: the catalog when a repo is
// found, else the lab targets and their aliases.
func completionNames(a *app.App) []string {
	if root, err := repo.Root(a); err == nil {
		if c, err := lab.LoadCatalog(root); err == nil {
			return c.Names()
		}
	}
	return lab.TargetNames()
}

func cmdCompletion(a *app.App, args []string) int {
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Fprint(a.Stdout, completionUsage)
		return 0
	}
	if len(args) != 1 {
		fmt.Fprint(a.Stderr, completionUsage)
		return 2
	}
	names := completionNames(a)
	switch args[0] {
	case "names":
		for _, n := range names {
			fmt.Fprintln(a.Stdout, n)
		}
	case "bash":
		fmt.Fprint(a.Stdout, bashCompletion(names))
	case "zsh":
		fmt.Fprint(a.Stdout, zshCompletion(names))
	case "fish":
		fmt.Fprint(a.Stdout, fishCompletion(names))
	default:
		fmt.Fprintf(a.Stderr, "anvil: no completion for %q\n\n%s", args[0], completionUsage)
		return 2
	}
	return 0
}

// sq quotes s for bash and zsh single quotes.
func sq(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// fq quotes s for fish single quotes.
func fq(s string) string {
	return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(s) + "'"
}

func cmdNames() []string {
	var out []string
	for _, c := range app.Commands() {
		out = append(out, c.Name)
	}
	return out
}

func bashCompletion(names []string) string {
	var b strings.Builder
	fmt.Fprintf(&b, `# bash completion for anvil. Made by: anvil completion bash
_anvil_names() {
  local n
  n=$(anvil completion names 2>/dev/null)
  [ -n "$n" ] || n=%s
  printf '%%s\n' "$n"
}
_anvil() {
  local cur prev cmd words
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=${COMP_WORDS[COMP_CWORD-1]}
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W %s -- "$cur"))
    return
  fi
  cmd=${COMP_WORDS[1]}
  case $prev in
    --from|--only|--skip) COMPREPLY=($(compgen -W %s -- "$cur")); return ;;
  esac
  if [[ $cur == -* ]]; then
    case $cmd in
`, sq(strings.Join(names, " ")), sq(strings.Join(append(cmdNames(), "--help", "--version", "--no-color"), " ")), sq(strings.Join(lab.StageNames(), " ")))
	for _, c := range app.Commands() {
		fmt.Fprintf(&b, "      %s) words=%s ;;\n", c.Name, sq(strings.Join(commandFlags(c), " ")))
	}
	b.WriteString(`      *) words='--help --no-color' ;;
    esac
    COMPREPLY=($(compgen -W "$words" -- "$cur"))
    return
  fi
  case $cmd in
`)
	fmt.Fprintf(&b, "    %s) words=$(_anvil_names) ;;\n", strings.Join(nameCommands, "|"))
	sub := subWords()
	for _, k := range slices.Sorted(maps.Keys(sub)) {
		fmt.Fprintf(&b, "    %s) [ \"$COMP_CWORD\" -eq 2 ] || return; words=%s ;;\n", k, sq(strings.Join(sub[k], " ")))
	}
	b.WriteString(`    *) return ;;
  esac
  COMPREPLY=($(compgen -W "$words" -- "$cur"))
}
complete -F _anvil anvil
`)
	return b.String()
}

func zshCompletion(names []string) string {
	var b strings.Builder
	b.WriteString("#compdef anvil\n# zsh completion for anvil. Made by: anvil completion zsh\n_anvil() {\n  local -a cmds names\n  cmds=(\n")
	for _, c := range app.Commands() {
		fmt.Fprintf(&b, "    %s\n", sq(c.Name+":"+c.Summary))
	}
	fmt.Fprintf(&b, `  )
  if (( CURRENT == 2 )); then
    _describe 'command' cmds
    return
  fi
  case ${words[CURRENT-1]} in
    --from|--only|--skip) compadd -- %s; return ;;
  esac
  if [[ ${words[CURRENT]} == -* ]]; then
    case ${words[2]} in
`, strings.Join(lab.StageNames(), " "))
	for _, c := range app.Commands() {
		fmt.Fprintf(&b, "      %s) compadd -- %s ;;\n", c.Name, strings.Join(commandFlags(c), " "))
	}
	b.WriteString("      *) compadd -- --help --no-color ;;\n    esac\n    return\n  fi\n  case ${words[2]} in\n")
	fmt.Fprintf(&b, `    %s)
      names=(${(f)"$(anvil completion names 2>/dev/null)"})
      (( ${#names} )) || names=(%s)
      compadd -- $names ;;
`, strings.Join(nameCommands, "|"), strings.Join(names, " "))
	sub := subWords()
	for _, k := range slices.Sorted(maps.Keys(sub)) {
		fmt.Fprintf(&b, "    %s) (( CURRENT == 3 )) && compadd -- %s ;;\n", k, strings.Join(sub[k], " "))
	}
	b.WriteString(`  esac
}
if [ "$funcstack[1]" = "_anvil" ]; then
  _anvil "$@"
else
  compdef _anvil anvil
fi
`)
	return b.String()
}

func fishCompletion(names []string) string {
	var b strings.Builder
	fmt.Fprintf(&b, `# fish completion for anvil. Made by: anvil completion fish
function __anvil_names
    set -l n (anvil completion names 2>/dev/null)
    if test (count $n) -eq 0
        set n %s
    end
    printf '%%s\n' $n
end
complete -c anvil -f
`, strings.Join(names, " "))
	for _, c := range app.Commands() {
		fmt.Fprintf(&b, "complete -c anvil -n __fish_use_subcommand -a %s -d %s\n", c.Name, fq(c.Summary))
	}
	fmt.Fprintf(&b, "complete -c anvil -n '__fish_seen_subcommand_from %s' -a '(__anvil_names)'\n", strings.Join(nameCommands, " "))
	sub := subWords()
	for _, k := range slices.Sorted(maps.Keys(sub)) {
		fmt.Fprintf(&b, "complete -c anvil -n '__fish_seen_subcommand_from %s' -a %s\n", k, fq(strings.Join(sub[k], " ")))
	}
	for _, c := range app.Commands() {
		for _, f := range commandFlags(c) {
			fmt.Fprintf(&b, "complete -c anvil -n '__fish_seen_subcommand_from %s' -l %s\n", c.Name, strings.TrimPrefix(f, "--"))
		}
	}
	fmt.Fprintf(&b, "complete -c anvil -n '__fish_seen_subcommand_from up; and __fish_prev_arg_in --from --only --skip' -a %s\n", fq(strings.Join(lab.StageNames(), " ")))
	return b.String()
}
