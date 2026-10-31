#!/bin/bash
#
# The containment gate (ADR 0002 §7). Run INSIDE the app container as root:
#   podman exec <container> /app/pkg/test/containment.sh          (local build check)
#   cloudron exec --app <app> -- /app/pkg/test/containment.sh      (the real gate, on a box)
# Optional: PROBE_OTHER_APP=<ip>:<port> of another app's container, which must be refused.
# Exit 0 only if every assertion holds. A single failure is a failed build.

set -u
fails=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails+1)); }

# 1. Build invariants.
suid="$(find / -xdev -perm -4000 -type f 2>/dev/null | sort | tr '\n' ' ')"
[[ "${suid}" == "/usr/bin/sudo.ws " ]] && ok "only sudo (sudo.ws) is setuid" || bad "setuid binaries: ${suid:-none}"
sgid="$(find / -xdev -perm -2000 -type f 2>/dev/null | tr '\n' ' ')"
[[ -z "${sgid}" ]] && ok "no setgid binaries" || bad "setgid binaries: ${sgid}"
[[ -z "$(find / -xdev -name paperclip-runnerd -type f 2>/dev/null | head -1)" ]] && ok "no native runner binary" || bad "paperclip-runnerd is present"
[[ -f /run/paperclip/agents-enabled ]] && ok "agents enabled (firewall installed and self-tested)" \
  || bad "agents are disabled: the firewall is not active (no net_admin?). Nothing below is meaningful"

# 1b. Bundled agent copies (ADR 0002 History, 2026-09-25). Paperclip's ACP bridges run the agent from
#     the SDK's own platform packages, as the server user, unless redirected. Every copy outside
#     /opt/agent-clis must be a shim to a wrapper, and the paths the bridges actually use must end in
#     the contained binary. The real binaries are executable by pcagent only, so a bundled path that
#     runs as cloudron and prints the pinned version can only have gone through the wrapper and sudo.
big="$(find / -xdev -type f \( -name claude -o -name claude.exe -o -name codex -o -name codex.exe -o -name opencode \
        -o -name opencode.exe -o -name codex-code-mode-host \) -size +4k ! -path '/opt/agent-clis/*' ! -path '/proc/*' 2>/dev/null)"
[[ -z "${big}" ]] && ok "no bundled agent binary outside /opt/agent-clis" || bad "bundled agent binaries remain: ${big//$'\n'/ }"
# Read as the server's own user: root in a Cloudron container has no CAP_SYS_PTRACE, so it cannot.
[[ "$(su cloudron -s /bin/bash -c "tr '\\0' '\\n' < /proc/$(pgrep -u cloudron -f 'server/dist/index.js' | head -1)/environ" 2>/dev/null \
      | grep -E '^(CLAUDE_CODE_EXECUTABLE|CODEX_PATH)=' | sort | tr '\n' ' ')" \
   == "CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude CODEX_PATH=/usr/local/bin/codex " ]] \
  && ok "the server points the ACP bridges at the wrappers" || bad "CLAUDE_CODE_EXECUTABLE / CODEX_PATH not set to the wrappers in the server"
touch /run/paperclip/test-mode
witness() {  # witness <tool> <command...>: run as the server user, report the launcher's witness line
  local tool="$1"; shift
  su cloudron -s /bin/bash -c "cd /app/workspaces && PAPERCLIP_CONTAINMENT_WITNESS=1 PATH=/usr/local/node-24.22.1/bin:\$PATH $*" 2>&1 >/dev/null \
    | grep -m1 -oE "^LAUNCHED ${tool} AS [0-9]+"
}
sdk="$(find /app/code/node_modules/.pnpm -path '*claude-agent-sdk-linux-x64/claude' -type f 2>/dev/null | head -1)"
cjs="$(find /app/code/node_modules/.pnpm -path '*@openai/codex/bin/codex.js' -type f 2>/dev/null | head -1)"
ocx="$(find /app/code/node_modules/.pnpm -path '*opencode-ai/bin/opencode.exe' -type f 2>/dev/null | head -1)"
[[ -n "${sdk}" && "$(witness claude "'${sdk}' --version")" == "LAUNCHED claude AS 61001" ]] \
  && ok "the SDK's bundled claude (ACP engine) runs as pcagent, through the launcher" \
  || bad "the SDK's bundled claude path bypasses the launcher (${sdk:-not found})"
