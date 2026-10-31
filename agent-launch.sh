#!/bin/bash
#
# The only door from the Paperclip server (user cloudron) to an agent tool (user pcagent), reached as
#   sudo -E -n -u pcagent /app/pkg/agent-launch.sh <tool> [args...]
# through the one sudoers rule in /etc/sudoers.d/paperclip. ADR 0002 is the design; test/containment.sh
# is the proof. It runs as pcagent, with the environment the server passed (-E, allowed by SETENV).
#
# Environment: users give agents arbitrary variables through Paperclip, so an allowlist would break
# them. Instead the server's own environment is minimal by construction (start.sh), upstream already
# strips inherited PAPERCLIP_* names, and this denylist removes anything that must never reach an
# agent even if a future release starts passing it.

set -u

if [[ ! -f /run/paperclip/agents-enabled ]]; then
  echo "paperclip: local agents are disabled because the containment firewall is not active (see the app log)" >&2
  exit 126
fi

tool="${1:-}"; shift || true
case "${tool}" in
  claude|codex|opencode) target="/opt/agent-clis/bin/${tool}" ;;
  # The containment suite's probe. Only root can create the test-mode flag (/run/paperclip is root's),
  # so neither the server nor an agent can reach this branch in normal operation.
  __probe) [[ -f /run/paperclip/test-mode ]] || { echo "paperclip: not in test mode" >&2; exit 2; }
           target=/app/pkg/test/as-agent.sh ;;
  *) echo "paperclip: unknown agent tool '${tool}'" >&2; exit 2 ;;
esac

# The containment gate's witness (test/containment.sh 1b): in test mode only, say that this door was
# used, and as whom. A path that bypasses the launcher cannot print it, whatever version it reports.
[[ -f /run/paperclip/test-mode && -n "${PAPERCLIP_CONTAINMENT_WITNESS:-}" ]] && echo "LAUNCHED ${tool} AS $(id -u)" >&2

while IFS= read -r v; do
  case "${v}" in
    CLOUDRON_*|DATABASE_*|BETTER_AUTH_*|PG*|PAPERCLIP_AGENT_JWT_SECRET|PAPERCLIP_SECRETS_*|\
    PAPERCLIP_TOOL_ACTION_SIGNING_SECRET|PAPERCLIP_CONFIG|LD_*|NODE_OPTIONS|NODE_EXTRA_CA_CERTS_UNSAFE)
      unset "${v}" ;;
  esac
done < <(compgen -e)

# TMPDIR, carried across the sudo crossing by agent-wrapper.sh (the C library strips it from setuid
# programs). Restored only if it is a per-run paperclip directory under /tmp with no "..".
if [[ "${PAPERCLIP_AGENT_TMPDIR:-}" == /tmp/paperclip-* && "${PAPERCLIP_AGENT_TMPDIR}" != *..* ]]; then
  export TMPDIR="${PAPERCLIP_AGENT_TMPDIR}"
fi
unset PAPERCLIP_AGENT_TMPDIR
export HOME=/app/data/agent-home
# The server side points ACP bridges at the wrappers (start.sh). Inside the agent those same names must
# point at the contained binaries: the agent user has no sudo rule, so a wrapper would refuse it.
export CLAUDE_CODE_EXECUTABLE=/opt/agent-clis/bin/claude CODEX_PATH=/opt/agent-clis/bin/codex
# The agent tools are Node scripts; cloudron/base keeps Node off the default PATH.
export PATH=/opt/agent-clis/bin:/usr/local/node-24.22.1/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
umask 0007
ulimit -c 0
ulimit -u 256        # processes for this UID (field guide #306: count with ps, not a bash loop)
ulimit -f 2097152    # 2 GiB per file, in KiB; it does not cap the total (see ADR 0002)

# Debugging aid, off by default: with /run/paperclip/debug-agent present (only root can create it:
# `touch /run/paperclip/debug-agent` in a Web Terminal), each run's command line, working directory,
# environment NAMES and stderr are also written to /tmp/paperclip-agent-debug-<tool>-<pid>.log (0600).
# Values are never logged, and bearer tokens in the arguments are masked. ACP bridges swallow the
# agent's stderr, so this is how an "Internal error" from a bridge gets its real cause.
if [[ -f /run/paperclip/debug-agent ]]; then
  dbg="/tmp/paperclip-agent-debug-${tool}-$$.log"
  ( umask 0077
    { echo "=== $(date -Is) ${tool} as $(id -u)"; echo "cwd: ${PWD}"
      echo "args: $*" | sed -E 's/(Bearer )[A-Za-z0-9._~+/=-]+/\1<masked>/g; s/("[Aa]uthorization" *: *")[^"]*/\1<masked>/g'
      echo "env: $(compgen -e | sort | tr '\n' ' ')"; } >> "${dbg}" )
  exec 2> >(tee -a "${dbg}" >&2)
fi

exec "${target}" "$@"
