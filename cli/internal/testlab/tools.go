package testlab

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// FakeTools puts every tool init checks on PATH, with versions that pass.
func FakeTools(l *Lab) {
	versions := map[string]string{
		"terraform": "Terraform v1.13.3", "vault": "Vault v1.20.4", "ansible-lint": "ansible-lint 25.9.2 using ansible-core:2.19.2",
		"yamllint": "yamllint 1.37.1", "gitleaks": "8.28.0", "tflint": "TFLint version 0.59.1",
		"age": "v1.2.1", "sshpass": "sshpass 1.10", "aws": "aws-cli/2.31.0", "pre-commit": "pre-commit 4.3.0",
		"python3": "Python 3.13.7", "git": "git version 2.51.0",
	}
	for name, v := range versions {
		l.Tool(name, "#!/bin/sh\necho '"+v+"'\n")
	}
	// ansible-galaxy: every required collection is installed unless FAKE_GALAXY_EMPTY is set;
	// an install is logged to FAKE_LOG as "galaxy install".
	l.Tool("ansible-galaxy", `#!/bin/sh
case "$*" in
  "collection list --format json")
    if [ -n "$FAKE_GALAXY_EMPTY" ]; then echo '{}'; else
    echo '{"/c":{"community.general":{},"community.hashi_vault":{},"community.crypto":{},"ansible.posix":{}}}'; fi ;;
  "collection install"*) echo "galaxy install" >> "$FAKE_LOG" ;;
esac
`)
	py := filepath.Join(l.Bin, "ansible-python")
	l.Tool("ansible-python", "#!/bin/sh\nexit 0\n")
	l.Tool("ansible-playbook", "#!/bin/sh\necho 'ansible-playbook [core 2.19.2]'\necho '  python version = 3.13.7 (main) [Clang 17] ("+py+")'\n")
	// The Keychain answers with a value on stdout, which must never be printed.
	l.Tool("security", "#!/bin/sh\necho 'password: \""+SentinelEnv+"\"'\ncase \"$*\" in *\"-a ${FAKE_MISSING_ITEM:-none}\"*) exit 44 ;; esac\nexit 0\n")
	// jq is the real one (status needs it). vault is fake.
	l.Tool("vault", `#!/bin/sh
[ "$1" = version ] && { echo 'Vault v1.20.4'; exit 0; }
if [ -n "${FAKE_VAULT_JSON+x}" ]; then printf '%s\n' "$FAKE_VAULT_JSON"; else echo '{"initialized":true,"sealed":false}'; fi
exit "${FAKE_VAULT_RC:-0}"
`)
	home := l.Env["HOME"]
	for _, f := range []string{".ssh/id_ed25519", ".ssh/id_ed25519.pub", ".config/homelab/vault-ca.pem"} {
		p := filepath.Join(home, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			l.T.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x\n"), 0o600); err != nil {
			l.T.Fatal(err)
		}
	}
}

// Git runs git for the test, with no user or system config.
func Git(t *testing.T, home, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@example.test", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"}, args...)...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "HOME="+home, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// Remote is a bare repo standing in for GitHub: main with tag v1.2.3, and one more
// commit on main after it. No network.
type Remote struct {
	*Lab
	Src, Bare, Data string
}

// NewRemote is a lab with a Remote and an empty data directory for anvil fetch.
func NewRemote(t *testing.T) *Remote {
	l := New(t)
	dir := filepath.Dir(l.Root)
	r := &Remote{Lab: l, Src: filepath.Join(dir, "src"), Bare: filepath.Join(dir, "remote.git"), Data: filepath.Join(dir, "data")}
	home := l.Env["HOME"]
	Git(t, home, dir, "init", "-q", "-b", "main", r.Src)
	for p, c := range map[string]string{"Makefile": "", "scripts/env.sh": "", "VERSION": "1.2.3\n"} {
		os.MkdirAll(filepath.Join(r.Src, filepath.Dir(p)), 0o755)
		os.WriteFile(filepath.Join(r.Src, p), []byte(c), 0o644)
	}
	Git(t, home, r.Src, "add", ".")
	Git(t, home, r.Src, "commit", "-q", "-m", "one")
	Git(t, home, r.Src, "tag", "v1.2.3")
	r.Commit("after the tag\n")
	Git(t, home, dir, "clone", "-q", "--bare", r.Src, r.Bare)
	l.Env["ANVIL_REPO_URL"] = r.Bare
	l.Env["XDG_DATA_HOME"] = r.Data
	return r
}

// Commit commits a new VERSION on main, and pushes it once the bare repo exists.
func (r *Remote) Commit(version string) {
	home := r.Env["HOME"]
	os.WriteFile(filepath.Join(r.Src, "VERSION"), []byte(version), 0o644)
	Git(r.T, home, r.Src, "commit", "-q", "-am", "change")
	if _, err := os.Stat(r.Bare); err == nil {
		Git(r.T, home, r.Src, "push", "-q", "--tags", r.Bare, "main")
	}
}

// Clone is where anvil fetch clones to.
func (r *Remote) Clone() string { return filepath.Join(r.Data, "anvil", "repo") }

// CloneFile is VERSION in the clone.
func (r *Remote) CloneFile() string {
	b, _ := os.ReadFile(filepath.Join(r.Clone(), "VERSION"))
	return string(b)
}