[[ -n "${cjs}" && "$(witness codex "node '${cjs}' --version")" == "LAUNCHED codex AS 61001" ]] \
  && ok "codex-acp's bundled codex runs as pcagent, through the launcher" \
  || bad "codex-acp's bundled codex path bypasses the launcher (${cjs:-not found})"
[[ -n "${ocx}" && "$(witness opencode "'${ocx}' --version")" == "LAUNCHED opencode AS 61001" ]] \
  && ok "the bundled opencode runs as pcagent, through the launcher" \
  || bad "the bundled opencode path bypasses the launcher (${ocx:-not found})"
[[ "$(witness claude /usr/local/bin/claude --version)" == "LAUNCHED claude AS 61001" ]] \
  && ok "the witness itself works: the claude wrapper reports the launcher as pcagent" \
  || bad "the witness did not fire on the wrapper itself, so the checks above prove nothing"
rm -f /run/paperclip/test-mode

# 1c. The launch-settings hardening patch is compiled into the server (ADR 0002 History, 2026-09-25).
#     It is proven per round on a throwaway (gate-ladder). Here, cheaply: the patch's message is in the dist.
grep -rq "Agent keys cannot modify the adapter launch command" /app/code/server/dist \
  && ok "the agent adapter-launch guard is compiled into the server" \
  || bad "the agent adapter-launch guard is missing from the server (patch not applied)"

# 2. The server user's side of the door.
# Test the permission itself: running the tool could also fail because node is not on su's PATH,
# which would pass this check for the wrong reason.
su cloudron -s /bin/bash -c 'test -x /opt/agent-clis/bin/claude' \
  && bad "the server user can run a real agent tool directly" || ok "the server user cannot run agent tools directly (no execute permission)"
su cloudron -s /bin/bash -c 'sudo -n id' >/dev/null 2>&1 && bad "sudo to root is allowed" || ok "sudo to root is refused"
su cloudron -s /bin/bash -c 'sudo -n -u pcagent /bin/true' >/dev/null 2>&1 && bad "sudo allows arbitrary commands as pcagent" \
  || ok "sudo allows only the launcher"

# 3. The agent's side: the probe through the REAL path, with canary secrets planted in the
#    environment the server would pass (they must not arrive).
touch /run/paperclip/test-mode
srv="$(pgrep -u cloudron -f 'server/dist/index.js' | head -1)"
out="$(su cloudron -s /bin/bash -c "export CLOUDRON_POSTGRESQL_PASSWORD=PAPERCLIP-CANARY-1 DATABASE_URL=PAPERCLIP-CANARY-2 \
  BETTER_AUTH_SECRET=PAPERCLIP-CANARY-3 PAPERCLIP_AGENT_JWT_SECRET=PAPERCLIP-CANARY-4 PROBE_OTHER_APP='${PROBE_OTHER_APP:-}'; \
  cd /app/workspaces && sudo -E -n -u pcagent /app/pkg/agent-launch.sh __probe ${srv:-1}" 2>&1)"
