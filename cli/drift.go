package main

// anvil drift: the nightly check. It runs what anvil check runs with no target (host, vms,
// tf), and pushes the verdict to ntfy when something drifted or a check failed. It runs on
// the operator machine, which already holds the lab's keys: GitHub holds none, and no lab
// VM may read Vault. --install schedules it (launchd on macOS, a systemd user timer on
// Linux).

import (
	"bytes"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func init() {
	register(command{"drift", "the nightly check: anvil check, then a push to ntfy if anything drifted", driftUsage, cmdDrift, 23})
}

const driftUsage = `usage: anvil drift [--always] [--log FILE]
       anvil drift --install [--at HH:MM]
       anvil drift --uninstall

Runs what anvil check runs with no target (host, vms and tf, all read-only) and sends the
verdict to ntfy when something drifted or a check failed. Exit 1 then.

The message has the targets, the VMs with changes and Terraform's counts. No addresses,
no diffs. The full output stays in the log.

  --always       send a message when nothing drifted too
  --log FILE     write the output to FILE, keeping the last 7 runs as FILE.1 to FILE.7
  --install      run it every night on this machine, from this checkout: launchd on
                 macOS, a systemd user timer on Linux. A run missed while the machine
                 slept runs when it wakes.
  --at HH:MM     the time for --install (default 03:30)
  --uninstall    remove the schedule

ntfy: the topic URL and an access token, from the environment (ANVIL_NTFY_URL,
ANVIL_NTFY_TOKEN), else the Keychain (service homelab, accounts ntfy-url and ntfy-token):

  security add-generic-password -s homelab -a ntfy-url -w https://<ntfy host>/<topic>
  security add-generic-password -s homelab -a ntfy-token -w

Without them it only prints the verdict.
`

const driftLabel = "com.github.memetics19.anvil.drift"

var atRE = regexp.MustCompile(`^([01]?\d|2[0-3]):([0-5]\d)$`)

func cmdDrift(a *app, args []string) int {
	var always, install, uninstall bool
	var logFile, at string
	fs := flag.NewFlagSet("drift", flag.ContinueOnError)
	fs.BoolVar(&always, "always", false, "")
	fs.StringVar(&logFile, "log", "", "")
	fs.BoolVar(&install, "install", false, "")
	fs.StringVar(&at, "at", "03:30", "")
	fs.BoolVar(&uninstall, "uninstall", false, "")
	pos, code, ok := a.flags(fs, driftUsage, args)
	if !ok {
		return code
	}
	if len(pos) > 0 {
		fmt.Fprint(a.stderr, driftUsage)
		return 2
	}
	switch {
	case uninstall:
		return a.driftUninstall()
	case install:
		m := atRE.FindStringSubmatch(at)
		if m == nil {
			fmt.Fprintf(a.stderr, "anvil: drift: --at wants HH:MM, for example 03:30 (got %q)\n", at)
			return 2
		}
		h, _ := strconv.Atoi(m[1])
		min, _ := strconv.Atoi(m[2])
		return a.driftInstall(h, min)
	}

	if logFile != "" {
		f, err := rotateLog(logFile, 7)
		if err != nil {
			fmt.Fprintf(a.stderr, "anvil: drift: %v\n", err)
			return 1
		}
		defer f.Close()
		a.stdout, a.stderr = f, f
		fmt.Fprintf(f, "anvil drift, %s\n", time.Now().Format(time.RFC1123))
	}

	r, c, ok := a.setup(false)
	if !ok {
		a.notify("anvil: drift check failed", "it could not start: no repo or no site dict", "x", 4)
		return 1
	}
	var lines []string
	drift, failed := false, false
	for _, n := range []string{"host", "vms", "tf"} {
		t, err := c.resolve(n, "")
		if err != nil {
			fmt.Fprintf(a.stderr, "anvil: %v\n", err)
			return 2
		}
		code, s := a.runCheck(r, t, targetOpts{})
		switch {
		case code != 0:
			failed = true
			lines = append(lines, fmt.Sprintf("%s: the check failed (exit %d)", t.name, code))
		default:
			drift = drift || !s.known || s.changes
			lines = append(lines, t.name+": "+driftLine(s))
		}
	}
	body := strings.Join(lines, "\n")
	fmt.Fprintln(a.stdout, "anvil drift:\n"+body)
	switch {
	case failed:
		a.notify("anvil: drift check failed", body, "x", 4)
	case drift:
		a.notify("anvil: the lab drifted", body+"\nanvil check <target> shows the diff.", "warning", 4)
	case always:
		a.notify("anvil: no drift", body, "white_check_mark", 2)
	}
	if failed || drift {
		return 1
	}
	return 0
}

// driftLine is a check's summary without the VMs that would not change.
func driftLine(s summary) string {
	if !s.known || !s.changes {
		return s.String()
	}
	var keep []string
	for _, l := range s.lines {
		if !strings.HasSuffix(l, " changed=0") {
			keep = append(keep, l)
		}
	}
	s.lines = keep
	return s.String()
}

// ntfyConfig is the topic URL and the token: the environment first, then the Keychain.
func (a *app) ntfyConfig() (url, token string) {
	url, token = a.getenv("ANVIL_NTFY_URL"), a.getenv("ANVIL_NTFY_TOKEN")
	if url == "" {
		url = keychainValue(a, "ntfy-url")
	}
	if token == "" {
		token = keychainValue(a, "ntfy-token")
	}
	return url, token
}

// keychainValue reads one item of service homelab, or "". Tests replace it.
var keychainValue = func(a *app, account string) string {
	if !a.lookPath("security") {
		return ""
	}
	out, code := a.probe("security", "find-generic-password", "-s", "homelab", "-a", account, "-w")
	if code != 0 {
		return ""
	}
	return strings.TrimSpace(out)
}

// notify posts one message to ntfy. The token goes in a header. A failure is printed,
// never fatal: the verdict is in the output and the exit code anyway.
func (a *app) notify(title, body, tag string, priority int) {
	url, token := a.ntfyConfig()
	if url == "" {
		fmt.Fprintln(a.stdout, "anvil drift: ntfy is not set up (anvil drift --help), no message sent")
		return
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewBufferString(body))
	if err != nil {
		fmt.Fprintln(a.stderr, "anvil drift: the ntfy URL is not a URL")
		return
	}
	req.Header.Set("Title", title)
	req.Header.Set("Tags", tag)
	req.Header.Set("Priority", strconv.Itoa(priority))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		fmt.Fprintln(a.stderr, "anvil drift: ntfy did not answer, no message sent")
		return
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		fmt.Fprintf(a.stderr, "anvil drift: ntfy refused the message (HTTP %d)\n", resp.StatusCode)
		return
	}
	fmt.Fprintln(a.stdout, "anvil drift: sent to ntfy")
}

