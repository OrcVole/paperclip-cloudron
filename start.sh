#!/bin/bash
#
# Entrypoint for Paperclip on Cloudron. Runs as root, prepares everything, installs the agent
# firewall, then execs the server as `cloudron` under tini. Decisions: docs/decisions/0001-0004.
# DRAFT from the design phase: the ownership list in step 1 is completed at the first real agent run.

set -euo pipefail
umask 0007

log()  { echo "==> [start] $*"; }
warn() { echo "==> [start] WARNING: $*" >&2; }
fail() { echo "==> [start] FATAL: $*" >&2; exit 1; }

DATA=/app/data
PHOME="${DATA}/paperclip"                      # PAPERCLIP_HOME
INST="${PHOME}/instances/default"
SECRETS="${DATA}/.secrets"                     # cloudron only: keys, config.json, first-admin invite
AGENT_HOME="${DATA}/agent-home"                # shared HOME of server and agents (ADR 0002 §5)
WORKSPACES=/app/workspaces                     # persistentDirs, not backed up (ADR 0003)
CONFIG="${SECRETS}/config.json"
ENV_FILE="${DATA}/env"                         # operator overrides

# ---------------------------------------------------------------------------------------------
# 1. Layout and ownership, on every boot: a restore returns files owned by an unmapped UID.
#    cloudron-only trees first, then the shared trees (group paperclip, setgid, 2770).
# ---------------------------------------------------------------------------------------------
mkdir -p "${SECRETS}" "${INST}" "${AGENT_HOME}" "${WORKSPACES}" "${INST}/data/storage" "${INST}/logs"
chown -R cloudron:cloudron "${PHOME}" "${SECRETS}"
chmod 0700 "${SECRETS}"
find "${SECRETS}" -type f -exec chmod 0600 {} +
# Shared trees keep each file's OWNER (P8, 2026-09-25): an agent tool owns its own state (Claude
# rewrites and re-permissions .credentials.json on every token refresh, which needs ownership), so a
# blanket chown to the server user would break a real login at the next boot. Only files a restore
# handed back with an unmapped owner (field guide #302) are re-owned: agent home to the agent user,
# workspaces to the server user. Either way the group is paperclip, group read-write, setgid dirs.
find "${AGENT_HOME}" -xdev \( -nouser -o -nogroup \) -exec chown pcagent:paperclip {} + 2>/dev/null || true
find "${WORKSPACES}" -xdev \( -nouser -o -nogroup \) -exec chown cloudron:paperclip {} + 2>/dev/null || true
for shared in "${AGENT_HOME}" "${WORKSPACES}"; do
  chown cloudron:paperclip "${shared}"
  chgrp -R paperclip "${shared}"
  chmod -R g+rwX "${shared}"
  find "${shared}" -type d -exec chmod g+s {} +
done
chmod 2770 "${AGENT_HOME}" "${WORKSPACES}"
# P6 adds here every further path a real agent run needs (each found as an EACCES), never a
# cloudron-only one. A needed cloudron-only path is a design problem: stop and escalate.

# ---------------------------------------------------------------------------------------------
# 2. Workspaces live in the persistent directory, outside the backup (ADR 0003).
# ---------------------------------------------------------------------------------------------
if [[ -d "${INST}/workspaces" && ! -L "${INST}/workspaces" ]]; then
  log "moving an existing workspaces directory into ${WORKSPACES}"
  cp -a "${INST}/workspaces/." "${WORKSPACES}/" && rm -rf "${INST}/workspaces"
fi
ln -sfn "${WORKSPACES}" "${INST}/workspaces"
# Managed project checkouts are git working trees too, so they live beside the agent workspaces,
# out of the backup, as the manifest checklist promises (ADR 0003). Upstream has no setting for
# either root (server/src/home-paths.ts), hence the links.
mkdir -p "${WORKSPACES}/projects"
chown cloudron:paperclip "${WORKSPACES}/projects"; chmod 2770 "${WORKSPACES}/projects"
if [[ -d "${INST}/projects" && ! -L "${INST}/projects" ]]; then
  log "moving an existing projects directory into ${WORKSPACES}/projects"
  cp -a "${INST}/projects/." "${WORKSPACES}/projects/" && rm -rf "${INST}/projects"
fi
ln -sfn "${WORKSPACES}/projects" "${INST}/projects"