rm -f /run/paperclip/test-mode
echo "${out}" | sed 's/^/    probe: /'
want() {  # want <ALLOW|DENY> <pattern> <label>
  local line; line="$(grep -E "^(ALLOW|DENY) +$2" <<< "${out}" | head -1)"
  [[ -z "${line}" ]] && { bad "$3: no probe result"; return; }
  [[ "${line}" == "$1"* ]] && ok "$3" || bad "$3 (got: ${line})"
}
[[ "$(grep -oE '^WHOAMI [0-9]+' <<< "${out}")" == "WHOAMI 61001" ]] && ok "the probe ran as pcagent (61001)" || bad "the probe did not run as pcagent"
[[ "$(grep -oE '^CANARIES [0-9]+' <<< "${out}")" == "CANARIES 0" ]] && ok "no canary secret reached the agent" || bad "a canary secret reached the agent"
[[ "$(grep -oE '^SECRETVARS [0-9]+' <<< "${out}")" == "SECRETVARS 0" ]] && ok "no secret-named variable reached the agent" || bad "secret-named variables reached the agent"
want DENY  "read /app/data/.secrets/master.key"      "agent cannot read the master key"
want DENY  "read /app/data/.secrets/config.json"     "agent cannot read config.json"
want DENY  "read /app/data/.secrets/agent-jwt-secret" "agent cannot read the JWT secret"
want DENY  "read /proc/${srv:-1}/environ"            "agent cannot read the server's environment"
want ALLOW "write agent-home"                        "agent can write its home"
want ALLOW "write workspaces"                        "agent can write the workspaces"
while read -r l; do [[ "${l}" == ALLOW* ]] && bad "agent reached an add-on database: ${l}"; done \
  < <(grep -E ':(5432|3306|27017)$' <<< "${out}")
grep -qE ':(5432|3306|27017)$' <<< "${out}" && ok "add-on database checks ran (every address must be DENY above)" || bad "no add-on address resolved; the database checks did not run"
want DENY  "net 172.18.0.1:22"   "agent cannot reach the gateway on other ports"
want ALLOW "net 172.18.0.1:443"  "agent reaches the reverse proxy (front door)"
want ALLOW "net 127.0.0.1:3100"  "agent reaches the Paperclip API"
[[ -n "${PROBE_OTHER_APP:-}" ]] && want DENY "net ${PROBE_OTHER_APP}" "agent cannot reach another app's container"
want DENY  "net smtp.gmail.com:25"  "agent cannot send mail on 25"
want DENY  "net smtp.gmail.com:587" "agent cannot send mail on 587"
want ALLOW "dns"                   "agent resolves DNS"
want ALLOW "net example.com:443"   "agent reaches the internet"

# 4. The instance root (ADR 0002 History, 2026-09-25): traverse-only for the agent, private below.
I=/app/data/paperclip/instances/default
asagent() { su pcagent -s /bin/bash -c "$1" >/dev/null 2>&1; }
asagent "ls '${I}'" && bad "the agent can list the instance root" || ok "the agent cannot list the instance root"
asagent "cd '${I}/workspaces/.'" && ok "the agent reaches its workspaces through the instance root" || bad "the agent cannot traverse to ${I}/workspaces"
asagent "ls '${I}/data'" && bad "the agent can list the instance data (run logs, traces, storage)" || ok "the agent cannot list the instance data (run logs, traces, storage)"
asagent "ls '${I}/companies'" && bad "the agent can list the companies (and so find other companies)" || ok "the agent cannot list the companies"
# A run's own company directory is granted read-only (agent-wrapper.sh). It must never become writable.
acp="$(find "${I}/companies" -mindepth 2 -maxdepth 2 -name acp-engine -type d 2>/dev/null | head -1)"
if [[ -n "${acp}" ]]; then
  asagent "touch '${acp}/.containment-write-test'" && { bad "the agent can write the ACP session store"; rm -f "${acp}/.containment-write-test"; } \
    || ok "the agent cannot write the ACP session store"
fi
open="$(find /app/data/paperclip -xdev ! -type l -perm /o=rwx 2>/dev/null | head -3 | tr '\n' ' ')"
[[ -z "${open}" ]] && ok "nothing under the Paperclip home is open to other users" || bad "entries open to other users: ${open}"

echo; echo "=== containment: ${fails} failure(s) ==="
exit $(( fails > 0 ? 1 : 0 ))
