# Changelog

[1.0.1]

- The operator settings file `/app/data/env` is made readable by root only at every start. A file created in the Web
  Terminal was readable by the agent user, and some `PAPERCLIP_*` settings are secrets.

[1.0.0]

- First release. Paperclip 2026.1023.0 (upstream release v2026.1023.0, 2026-10-24), built from source
  on `cloudron/base:6.0.1` with Node.js 24.22.1 (security release).
- Sign-up is open only until the first admin has claimed the instance, and is closed automatically at the next start after
  that. Restart the app once after claiming it. An explicit `PAPERCLIP_AUTH_DISABLE_SIGN_UP` in `/app/data/env` wins.
- The operator's `/app/data/env` file is read line by line and never executed.
- Local coding agents (Claude Code, Codex, OpenCode) run as a separate, unprivileged user, reached
  only through a wrapper that firewalls their outbound network and strips server secrets from their
  environment. This holds for Paperclip's ACP engine too (its bundled agent binaries are routed back
  through the wrapper). See the package `docs/decisions/0002-agent-containment.md` for what this does and does
  not protect against.
- Agent workspaces are kept outside Cloudron's backup, because they are large, change constantly,
  and are git checkouts that Paperclip rebuilds from your repositories. Anything an agent has not
  committed and pushed is not backed up.
- No single sign-on: Paperclip supports email and password sign-in only. There is no password reset
  by email; recovery needs an administrator.