// rotateLog moves FILE to FILE.1 (FILE.1 to FILE.2, and so on, keeping n) and opens a new
// FILE, readable by its owner only.
func rotateLog(path string, n int) (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	for i := n - 1; i >= 1; i-- {
		_ = os.Rename(fmt.Sprintf("%s.%d", path, i), fmt.Sprintf("%s.%d", path, i+1))
	}
	_ = os.Rename(path, path+".1")
	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
}

// driftPaths: the schedule's files and the log, for this OS.
func (a *app) driftPaths() (unit, timer, log string) {
	home := a.getenv("HOME")
	if goos == "darwin" {
		return filepath.Join(home, "Library", "LaunchAgents", driftLabel+".plist"), "",
			filepath.Join(home, "Library", "Logs", "anvil", "drift.log")
	}
	cfg := a.getenv("XDG_CONFIG_HOME")
	if cfg == "" {
		cfg = filepath.Join(home, ".config")
	}
	state := a.getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(home, ".local", "state")
	}
	dir := filepath.Join(cfg, "systemd", "user")
	return filepath.Join(dir, "anvil-drift.service"), filepath.Join(dir, "anvil-drift.timer"),
		filepath.Join(state, "anvil", "drift.log")
}

// runSched runs launchctl or systemctl. Tests replace it.
var runSched = func(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}

