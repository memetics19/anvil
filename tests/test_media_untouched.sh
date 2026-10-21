#!/usr/bin/env bash
# The media library on ragnarok must survive every run. Static checks over ansible/ and
# scripts/ (check_tree), run on the real tree (must pass) and on fixtures that each add one
# violation (each must fail, with the expected rule):
#   media-path   the media path appears only as bind-mount sources in the ARR compose
#                template, and as the protected path in compose_project's defaults
#   home-dir     the VM user's home directory (the media library's parent) appears, and
#                any variable that resolves to it is defined, only in arr_stack/defaults and
#                used only in arr_stack/defaults and arr_stack/tasks
#   destructive  no recursive chown/chmod (recurse:), docker prune, compose down (-v,
#                --volumes), --remove-orphans or recursive rm, apart from the reviewed
#                exceptions below
#   absent       no task with `state: absent` names a path under the home directory or a
#                variable that resolves under it
# Literal values are assembled at runtime so this file does not trip the checks itself.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

home="/home/""ubuntu"
media="$home/media"
template="ansible/roles/arr_stack/templates/docker-compose.yaml.j2"
protected="ansible/roles/compose_project/defaults/main.yml"
arr_defaults="ansible/roles/arr_stack/defaults/main.yml"
arr_tasks="ansible/roles/arr_stack/tasks/main.yml"

# Reviewed exceptions for the destructive rule: "<file>|<fixed text on the line>".
# shellcheck disable=SC2016  # literal text, not an expansion
exceptions=(
  # nginx -t on a mktemp directory, removed right after
  'ansible/roles/frigate_stack/tasks/main.yml|rm -rf "$d"'
  # a shell function that keeps the newest local backups on the operator's Mac
  'scripts/backup.sh|prune'
  # apt cache cleanup inside the IPTV image build, not on the host
  'ansible/roles/iptv/templates/Dockerfile.j2|rm -rf /var/lib/apt/lists/*'
  # the Vaultwarden backup job's mktemp work directory (apps VM), removed on exit
  'ansible/roles/vaultwarden/templates/vaultwarden-backup.sh.j2|rm -rf "$work"'
)

destructive_re='recurse:|(^|[^A-Za-z_-])prune([^A-Za-z_-]|$)|compose[^#]*[[:space:]]down([[:space:]]|$)|^[[:space:]]*-[[:space:]]*["'"'"']?down["'"'"']?[[:space:]]*$|["'"'"']down["'"'"']|down[^#]*[[:space:]]-v([[:space:]]|$)|--volumes|remove-orphans|(^|[^A-Za-z_])rm[[:space:]]+(-[A-Za-z]*[rR]|--recursive)'
home_exact_re="${home}/?(\$|[\"'[:space:],)}])"