# The server hands agents paths THROUGH the instance root (its workspace and project links, the
# Claude prompt bundle). So the three ancestors are traversable by the paperclip group, and not
# listable: 0710 (ADR 0002 History, 2026-09-25). Everything below them stays private to cloudron,
# because the server runs with umask 0007 and pcagent is not in the cloudron group. The few subtrees
# a run needs are granted just in time, read-only, by agent-wrapper.sh.
chgrp paperclip "${PHOME}" "${PHOME}/instances" "${INST}"
chmod 0710 "${PHOME}" "${PHOME}/instances" "${INST}"
# Copies from the image keep their 0644 mode whatever the umask; close anything open to "other".
find "${PHOME}" -xdev ! -type l -perm /o=rwx -exec chmod o-rwx {} + 2>/dev/null || true

# ---------------------------------------------------------------------------------------------
# 3. Secrets, generated once and never reseeded. The master key encrypts every stored secret:
#    losing it makes them unreadable, so a missing key over an initialised instance is fatal.
# ---------------------------------------------------------------------------------------------
gen() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
if [[ ! -s "${SECRETS}/master.key" ]]; then
  [[ -f "${SECRETS}/.initialised" ]] && fail "${SECRETS}/master.key is missing but this instance was already initialised." \
    "Generating a new key would make every stored secret unreadable. Restore the key from a backup."
  head -c 32 /dev/urandom > "${SECRETS}/master.key"
  log "generated the secrets master key (first run)"
