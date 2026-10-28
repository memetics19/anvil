package app

import "os"

// Palette colors anvil's own status words. It is on only when stdout is a terminal,
// NO_COLOR is unset, TERM is not dumb and --no-color was not given. Off, every method
// returns its text unchanged, so piped output and logs stay plain.
type Palette struct{ on bool }

// Paint wraps s in the ANSI code when color is on.
func (p Palette) Paint(code, s string) string {
	if !p.on || s == "" {
		return s
	}
	return "\x1b[" + code + "m" + s + "\x1b[0m"
}

// Ok, Warn, Fail, Bold and Dim are green, yellow, red, bold and dim.
func (p Palette) Ok(s string) string   { return p.Paint("32", s) }
func (p Palette) Warn(s string) string { return p.Paint("33", s) }
func (p Palette) Fail(s string) string { return p.Paint("31", s) }
func (p Palette) Bold(s string) string { return p.Paint("1", s) }
func (p Palette) Dim(s string) string  { return p.Paint("2", s) }

// Pal is the palette for this run.
func (a *App) Pal() Palette {
	return Palette{on: a.TTY && !a.NoColor && a.Getenv("NO_COLOR") == "" && a.Getenv("TERM") != "dumb"}
}

// IsTerminal reports whether f is a terminal, without a dependency: a terminal is a
// character device, a pipe or a file is not.
func IsTerminal(f *os.File) bool {
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