# check_tree <root>: prints "FAIL <rule>: ..." lines; returns 1 if any.
check_tree() {
  local root=$1 rc=0 f line hits name names prev risky
  [ -f "$root/$template" ] || { echo "FAIL media-path: $template is missing"; return 1; }

  # media-path
  while IFS= read -r f; do
    case $f in
      "$root/$template")
        hits=$(grep -nF -- "$media" "$f" | grep -vE "^[0-9]+:      - ${media}(/[A-Za-z0-9._-]+)*:/[^:]+$")
        [ -z "$hits" ] || { echo "FAIL media-path: $template, not a bind-mount source: $hits"; rc=1; } ;;
      "$root/$protected")
        hits=$(grep -nF -- "$media" "$f" | grep -vE "^[0-9]+:  - ${media}$")
        [ -z "$hits" ] || { echo "FAIL media-path: $protected, not the protected-path entry: $hits"; rc=1; } ;;
      *) echo "FAIL media-path: ${f#"$root"/}"; rc=1 ;;
    esac
  done < <(grep -rlF --exclude-dir=.ansible --exclude-dir=.collections -- "$media" "$root/ansible" "$root/scripts")

  # home-dir: the bare home directory, and variables that resolve to it
  while IFS= read -r f; do
    [ "$f" = "$root/$arr_defaults" ] || { echo "FAIL home-dir: ${f#"$root"/} names $home"; rc=1; }
  done < <(grep -rlE --exclude-dir=.ansible --exclude-dir=.collections -- "$home_exact_re" "$root/ansible")
  names=$(grep -rhoE --exclude-dir=.ansible --exclude-dir=.collections \
    "^[[:space:]]*[a-z0-9_]+:[[:space:]]*[\"']?${home}/?[\"']?[[:space:]]*$" "$root/ansible" |
    sed -E 's/^[[:space:]]*([a-z0-9_]+):.*/\1/' | sort -u)
  for name in $names; do
    while IFS= read -r f; do
      case $f in
        "$root/$arr_defaults" | "$root/$arr_tasks") ;;
        *) echo "FAIL home-dir: ${f#"$root"/} uses $name (resolves to $home)"; rc=1 ;;
      esac
    done < <(grep -rlwE --exclude-dir=.ansible --exclude-dir=.collections -- "$name" "$root/ansible")
  done

  # destructive
  while IFS= read -r line; do
    f=${line%%:*}; f=${f#"$root"/}
    local ok=0 e
    for e in "${exceptions[@]}"; do
      [ "$f" = "${e%%|*}" ] && [[ $line == *"${e#*|}"* ]] && ok=1
    done
    [ "$ok" = 1 ] || { echo "FAIL destructive: ${line#"$root"/}"; rc=1; }
  done < <(grep -rnE --exclude-dir=.ansible --exclude-dir=.collections -- "$destructive_re" "$root/ansible" "$root/scripts")

  # absent: variables whose value starts at the home directory, then variables built on them.
  # Variables are role-prefixed (contain "_"); module options like path/dest/chdir are not.
  risky=$(grep -rhoE --exclude-dir=.ansible --exclude-dir=.collections \
    "^[[:space:]]*[a-z0-9]+_[a-z0-9_]+:[[:space:]]*[\"']?${home}" "$root/ansible" | sed -E 's/^[[:space:]]*([a-z0-9_]+):.*/\1/' | sort -u)
  prev=
  while [ "$risky" != "$prev" ]; do
    prev=$risky
    for name in $prev; do
      risky=$(printf '%s\n%s\n' "$risky" "$(grep -rhoE --exclude-dir=.ansible --exclude-dir=.collections \
        "^[[:space:]]*[a-z0-9]+_[a-z0-9_]+:[[:space:]]*[\"']?\{\{[[:space:]]*${name}[[:space:]]*\}\}" "$root/ansible" |
        sed -E 's/^[[:space:]]*([a-z0-9_]+):.*/\1/')" | sed '/^$/d' | sort -u)
    done
  done
  while IFS= read -r f; do
    hits=$(awk -v home="$home" -v risky="$(printf '%s ' "$risky" | tr '\n' ' ')" '
      function flush() {
        if (chunk ~ /state:[[:space:]]*absent/) {
          bad = index(chunk, home) > 0
          n = split(risky, r, " ")
          for (i = 1; i <= n; i++) if (r[i] != "" && chunk ~ ("(^|[^a-z0-9_])" r[i] "([^a-z0-9_]|$)")) bad = 1
          if (bad) print FILENAME ":" start
        }
        chunk = ""
      }
      /^[[:space:]]*- name:/ { flush(); start = FNR }
      { chunk = chunk "\n" $0 }
      END { flush() }' "$f")
    [ -z "$hits" ] || { echo "FAIL absent: state: absent on a home-directory path at ${hits//"$root"\//}"; rc=1; }
  done < <(grep -rlE --exclude-dir=.ansible --exclude-dir=.collections 'state:[[:space:]]*absent' "$root/ansible" --include='*.yml' --include='*.yaml')
  return "$rc"
}

fail=0
out=$(check_tree .); rc=$?
if [ "$rc" = 0 ]; then echo "PASS real tree"; else echo "$out"; echo "FAIL real tree"; fail=1; fi

# Fixture cases: copy ansible/ and scripts/, add one violation, expect that rule to fire.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# case <name> <expected rule> <file relative to the copy> <content to append>
case_() {
  local name=$1 rule=$2 file=$3 content=$4 d
  d="$work/$name"; mkdir -p "$d"
  cp -R ansible scripts "$d"/
  rm -rf "$d/ansible/.ansible" "$d/ansible/.collections"
  mkdir -p "$(dirname "$d/$file")"
  printf '%s\n' "$content" >> "$d/$file"
  if out=$(check_tree "$d"); then
    echo "FAIL case $name: expected rule $rule, the tree passed"; fail=1
  elif grep -q "^FAIL $rule:" <<<"$out"; then
    echo "PASS case $name ($rule)"
  else
    echo "FAIL case $name: expected rule $rule, got: ${out:-nothing}"; fail=1
  fi
}
x=ansible/roles/zz_fixture/tasks/main.yml
case_ media-in-defaults media-path ansible/roles/zz_fixture/defaults/main.yml "zz_path: $media/tv"
case_ media-in-template media-path "$template" "    working_dir: $media"
case_ media-in-script media-path scripts/zz.sh "ls $media"
case_ home-var-elsewhere home-dir ansible/roles/zz_fixture/defaults/main.yml "zz_dir: $home"
case_ arr-dir-elsewhere home-dir "$x" "- name: x
  ansible.builtin.debug:
    msg: \"{{ arr_stack_dir }}\""
case_ recurse destructive "$x" "- name: x
  ansible.builtin.file:
    path: /opt/x
    recurse: true"
case_ prune destructive "$x" "- name: x
  ansible.builtin.command: docker system prune -af"
case_ compose-down destructive "$x" "- name: x
  ansible.builtin.command: docker compose -f /x/docker-compose.yaml down"
case_ compose-down-argv destructive "$x" "- name: x
  ansible.builtin.command:
    argv:
      - docker
      - compose
      - down"
case_ compose-down-v destructive scripts/zz.sh "docker compose down -v"
case_ volumes destructive "$x" "- name: x
  ansible.builtin.command: docker compose rm --volumes web"
case_ remove-orphans destructive "$x" "- name: x
  ansible.builtin.command: docker compose up -d --remove-orphans"
case_ rm-rf destructive scripts/zz.sh "rm -rf /opt/x"
case_ rm-r-ansible destructive "$x" "- name: x
  ansible.builtin.shell: rm -r -f /opt/x"
case_ absent-home-literal absent "$x" "- name: x
  ansible.builtin.file:
    path: $home/x
    state: absent"
case_ absent-arr-var absent "$arr_tasks" "- name: x
  ansible.builtin.file:
    path: \"{{ arr_stack_dir }}/x\"
    state: absent"
case_ absent-derived-var absent "$x" "- name: x
  ansible.builtin.file:
    path: \"{{ iptv_epg_dir }}/output\"
    state: absent"

if [ "$fail" != 0 ]; then echo "FAIL: media library checks"; exit 1; fi
echo "PASS: media library checks"
