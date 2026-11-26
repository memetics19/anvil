#!/bin/sh
# Managed by anvil (role postboot_verify). Runs once on boot after docker. It reconciles every
# compose project so apps restart in the right order (depends_on and the gluetun netns pair),
# then reports container health to Gotify. Config in /etc/anvil-postboot.env. Projects are
# discovered from docker itself, so no paths are hardcoded here.
set -u
. /etc/anvil-postboot.env
sleep "${SETTLE:-45}"
# up -d is idempotent and restores depends_on and the gluetun netns ordering.
docker compose ls -a 2>/dev/null | awk 'NR > 1 {print $NF}' | tr ',' '\n' | while read -r cf; do
  [ -n "$cf" ] && [ -f "$cf" ] && docker compose -f "$cf" up -d >/dev/null 2>&1
done
sleep 25
run=$(docker ps --filter status=running --format '{{.Names}}' | grep -vc -- '-build-')
unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' | paste -sd, -)
exited=$(docker ps -a --filter status=exited --format '{{.Names}}' | grep -v -- '-build-' | paste -sd, -)
H=$(hostname)
if [ -n "${unhealthy}${exited}" ]; then
  title="anvil post-boot WARNING ${H}"
  msg="unhealthy=[${unhealthy}] exited=[${exited}] running=${run}"
  prio=8
else
  title="anvil post-boot OK ${H}"
  msg="all ${run} containers running and healthy after boot"
  prio=3
fi
TOK=""
[ -f "${TOKEN_FILE}" ] && TOK=$(cat "${TOKEN_FILE}")
[ -n "${TOK}" ] && curl -s -m15 "${GOTIFY_URL}/message?token=${TOK}" \
  -F "title=${title}" -F "message=${msg}" -F "priority=${prio}" >/dev/null 2>&1
exit 0
