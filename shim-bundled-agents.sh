#!/bin/sh
#
# Build-time only (ADR 0002 History, 2026-09-25). Replace every bundled claude, codex and opencode,
# native binary or launcher script, under the given roots, with a shim that execs the matching
# /usr/local/bin wrapper, so every route Paperclip takes to an agent ends in containment.
# codex-code-mode-host has no wrapper and is only started by codex itself (the contained copy has its
# own), so bundled copies are disabled outright. Run in the SAME build step that creates the files,
# so the originals never reach an image layer. Prints how many it replaced.
set -eu
n=0
for f in $(find "$@" -xdev -type f \( -name claude -o -name claude.exe -o -name codex -o -name codex.exe \
             -o -name opencode -o -name opencode.exe -o -name codex-code-mode-host \) \
             ! -path '/opt/agent-clis/*' ! -path '/usr/local/bin/*' 2>/dev/null); do
  head -c 200 "$f" | grep -q 'by the Cloudron package' && continue   # already a shim
  case "${f##*/}" in
    claude|claude.exe) t=claude ;; codex|codex.exe) t=codex ;; opencode|opencode.exe) t=opencode ;; *) t= ;;
  esac
  rm -f "$f"
  if [ -n "$t" ]; then
    printf '#!/bin/sh\n# Replaced by the Cloudron package (ADR 0002): agents run contained, via the wrapper.\nexec /usr/local/bin/%s "$@"\n' "$t" > "$f"
  else
    printf '#!/bin/sh\necho "%s: disabled by the Cloudron package (ADR 0002)" >&2\nexit 126\n' "${f##*/}" > "$f"
  fi
  chmod 0755 "$f"
  n=$((n+1))
done
echo "$n"