func (a *app) driftInstall(hour, minute int) int {
	root, err := a.repoRoot()
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: drift: %v\n", err)
		return 1
	}
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintf(a.stderr, "anvil: drift: cannot find this binary: %v\n", err)
		return 1
	}
	if p, err := filepath.EvalSymlinks(self); err == nil {
		self = p
	}
	unit, timer, log := a.driftPaths()
	if err := os.MkdirAll(filepath.Dir(unit), 0o755); err != nil {
		fmt.Fprintf(a.stderr, "anvil: drift: %v\n", err)
		return 1
	}
	// The schedule gets this shell's PATH: make, ansible, terraform and vault live there.
	path := a.getenv("PATH")
	if goos == "darwin" {
		uid := strconv.Itoa(os.Getuid())
		if err := os.WriteFile(unit, []byte(launchdPlist(self, root, path, log, hour, minute)), 0o644); err != nil {
			fmt.Fprintf(a.stderr, "anvil: drift: %v\n", err)
			return 1
		}
		_ = runSched("launchctl", "bootout", "gui/"+uid+"/"+driftLabel)
		if err := runSched("launchctl", "bootstrap", "gui/"+uid, unit); err != nil {
			fmt.Fprintf(a.stderr, "anvil: drift: launchctl bootstrap failed: %v\n", err)
			return 1
		}
	} else {
		svc, tmr := systemdUnits(self, root, path, log, hour, minute)
		if err := os.WriteFile(unit, []byte(svc), 0o644); err != nil {
			fmt.Fprintf(a.stderr, "anvil: drift: %v\n", err)
			return 1
		}
		if err := os.WriteFile(timer, []byte(tmr), 0o644); err != nil {
			fmt.Fprintf(a.stderr, "anvil: drift: %v\n", err)
			return 1
		}
		if err := runSched("systemctl", "--user", "daemon-reload"); err == nil {
			err = runSched("systemctl", "--user", "enable", "--now", "anvil-drift.timer")
		}
		if err != nil {
			fmt.Fprintf(a.stderr, "anvil: drift: systemctl --user failed: %v\n", err)
			return 1
		}
	}
	fmt.Fprintf(a.stdout, "anvil drift: every night at %02d:%02d from %s. Log: %s\n",
		hour, minute, tildePath(a.getenv, root), tildePath(a.getenv, log))
	if url, _ := a.ntfyConfig(); url == "" {
		fmt.Fprintln(a.stdout, "anvil drift: ntfy is not set up yet, see anvil drift --help")
	}
	return 0
}

func (a *app) driftUninstall() int {
	unit, timer, _ := a.driftPaths()
	if goos == "darwin" {
		_ = runSched("launchctl", "bootout", "gui/"+strconv.Itoa(os.Getuid())+"/"+driftLabel)
	} else {
		_ = runSched("systemctl", "--user", "disable", "--now", "anvil-drift.timer")
	}
	for _, f := range []string{unit, timer} {
		if f != "" {
			_ = os.Remove(f)
		}
	}
	if goos != "darwin" {
		_ = runSched("systemctl", "--user", "daemon-reload")
	}
	fmt.Fprintln(a.stdout, "anvil drift: the nightly check is removed")
	return 0
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;").Replace(s)
}

func launchdPlist(self, root, path, log string, hour, minute int) string {
	x := xmlEscape
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>%s</string><string>drift</string><string>--log</string><string>%s</string></array>
  <key>WorkingDirectory</key><string>%s</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>%s</string>
    <key>ANVIL_REPO</key><string>%s</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>
  <key>StandardOutPath</key><string>%s.launchd</string>
  <key>StandardErrorPath</key><string>%s.launchd</string>
</dict>
</plist>
`, driftLabel, x(self), x(log), x(root), x(path), x(root), hour, minute, x(log), x(log))
}

func systemdUnits(self, root, path, log string, hour, minute int) (service, timer string) {
	q := func(s string) string {
		return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "%", "%%").Replace(s) + `"`
	}
	service = fmt.Sprintf(`[Unit]
Description=anvil drift: the nightly read-only check of the lab

[Service]
Type=oneshot
WorkingDirectory=%s
Environment=%s
Environment=%s
ExecStart=%s drift --log %s
`, q(root), q("PATH="+path), q("ANVIL_REPO="+root), q(self), q(log))
	timer = fmt.Sprintf(`[Unit]
Description=anvil drift every night

[Timer]
OnCalendar=*-*-* %02d:%02d:00
Persistent=true

[Install]
WantedBy=timers.target
`, hour, minute)
	return service, timer
}
