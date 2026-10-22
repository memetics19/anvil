package main

import "os"

// palette colors anvil's own status words. It is on only when stdout is a terminal,
// NO_COLOR is unset, TERM is not dumb and --no-color was not given. Off, every method
// returns its text unchanged, so piped output and logs stay plain.
type palette struct{ on bool }

func (p palette) paint(code, s string) string {
	if !p.on || s == "" {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

func (p palette) ok(s string) string   { return p.paint("32", s) }
func (p palette) warn(s string) string { return p.paint("33", s) }
func (p palette) fail(s string) string { return p.paint("31", s) }
func (p palette) bold(s string) string { return p.paint("1", s) }
func (p palette) dim(s string) string  { return p.paint("2", s) }

// level paints s in the color of lv.
func (p palette) level(lv level, s string) string {
	switch lv {
	case lvWarn:
		return p.warn(s)
	case lvFail:
		return p.fail(s)
	}
	return p.ok(s)
}

func (a *app) pal() palette {
	return palette{on: a.tty && !a.noColor && a.getenv("NO_COLOR") == "" && a.getenv("TERM") != "dumb"}
}

// isTerminal reports whether f is a terminal, without a dependency: a terminal is a
// character device, a pipe or a file is not.
func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// valueFlags take a value, so a --no-color right after one is that value, not the switch.
var valueFlags = map[string]bool{"--args": true, "--host": true, "--tags": true, "--from": true, "--only": true, "--skip": true}

// stripNoColor takes --no-color out of args, wherever it is.
func stripNoColor(args []string) ([]string, bool) {
	var out []string
	found := false
	for i, s := range args {
		if s == "--no-color" && (i == 0 || !valueFlags[args[i-1]]) {
			found = true
			continue
		}
		out = append(out, s)
	}
	return out, found
}
