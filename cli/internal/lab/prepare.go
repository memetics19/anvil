package lab

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/memetics19/anvil/cli/internal/app"
	"github.com/memetics19/anvil/cli/internal/run"
	"gopkg.in/yaml.v3"
)

// prepare sets up this checkout the way the docs' first-time steps do, so no command
// needs a manual make or install first: Terraform's backend (a fresh clone or worktree
// has no .terraform) and the Ansible collections in ansible/requirements.yml. A dry run
// only prints what it would do.
func prepare(a *app.App, r *run.Runner) bool {
	return prepareTerraform(a, r) && prepareCollections(a, r)
}

func prepareTerraform(a *app.App, r *run.Runner) bool {
	if _, err := os.Stat(filepath.Join(r.Root, "terraform", ".terraform", "terraform.tfstate")); err == nil {
		return true
	}
	if !r.DryRun {
		fmt.Fprintln(a.Stderr, "anvil: this checkout has no Terraform setup yet, running tf-init first")
	}
	if !canReach(a, r, "tf-init") {
		return false
	}
	if code := r.Make(run.NewMake("tf-init"), nil); code != 0 {
		fmt.Fprintf(a.Stderr, "anvil: tf-init failed (exit %d)\n", code)
		return false
	}
	return true
}

// prepareCollections installs the collections ansible/requirements.yml names when any is
// missing. Without ansible-galaxy it does nothing: anvil init reports the missing tool.
func prepareCollections(a *app.App, r *run.Runner) bool {
	b, err := os.ReadFile(filepath.Join(r.Root, "ansible", "requirements.yml"))
	if err != nil {
		return true
	}
	var req struct {
		Collections []struct {
			Name string `yaml:"name"`
		} `yaml:"collections"`
	}
	if err := yaml.Unmarshal(b, &req); err != nil {
		fmt.Fprintf(a.Stderr, "anvil: ansible/requirements.yml: %v\n", err)
		return false
	}
	// Through bash so the lookup uses the child environment's PATH, like every make run.
	cmd := exec.Command("bash", "-c", "ansible-galaxy collection list --format json 2>/dev/null")
	cmd.Dir, cmd.Env = r.Root, r.Env
	var out bytes.Buffer
	cmd.Stdout = &out
	if cmd.Run() != nil {
		return true
	}
	var listed map[string]map[string]json.RawMessage
	if json.Unmarshal(out.Bytes(), &listed) != nil {
		return true
	}
	have := map[string]bool{}
	for _, cols := range listed {
		for name := range cols {
			have[name] = true
		}
	}
	missing := 0
	for _, c := range req.Collections {
		if !have[c.Name] {
			missing++
		}
	}
	if missing == 0 {
		return true
	}
	if !r.DryRun {
		fmt.Fprintf(a.Stderr, "anvil: %d Ansible collection(s) missing, installing ansible/requirements.yml\n", missing)
	}
	if code := r.Shell("bash scripts/install-collections.sh ~/.ansible/collections", nil); code != 0 {
		fmt.Fprintf(a.Stderr, "anvil: installing the Ansible collections failed (exit %d)\n", code)
		return false
	}
	return true
}
