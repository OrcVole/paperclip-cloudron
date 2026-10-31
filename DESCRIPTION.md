<upstream>2026.1023.0</upstream>

# Paperclip

Paperclip is an open-source control plane for teams of AI agents. Define a company with a goal,
hire agents into an org chart (Claude Code, Codex, OpenCode, or an HTTP or gateway agent), give
them budgets and approval gates, and they wake on a schedule to check out tickets, do the work,
and report back. Tickets, routines, cost tracking and an audit log are built in.

**How coding agents are contained.** Agents that run inside this app (Claude Code, Codex, OpenCode)
run as a separate, unprivileged user, never as the app's own server user. They cannot read Paperclip's
database credentials or its encryption key, they cannot reach other apps or databases on your server's
internal network, and they cannot send mail. They can reach the internet, their own workspace, and
Paperclip's own API with their own permissions. This holds however Paperclip runs an agent, including
its ACP engine, which bundles its own copy of each agent binary: every one is routed back through the
contained path.

**What it does not protect against.** Agents of one company share a single user, so one can read
another's workspace and saved logins. An agent can fill the server's disk. Anyone you give board
access can run any command inside the app, so grant it only to people you trust. **For work on
untrusted input** — pull requests from strangers, public tickets — run agents in a remote sandbox or a
separate app rather than inside this one. The design and its limits are in the package's
`docs/decisions/0002-agent-containment.md`.

This package only supports email and password sign-in. There is no single sign-on, and there is no
password reset by email; account recovery needs an administrator with access to the app's
database.

Agent workspaces (checkouts of your project repositories) are excluded from Cloudron's backup,
because they are large, change continuously, and are rebuilt from your repositories on demand.
Anything an agent has not committed and pushed is not backed up. See POSTINSTALL for what this
means in practice.

This package includes software developed by the Paperclip AI project, licensed MIT. It is a
community package, not affiliated with or officially supported by the Paperclip project.
