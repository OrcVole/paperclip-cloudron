## First deployment takes a while

This is a large image (several gigabytes: it bundles the coding-agent CLIs). The **first** install or
update spends several minutes downloading and unpacking before the app starts; this is normal, and it
is only slow the first time. Later restarts are quick.

## First admin

Read the app's Logs tab for a one-time invite link, printed at first start. It is also saved at
`/app/data/.secrets/first-admin-invite` (Web Terminal: `cat /app/data/.secrets/first-admin-invite`).

Treat this link as a password: whoever opens it first becomes the instance administrator. It
expires after 72 hours. If it expires before anyone claims it, open a Web Terminal and run:

```bash
paperclipai auth bootstrap-ceo --force
```

## Sign-up

Sign-up is **open until the first admin has claimed the instance**, because claiming it needs an account. From the next start
after that, sign-up is **closed automatically**, so a stranger who reaches this app's URL cannot create an account.

**After you have claimed the instance, restart the app once** (Cloudron dashboard, Restart). Until that restart sign-up is still
open. Existing users keep signing in either way.

To add more people: open a Web Terminal, run `umask 077`, set `PAPERCLIP_AUTH_DISABLE_SIGN_UP=false` in `/app/data/env`, restart the app, have them
sign up, then set it back to `true` (or remove the line) and restart. An explicit value in that file always wins over the automatic
setting. The file is read line by line (`NAME=value`, only `PAPERCLIP_*` names, plain values); it is never executed.

## Agent workspaces are not backed up

Agents work in checkouts of your project repositories, kept outside Cloudron's backup because they
are large and change constantly. The durable copy of an agent's work is its git repository:
anything committed and pushed survives a restore or a clone; anything left uncommitted does not.
Have agents push their work as they go, particularly before a planned update or restore.

## What an agent running inside this app can reach

See the app's description for the summary. In short: agents run as a separate, unprivileged user;
they cannot read Paperclip's secrets or reach your other apps and databases; they can reach the
internet, their own workspace and Paperclip's API. Agents of one company share a user, so keep
untrusted-input work (public tickets, strangers' pull requests) in a remote sandbox or a separate
app. Full detail: `docs/decisions/0002-agent-containment.md` in the package repository.

## Connecting an agent to a model

**API key (Claude, OpenAI, or any OpenAI-compatible endpoint):** add it when you configure the agent
in the Paperclip UI. Keys you set there are stored by Paperclip, encrypted, and handed only to that
agent's run.

**Claude or ChatGPT subscription:** the onboarding wizard's "use subscription" button does **not**
sign you in by itself. Do it from a Web Terminal: run `claude` (or `codex`), then `/login`, follow
the prompt, and `/exit`. The login is saved under `/app/data/agent-home`, readable only by the agent
user, and it is included in this app's backups, so it survives an update, a restore and a clone.

**Agents hiring agents.** An agent can build its own team: it can hire other agents (name, role,
adapter, model), which is a supported flow. **By default a new agent needs no board sign-off**, so an agent team can
grow itself unattended; if you want a human to approve each new hire, turn on "require board approval
for new agents" for the company. See the trust notes in the app description.

**Local or self-hosted models** (for example a vLLM or Ollama endpoint on your network, or a gateway):
give the agent an OpenAI-compatible base URL and key in its configuration. Because agents are
firewalled off your server's internal network, an endpoint on another Cloudron app is reached through
its public URL, not its internal address.

## How much memory to give it

The app idles at about 1.3 GiB. Each agent running at the same time adds roughly 0.5 GiB. The default
4 GiB limit comfortably holds the app plus about four concurrent agents; raise the memory limit in the
app's settings if you expect more agents working at once.

## Backups and restores

Restoring a backup rolls the whole app back to that point: your agents, tickets, settings and saved
logins return to how they were, and anything created since is gone. **Agent workspaces are the
exception** — they live outside the backup (see "Agent workspaces are not backed up" above), so a restore does not touch them. Have agents
commit and push their work before a planned restore.
