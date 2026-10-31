#!/bin/bash
# The containment probe, run AS pcagent through the real path (wrapper -> sudo -> agent-launch.sh),
# only when root has set /run/paperclip/test-mode. Prints one line per check: ALLOW or DENY.
# test/containment.sh decides which answer each check must give. Arg 1: the server's PID.
t()  { timeout 4 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null && echo "ALLOW net $1:$2" || echo "DENY  net $1:$2"; }
r()  { head -c 1 "$1" >/dev/null 2>&1 && echo "ALLOW read $1" || echo "DENY  read $1"; }
echo "WHOAMI $(id -u):$(id -g)"
echo "CANARIES $(env | grep -c 'PAPERCLIP-CANARY')"
echo "SECRETVARS $(env | grep -c -E '^(CLOUDRON_|DATABASE_|BETTER_AUTH_|PAPERCLIP_AGENT_JWT_SECRET|PAPERCLIP_SECRETS_|PAPERCLIP_TOOL_ACTION_SIGNING_SECRET)')"
r /app/data/.secrets/master.key; r /app/data/.secrets/config.json; r /app/data/.secrets/agent-jwt-secret
r "/proc/${1:-1}/environ"; r /proc/1/environ
echo x > /app/data/agent-home/.probe 2>/dev/null && echo "ALLOW write agent-home" || echo "DENY  write agent-home"
echo x > /app/workspaces/.probe 2>/dev/null && echo "ALLOW write workspaces" || echo "DENY  write workspaces"
rm -f /app/data/agent-home/.probe /app/workspaces/.probe
for h in postgresql:5432 mysql:3306 mongodb:27017; do n=${h%:*}; p=${h#*:}
  for ip in $(getent ahosts "$n" | awk '{print $1}' | sort -u); do t "$ip" "$p"; done; done
t 172.18.0.1 22; t 172.18.0.1 443; t 127.0.0.1 3100
[[ -n "${PROBE_OTHER_APP:-}" ]] && t "${PROBE_OTHER_APP%:*}" "${PROBE_OTHER_APP#*:}"
t smtp.gmail.com 25; t smtp.gmail.com 587
getent hosts example.com >/dev/null && echo "ALLOW dns" || echo "DENY  dns"
t example.com 443
