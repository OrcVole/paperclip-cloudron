#!/bin/bash -p
#
# The server-side half of the agent door (ADR 0002). Runs as the server user (cloudron), called by the
# /usr/local/bin/{claude,codex,opencode} wrappers, then crosses to pcagent through the one sudoers rule.
#
# Hardening (ADR 0002 History, 2026-09-25): `-p` makes bash ignore BASH_ENV/ENV and imported shell
# functions, and the first lines pin PATH and clear those names, so nothing an adapter config passes
# through can steer the commands this script runs as the server user.
export PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
unset BASH_ENV ENV CDPATH
#
# Before crossing, it grants the paperclip group access to exactly the paths THIS run was handed (in
# its working directory, its environment and its arguments), and only inside an allowlist:
#
#  * Per-run temp directories (P6, 2026-09-24). Paperclip's adapters mkdtemp private directories
#    (0700, prefixed paperclip-) under the temp dir and pass them in variables such as
#    XDG_CONFIG_HOME, CODEX_HOME and CLAUDE_CONFIG_DIR. Read-write, because they are the run's own.
#  * Paths under the instance root (2026-09-25). The server hands agents paths through
#    /app/data/paperclip/instances/default, which is private to cloudron apart from its traverse-only
#    ancestors (start.sh). workspaces/ and projects/ are links into /app/workspaces and already
#    shared. The run's OWN company directory (companies/<PAPERCLIP_COMPANY_ID>) is granted READ-ONLY:
#    upstream widens Claude's read roots to it on purpose (acpx-engine writePaperclipClaudeSettings:
#    state dir, skills bundle, instructions, prompt cache). Its codex-home, when handed as CODEX_HOME,
#    is read-write, because Codex keeps its sessions there. Skills (skills/<id>/...) and runtime
#    context bundles (runtime-context-assets/bundles/<digest>) are read-only. Nothing else is
#    granted: a run that needs another path fails closed with EACCES, visibly, and gets decided in
#    ADR 0002. Within one company this exposes what ADR 0002 already accepts: agents share a UID.
#
# A run's working directory can come from agent configuration, so a path with a "." or ".." component
# is never granted, and neither is a symlink: the grant must not be steerable outside its subtree.

tool="$1"; shift
# Fixed, not ${TMPDIR}: Paperclip points TMPDIR at the run's own scratch directory (/tmp/paperclip-run-*),
# so deriving the root from it would look for paperclip-* INSIDE that directory and grant nothing.
tmp=/tmp
INST=/app/data/paperclip/instances/default

# o-rwx too: Paperclip copies bundled skills out of the image with their 0644 mode (a copy keeps the
# mode and ignores the umask), and nothing under the instance root is for "other".
readonly_grant() { chgrp -R paperclip "$1" 2>/dev/null; chmod -R g+rX,g-w,o-rwx "$1" 2>/dev/null; }
traverse()       { chgrp paperclip "$1" 2>/dev/null; chmod g+x,g-rw "$1" 2>/dev/null; }

grant_tmp() {  # a path under the temp dir: its top-level paperclip-* directory, read-write
  local top
  top="$tmp/$(printf '%s' "${1#"$tmp"/}" | cut -d/ -f1)"
  case "$top" in "$tmp"/paperclip-*) ;; *) return 0 ;; esac
  if [ -d "$top" ] && [ ! -L "$top" ] && [ -O "$top" ]; then
    chgrp -R paperclip "$top" 2>/dev/null
    chmod -R g+rwX "$top" 2>/dev/null
    find "$top" -type d -exec chmod g+s {} + 2>/dev/null
  fi
}

grant_inst() {  # a path under the instance root: only the allowlisted subtrees, read-only
  local rel="${1#"$INST"/}" c1 c2 c3 c4 d t l
  case "/$rel/" in */./*|*/../*|*//*) return 0 ;; esac
  IFS=/ read -r c1 c2 c3 c4 _ <<< "$rel"
  case "$c1" in
    workspaces|projects) ;;
    companies)
      # Only the run's own company (granted read-only by grant_company); here, the one writable
      # subtree, and the skill sources that a prompt bundle links to.
      [ -n "$c2" ] && [ "$c2" = "${company_ok:-}" ] || return 0
      if [ "$c3" = codex-home ]; then
        d="$INST/companies/$c2/codex-home"
        [ -d "$d" ] && [ ! -L "$d" ] || return 0
        chgrp -R paperclip "$d" 2>/dev/null; chmod -R g+rwX "$d" 2>/dev/null
        find "$d" -type d -exec chmod g+s {} + 2>/dev/null
      fi
      while IFS= read -r l; do
        t="$(readlink -f "$l")"
        case "$t" in "$INST"/skills/*) grant_inst "$t" ;; esac
      done < <(find "$INST/companies/$c2" -type l 2>/dev/null)
      ;;
    skills)
      [ -n "$c2" ] || return 0
      d="$INST/skills/$c2${c3:+/$c3}"
      [ -e "$d" ] && [ ! -L "$d" ] || return 0
      traverse "$INST/skills"; traverse "$INST/skills/$c2"
      readonly_grant "$d"
      ;;
    runtime-context-assets)
      [ "$c2" = bundles ] && [ -n "$c3" ] || return 0
      d="$INST/runtime-context-assets/bundles/$c3"
      [ -d "$d" ] && [ ! -L "$d" ] || return 0
      traverse "$INST/runtime-context-assets"; traverse "$INST/runtime-context-assets/bundles"
      readonly_grant "$d"
      ;;
  esac
}

grant_all_in() {  # every temp-dir or instance-root path mentioned anywhere in the given text
  local p
  while IFS= read -r p; do
    case "$p" in
      "$tmp"/paperclip-*) grant_tmp "$p" ;;
      "$INST"/*) grant_inst "$p" ;;
    esac
  done < <(printf '%s\n' "$1" | grep -oE "(${tmp}/paperclip-|${INST}/)[^[:space:]\"',;:]*")
}

grant_company() {  # the run's own company directory, read-only; the id must be a well-formed UUID
  local cid="${PAPERCLIP_COMPANY_ID:-}" d
  [[ "$cid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 0
  d="$INST/companies/$cid"
  [ -d "$d" ] && [ ! -L "$d" ] || return 0
  traverse "$INST/companies"
  readonly_grant "$d"
  company_ok="$cid"
}

company_ok=
grant_company
grant_all_in "$PWD"
while IFS= read -r -d '' kv; do grant_all_in "${kv#*=}"; done < <(env -0)
for a in "$@"; do grant_all_in "$a"; done

# sudo is setuid, and the C library strips TMPDIR from a setuid program's environment, so it would
# never reach the agent. Carry it across under another name; agent-launch.sh restores it after checking.
export PAPERCLIP_AGENT_TMPDIR="${TMPDIR:-}"
exec sudo -E -n -u pcagent /app/pkg/agent-launch.sh "$tool" "$@"
