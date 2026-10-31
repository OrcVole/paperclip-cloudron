# 0004: Authenticated public mode; first admin from a one-time invite in the log

Status: accepted, 2026-09-24. The sign-up question is settled at gate 1.

## Context

Paperclip's only human sign-in is email and password (Better Auth). There is no OIDC; a community
pull request for it is unmerged. The server sends no email, so there is no password reset.

The deployment modes (`doc/DEPLOYMENT-MODES.md`):
- **`authenticated/private`** has a browser "claim this instance" where **the first signed-in session
  becomes admin**. Upstream limits it to trusted networks. It also puts a Host-header allowlist in
  front of the health check.
- **`authenticated/public`** requires an explicit public URL, enables rate limiting, and gets its
  first admin from a one-time invite made by `paperclipai auth bootstrap-ceo`, which the server image
  never runs by itself.

Sign-up is open by default (`PAPERCLIP_AUTH_DISABLE_SIGN_UP`). Invitees create their account through
the same sign-up endpoint, so whether invites still work with sign-up off is unverified.

## Decision

- **Mode and URLs:**
  - `PAPERCLIP_DEPLOYMENT_MODE=authenticated`, `PAPERCLIP_DEPLOYMENT_EXPOSURE=public`;
  - `PAPERCLIP_PUBLIC_URL=https://$CLOUDRON_APP_DOMAIN`;
  - `PAPERCLIP_API_URL=http://127.0.0.1:3100`, so agents call the server directly and not through
    the proxy;
  - `TRUST_PROXY` set for the Cloudron reverse proxy.
- **Addons:** no `oidc`, no `sendmail`, and **never `proxyAuth`**. It would break agent API keys,
  command-line login, invites, MCP gateways and every webhook.
- **The first admin, at first boot only** (no admin yet, per `/api/health`'s `bootstrapStatus`):
  - `start.sh` runs `paperclipai auth bootstrap-ceo --base-url https://$CLOUDRON_APP_DOMAIN`;
  - it prints the invite URL prominently in the app log;
  - it saves it to `/app/data/.secrets/first-admin-invite` (`0600`, `cloudron`).
- **A manifest `checklist` item** says where the link is, that it is single-use and must be treated as
  a password (whoever uses it becomes instance admin), and how to make a new one if it expires (72
  hours): `paperclipai auth bootstrap-ceo --force` in the app's Terminal.
- **Sign-up is decided at gate 1** by testing whether an invited **new** user can join with
  `PAPERCLIP_AUTH_DISABLE_SIGN_UP=true`:
  - **If yes:** default it to true, and the checklist says so.
  - **If no:** leave sign-up open, and the checklist says to turn it off whenever no one is waiting
    to join. Say plainly that inviting new people means turning it on briefly.
- **Telemetry and announcements off by default:** `PAPERCLIP_TELEMETRY_DISABLED=1`,
  `PAPERCLIP_ANNOUNCEMENTS_ENABLED=false`, and
  `PAPERCLIP_SETTING_DEFAULTS={"feedbackDataSharingPreference":"not_allowed"}`. All three are
  documented, and an operator can change them in `/app/data/env`.

## Consequences

- **No SSO.** The manifest does not claim it; the listing says so, and says there is no password
  reset. Recovery is by an admin; the procedure is written in POSTINSTALL at the build phase.
- **There is no default password to change.** The admin chooses their own. The warning that matters is
  the open sign-up, and the checklist carries it.

## History

**2026-09-24, P4 smoke: the monorepo-built CLI is missing dependencies; use the published package
instead.** ADR 0004's original wording assumed `start.sh` would run the workspace-built
`/app/code/cli/dist/index.js` directly, and P4's earlier check confirmed only that this file exists
and the package name matches (`paperclipai`, a `pnpm-workspace.yaml` member). It did not confirm the
file actually **runs**, which the first real smoke boot showed it does not:
`Cannot find package 'zod' imported from /app/code/cli/dist/index.js`.

Checked against the npm registry: the **published** `paperclipai@2026.916.1` package (the exact
version pinned for this build) declares `zod`, `ws`, `postgres`, `@anthropic-ai/sdk`,
`@agentclientprotocol/codex-acp` and `@agentclientprotocol/claude-agent-acp` as direct dependencies.
None of these are declared in the monorepo's own `cli/package.json`, so the raw workspace build
never vendors them; they are added at publish time. Upstream's own quickstart already runs the CLI
this way (`npx paperclipai onboard --yes`), not from an in-place monorepo checkout.

**Decision:** install the published `paperclipai` package globally, pinned to the same version as
the rest of the image, alongside the three agent CLIs (root-owned, at `/opt/paperclip-cli`, no
containment implication: it is an operational tool run by `cloudron`, never by an agent).
`start.sh` calls `/opt/paperclip-cli/bin/paperclipai auth bootstrap-ceo` instead of the workspace
build. The monorepo's own `cli/` is no longer built at all, since nothing else needs it.

**Lesson, logged for the field guide:** confirming a file exists and its package name matches is not
confirming it runs. The instrument has to be run, not just located.

**2026-09-24, P6 gate 1 on the Proving Ground (Cloudron 10.0.4): the sign-up question is settled,
"no" branch.**
- **The first-admin path works:** sign up, then `POST /api/invites/<bootstrap token>/accept`
  (`requestType: human`) returns 202, `bootstrapAccepted: true`, and `/api/health` moves from
  `bootstrap_pending` to `ready`.
- **With `PAPERCLIP_AUTH_DISABLE_SIGN_UP=true`, a new person cannot join:**
  `/api/auth/sign-up/email` returns `400 EMAIL_PASSWORD_SIGN_UP_DISABLED`, and invite acceptance
  needs a signed-in user, so an invite cannot bring in someone who has no account.
- **Existing users still sign in normally** with the flag on.

**Consequence, as ADR 0004 planned:**
- Sign-up **stays open by default**.
- The checklist says to turn it off (`PAPERCLIP_AUTH_DISABLE_SIGN_UP=true` in `/app/data/env`, then
  restart) once your team has joined, and to turn it on briefly whenever a new person needs to join.