fi
[[ -s "${SECRETS}/agent-jwt-secret" ]] || gen > "${SECRETS}/agent-jwt-secret"
[[ -s "${SECRETS}/tool-action-signing-secret" ]] || gen > "${SECRETS}/tool-action-signing-secret"
chown cloudron:cloudron "${SECRETS}"/*; chmod 0600 "${SECRETS}"/*

# ---------------------------------------------------------------------------------------------
# 4. Operator overrides, then the settings an operator may not override.
# ---------------------------------------------------------------------------------------------
# The operator's file is PARSED, never sourced. This script runs as root and /app/data is writable by the server user, so
# sourcing the file would turn anything that compromises the server into root (inside the container) at the next start.
# Only PAPERCLIP_* settings with a plain value pass; the settings an operator may not override are forced further down.
# The agent user can traverse /app/data, and a file made in the Web Terminal is 0644, so it could read this one, and some
# PAPERCLIP_* settings are secrets (measured 2026-10-31). Root only, at every start.
[[ -f "${ENV_FILE}" ]] && { chown root:root "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"; }
if [[ -f "${ENV_FILE}" ]]; then
  log "reading operator overrides from ${ENV_FILE} (parsed, not sourced)"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    if ! [[ "${k}" =~ ^PAPERCLIP_[A-Z0-9_]+$ ]]; then warn "env: ignoring '${k}' (only PAPERCLIP_* settings are read)"; continue; fi
    if ! [[ "${v}" =~ ^[A-Za-z0-9_.,:/@+=-]*$ ]]; then warn "env: ignoring ${k} (unsupported characters in the value)"; continue; fi
    export "${k}=${v}"
  done < "${ENV_FILE}"
fi

# Sign-up. The first admin claims the instance by signing up and then accepting the one-time invite, and an invite can only be
# accepted by a signed-in user (ADR 0004), so sign-up has to be open until an admin exists. From then on it is CLOSED at every start
# (a stranger reaching the URL cannot create an account). An explicit PAPERCLIP_AUTH_DISABLE_SIGN_UP in the operator's file wins.
if [[ -n "${PAPERCLIP_AUTH_DISABLE_SIGN_UP+x}" ]]; then
  case "${PAPERCLIP_AUTH_DISABLE_SIGN_UP}" in true|false) DISABLE_SIGN_UP="${PAPERCLIP_AUTH_DISABLE_SIGN_UP}";; *) warn "PAPERCLIP_AUTH_DISABLE_SIGN_UP must be true or false; using the automatic setting"; DISABLE_SIGN_UP=auto;; esac
else DISABLE_SIGN_UP=auto; fi
if [[ "${DISABLE_SIGN_UP}" == auto ]]; then
  admins="$(psql "${CLOUDRON_POSTGRESQL_URL}" -Atc "select count(*) from instance_user_roles where role = 'instance_admin'" 2>/dev/null || true)"
  if [[ "${admins}" =~ ^[0-9]+$ && "${admins}" -gt 0 ]]; then DISABLE_SIGN_UP=true; log "sign-up : closed (an instance admin exists)"
  else DISABLE_SIGN_UP=false; log "sign-up : OPEN until the first admin has claimed this instance; restart the app once afterwards to close it"; fi
else log "sign-up : ${DISABLE_SIGN_UP} (set by PAPERCLIP_AUTH_DISABLE_SIGN_UP)"; fi

# ---------------------------------------------------------------------------------------------
# 5. config.json: the database URL goes here, never into the environment (ADR 0002 §4).
# ---------------------------------------------------------------------------------------------
jq -n --arg db "${CLOUDRON_POSTGRESQL_URL}" --arg url "https://${CLOUDRON_APP_DOMAIN}" \
      --arg inst "${INST}" --arg key "${SECRETS}/master.key" --argjson nosignup "${DISABLE_SIGN_UP}" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
  "$meta": {version: 1, updatedAt: $now, source: "configure"},
  database: {mode: "postgres", connectionString: $db, backup: {enabled: false}},
  logging: {mode: "file", logDir: ($inst + "/logs")},
  server: {deploymentMode: "authenticated", exposure: "public", host: "0.0.0.0", port: 3100, serveUi: true},
  telemetry: {enabled: false},
  auth: {baseUrlMode: "explicit", publicBaseUrl: $url, disableSignUp: $nosignup},
  storage: {provider: "local_disk", localDisk: {baseDir: ($inst + "/data/storage")}},
  secrets: {provider: "local_encrypted", localEncrypted: {keyFilePath: $key}}
}' > "${CONFIG}"
chown cloudron:cloudron "${CONFIG}"; chmod 0600 "${CONFIG}"

# ---------------------------------------------------------------------------------------------
# 6. The agent firewall (ADR 0002 §3). Agents are enabled only if every rule installs AND a
#    self-test from the agent UID is refused on the database. Otherwise the wrappers refuse.
# ---------------------------------------------------------------------------------------------
mkdir -p /run/paperclip && chmod 0755 /run/paperclip && rm -f /run/paperclip/agents-enabled /run/paperclip/test-mode
AGENT_UID=61001
fw_ok=1
ns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)"
v4() { iptables  -A OUTPUT -m owner --uid-owner "${AGENT_UID}" "$@" || fw_ok=0; }
v6() { ip6tables -A OUTPUT -m owner --uid-owner "${AGENT_UID}" "$@" || fw_ok=0; }
if command -v iptables >/dev/null && iptables -S OUTPUT >/dev/null 2>&1; then
  for p in udp tcp; do v4 -d "${ns}" -p "${p}" --dport 53 -j ACCEPT; done
  v4 -d 127.0.0.1 -p tcp --dport 3100 -j ACCEPT
  v4 -d 172.18.0.1 -p tcp --dport 443 -j ACCEPT          # the reverse proxy, front door only
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do v4 -d "${net}" -j REJECT; done
  for port in 25 465 587; do v4 -p tcp --dport "${port}" -j REJECT; done
  for net in fc00::/7 fe80::/10; do v6 -d "${net}" -j REJECT; done
  for port in 25 465 587; do v6 -p tcp --dport "${port}" -j REJECT; done
else
  fw_ok=0
fi
if (( fw_ok )) && timeout 4 setpriv --reuid="${AGENT_UID}" --regid=61000 --clear-groups \
     bash -c "echo > /dev/tcp/${CLOUDRON_POSTGRESQL_HOST}/${CLOUDRON_POSTGRESQL_PORT:-5432}" 2>/dev/null; then
  warn "self-test: the agent UID reached the database despite the rules"; fw_ok=0
fi
if (( fw_ok )); then
  touch /run/paperclip/agents-enabled
  log "agents   : enabled; firewall active for UID ${AGENT_UID} (v4 and v6), self-test refused as expected"
else
  warn "agents   : DISABLED. The agent firewall could not be installed or did not hold (is the net_admin" \
       "capability granted?). Local agents will refuse to run; gateway and HTTP agents still work."
fi

# ---------------------------------------------------------------------------------------------
# 7. The server's environment: only what it needs, then drop every CLOUDRON_* variable.
# ---------------------------------------------------------------------------------------------
export HOME="${AGENT_HOME}" PAPERCLIP_HOME="${PHOME}" PAPERCLIP_INSTANCE_ID=default PAPERCLIP_CONFIG="${CONFIG}"
export PAPERCLIP_DEPLOYMENT_MODE=authenticated PAPERCLIP_DEPLOYMENT_EXPOSURE=public
export PAPERCLIP_PUBLIC_URL="https://${CLOUDRON_APP_DOMAIN}" PAPERCLIP_API_URL=http://127.0.0.1:3100
export HOST=0.0.0.0 PORT=3100 SERVE_UI=true NODE_ENV=production TRUST_PROXY=uniquelocal
export PAPERCLIP_MIGRATION_AUTO_APPLY=true PAPERCLIP_DB_BACKUP_ENABLED=false
export PAPERCLIP_SECRETS_MASTER_KEY_FILE="${SECRETS}/master.key"
export PAPERCLIP_AGENT_JWT_SECRET="$(cat "${SECRETS}/agent-jwt-secret")"
export PAPERCLIP_TOOL_ACTION_SIGNING_SECRET="$(cat "${SECRETS}/tool-action-signing-secret")"
export PAPERCLIP_TELEMETRY_DISABLED="${PAPERCLIP_TELEMETRY_DISABLED:-1}"
export PAPERCLIP_ANNOUNCEMENTS_ENABLED="${PAPERCLIP_ANNOUNCEMENTS_ENABLED:-false}"
# A JSON default inside ${VAR:-...} misparses (the first } ends the expansion), so assign it apart.
[[ -n "${PAPERCLIP_SETTING_DEFAULTS:-}" ]] || PAPERCLIP_SETTING_DEFAULTS='{"feedbackDataSharingPreference":"not_allowed"}'
export PAPERCLIP_SETTING_DEFAULTS
export PAPERCLIP_HIDDEN_SETTINGS="instance.experimental.enableNativeRunner${PAPERCLIP_HIDDEN_SETTINGS:+,${PAPERCLIP_HIDDEN_SETTINGS}}"
export PAPERCLIP_DISABLE_CWD_ENV_FILE=true
# ACP bridges start their agent from these, or from a bundled copy when unset (ADR 0002 History,
# 2026-09-25). Point both at the wrappers, so an ACP run crosses to the agent user exactly as a CLI
# run does. The Dockerfile's shims make an unset or overridden variable fail closed anyway.
export CLAUDE_CODE_EXECUTABLE=/usr/local/bin/claude CODEX_PATH=/usr/local/bin/codex
APP_DOMAIN="${CLOUDRON_APP_DOMAIN}"
while IFS= read -r v; do [[ "${v}" == CLOUDRON_* ]] && unset "${v}"; done < <(compgen -e)
unset BETTER_AUTH_SECRET DATABASE_URL || true

# ---------------------------------------------------------------------------------------------
# 8. First admin, once (ADR 0004): after the server answers, if no admin exists, make a one-time
#    invite, print it, and keep a copy. This subshell outlives the exec below.
# ---------------------------------------------------------------------------------------------
(
  for _ in $(seq 1 180); do
    h="$(curl -fsS -m 5 http://127.0.0.1:3100/api/health 2>/dev/null || true)"
    [[ "${h}" == *'"status":"ok"'* ]] && break; sleep 2
  done
  if [[ "${h:-}" == *bootstrap_pending* && "${h}" != *'"bootstrapInviteActive":true'* ]]; then
    out="$(gosu cloudron /opt/paperclip-cli/bin/paperclipai auth bootstrap-ceo --base-url "https://${APP_DOMAIN}" 2>&1 || true)"
    url="$(grep -oE 'https://[^ ]+/invite/[A-Za-z0-9_-]+' <<< "${out}" | head -1)"
    if [[ -n "${url}" ]]; then
      printf '%s\n' "${url}" > "${SECRETS}/first-admin-invite"
      chown cloudron:cloudron "${SECRETS}/first-admin-invite"; chmod 0600 "${SECRETS}/first-admin-invite"
      echo "==> [start] ================================================================"
      echo "==> [start] FIRST ADMIN: open this one-time link to create the admin account."
      echo "==> [start] Treat it as a password. It is single-use and expires in 72 hours."
      echo "==> [start]   ${url}"
      echo "==> [start] A copy is in ${SECRETS}/first-admin-invite (Terminal: cat it)."
      echo "==> [start] ================================================================"
    else
      echo "==> [start] WARNING: could not create the first-admin invite: ${out}" >&2
    fi
  elif [[ -s "${SECRETS}/first-admin-invite" && "${h:-}" == *bootstrap_pending* ]]; then
    echo "==> [start] FIRST ADMIN: an invite is still active; it is in ${SECRETS}/first-admin-invite"
  fi
  touch "${SECRETS}/.initialised" 2>/dev/null || true
) &

log "exec     : paperclip server as cloudron (public URL https://${APP_DOMAIN})"
cd /app/code
exec /usr/bin/tini -- gosu cloudron node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js
