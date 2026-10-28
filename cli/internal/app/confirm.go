package app

import (
	"bufio"
	"fmt"
	"io"
	"strings"
)

// ReadLine reads one answer. ok is false at end of input.
func ReadLine(in *bufio.Reader) (string, bool) {
	line, err := in.ReadString('\n')
	if err != nil && line == "" {
		return "", false
	}
	return strings.TrimSpace(line), true
}

// AskYesDefault asks a Y/n question: an empty answer is a yes, end of input a no.
func AskYesDefault(in *bufio.Reader, out io.Writer, question string) bool {
	fmt.Fprintf(out, "%s [Y/n] ", question)
	ans, ok := ReadLine(in)
	if !ok {
		fmt.Fprintln(out)
		return false
	}
	ans = strings.ToLower(ans)
	return ans == "" || ans == "y" || ans == "yes"
}

// AskYesNo asks a y/N question. Only y or yes is a yes, and end of input is a no.
func AskYesNo(in *bufio.Reader, out io.Writer, question string) bool {
	fmt.Fprintf(out, "%s [y/N] ", question)
	ans, ok := ReadLine(in)
	if !ok {
		fmt.Fprintln(out)
		return false
	}
	ans = strings.ToLower(ans)
	return ans == "y" || ans == "yes"
}

// AskTyped asks the user to type want exactly.
func AskTyped(in *bufio.Reader, out io.Writer, question, want string) bool {
	fmt.Fprintf(out, "%s Type %q to continue: ", question, want)
	ans, ok := ReadLine(in)
	if !ok {
		fmt.Fprintln(out)
		return false
	}
	return ans == want
}
