#!/usr/bin/env bash
# The local language model (role llm): the compose file renders, Ollama is not published,
# the chat UI is on the lab address only, images are pinned, memory is capped, and the VM is
# wired into vms.yml, the gateway example and Homepage. Documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

cat >"$tmp/play.yml" <<PLAY
- name: LLM compose
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: llm
    gateway_domain: lab.example.com
    site:
      hosts: {llm: {ip: 192.0.2.126}}
  vars_files:
    - $PWD/ansible/roles/llm/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/llm/templates/docker-compose.yml.j2
        dest: $tmp/compose.yml
        mode: "0644"
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1; then ok "compose renders"; else
  bad_ "compose renders"; cat "$tmp/log"; exit 1; fi
c=$tmp/compose.yml
# shellcheck disable=SC2329  # called through check's eval
py() { python3 -c "import yaml; s=yaml.safe_load(open('$c'))['services']; $1"; }
check "valid YAML with ollama and webui" "py 'assert sorted(s)==[\"ollama\",\"webui\"]'"
check "Ollama publishes no port (only the UI reaches it)" "py 'assert \"ports\" not in s[\"ollama\"]'"
check "the chat UI is published on the lab address only, port 8080" \
  "py 'assert s[\"webui\"][\"ports\"]==[\"192.0.2.126:8080:8080\"]'"
check "the UI talks to Ollama inside the network" "py 'assert s[\"webui\"][\"environment\"][\"OLLAMA_BASE_URL\"]==\"http://ollama:11434\"'"
check "no sign-ups from outside the gateway" "py 'assert s[\"webui\"][\"environment\"][\"ENABLE_SIGNUP\"]==\"false\"'"
check "both images pinned by digest" "[ \$(grep -cE 'image: .*@sha256:[a-f0-9]{64}' '$c') = 2 ]"
check "memory capped with no swap on both" "py 'assert all(s[n][\"mem_limit\"]==s[n][\"memswap_limit\"] for n in s)'"
check "no telemetry" "py 'assert s[\"webui\"][\"environment\"][\"ANONYMIZED_TELEMETRY\"]==\"false\"'"

# Wiring.
check "vms.yml: role llm with tag llm on llm_servers, after Docker" \
  "python3 -c 'import yaml; p=yaml.safe_load(open(\"ansible/playbooks/vms.yml\")); n=[x[\"name\"] for x in p]
i=[k for k,x in enumerate(p) if any(r.get(\"role\")==\"llm\" for r in x.get(\"roles\",[]))]
assert len(i)==1 and p[i[0]][\"hosts\"]==\"llm_servers\" and i[0]>n.index(\"Docker\")
assert [r for r in p[i[0]][\"roles\"] if r[\"role\"]==\"llm\"][0][\"tags\"]==[\"llm\"]'"
check "vms.yml: llm_servers gets guest base, docker, grow disk and the pulse agent" \
  "python3 -c 'import yaml; p=yaml.safe_load(open(\"ansible/playbooks/vms.yml\"))
for nm in (\"Guest base\",\"Docker\",\"Grow disk\",\"Pulse agent\"):
    h=[x[\"hosts\"] for x in p if x[\"name\"]==nm][0]; assert \"llm_servers\" in h, nm'"
check "site.example.yml: the llm entry on the second node, and the gateway service" \
  "python3 -c 'import yaml; s=yaml.safe_load(open(\"site/site.example.yml\"))[\"site\"]
assert s[\"hosts\"][\"llm\"][\"node\"]==\"pve2\"
a=[x for x in s[\"services\"] if x[\"name\"]==\"llm\"]; assert a==[dict(name=\"llm\",host=\"hosts.llm.ip\",port=8080,scheme=\"http\",websocket=True)]'"
check "homepage: catalog entry llm, no widget" \
  "python3 -c 'import yaml; c=yaml.safe_load(open(\"ansible/roles/homepage/defaults/main.yml\"))[\"homepage_catalog\"][\"llm\"]
assert c[\"group\"]==\"Home\" and c[\"widget\"]==\"none\"'"
check "inventory: the llm_servers group with the llm host" \
  "python3 -c 'import yaml; g=yaml.safe_load(open(\"ansible/inventory/hosts.yml\"))
def find(d):
    if isinstance(d,dict):
        if \"llm_servers\" in d: return d[\"llm_servers\"]
        for v in d.values():
            r=find(v)
            if r: return r
    return None
assert \"llm\" in find(g)[\"hosts\"]'"

[ "$fail" -eq 0 ] && echo "PASS: llm"
exit "$fail"
