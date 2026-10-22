package main

import (
	"bufio"
	"fmt"
	"io"
	"strings"
)

// readLine reads one answer. ok is false at end of input.
func readLine(in *bufio.Reader) (string, bool) {
	line, err := in.ReadString('\n')
	if err != nil && line == "" {
		return "", false
	}
	return strings.TrimSpace(line), true
}

// askYesNo asks a y/N question. Only y or yes is a yes, and end of input is a no.
func askYesNo(in *bufio.Reader, out io.Writer, question string) bool {
	fmt.Fprintf(out, "%s [y/N] ", question)
	ans, ok := readLine(in)
	if !ok {
		fmt.Fprintln(out)
		return false
	}
	ans = strings.ToLower(ans)
	return ans == "y" || ans == "yes"
}

// askTyped asks the user to type want exactly.
func askTyped(in *bufio.Reader, out io.Writer, question, want string) bool {
	fmt.Fprintf(out, "%s Type %q to continue: ", question, want)
	ans, ok := readLine(in)
	if !ok {
		fmt.Fprintln(out)
		return false
	}
	return ans == want
}

// confirmApply is the confirmation before a real run. Every target needs a yes, which
// --yes gives. A risky target also needs its name typed, which --yes does not skip.
func confirmApply(in *bufio.Reader, out io.Writer, t target, yes bool) bool {
	if t.risky {
		return askTyped(in, out, fmt.Sprintf("%s is a risky target (%s).", t.name, t.help), t.name)
	}
	if yes {
		return true
	}
	return askYesNo(in, out, fmt.Sprintf("Apply %s?", t.name))
}
