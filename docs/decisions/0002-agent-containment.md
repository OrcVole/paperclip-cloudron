# 0002: Local agents run as a separate, firewalled user

Status: accepted, 2026-09-24. The mechanism was proven on Cloudron 10.0.4 with a throwaway probe
app before this was written. The package implementation is still to be proven by `test/containment.sh`.

## Context

Paperclip's local adapters (`claude-local`, `codex-local`, `opencode-local` and others) start the
agent's command-line tool as a child of the Paperclip server, in the same container and as the same
Unix user. Upstream builds the child's environment as `{...sanitizeInheritedPaperclipEnv(process.env),
...opts.env}`, and the sanitiser removes only variables whose names start with `PAPERCLIP_`. An agent
is an LLM running shell commands, often on untrusted input (tickets, repositories, web pages). As the
server's user, with the server's environment, it could:

- read the database credentials and the secrets master key, and so take over the whole instance;
- read `/proc/<server>/environ` (same-UID processes can; measured);
- reach every other app on the same Cloudron directly, bypassing the reverse proxy and any
  `proxyAuth` wall (measured: other apps answer HTTP 200 on their internal addresses), plus the
  shared database servers;
- send mail from the server's IP address.

Upstream's own confinement (Bubblewrap, `filesystemScope` and `networkScope`) needs namespaces, and
`unshare` is refused in a Cloudron app container, so it cannot run here.

## Decision

1. **Two users.**
   - **The server runs as `cloudron`.**
   - **Agents run as `pcagent`**, with a fixed UID of **61001**: high, so no other container's
     processes share it, because `RLIMIT_NPROC` counts per real UID and Cloudron does not remap UIDs.
   - Both users belong to a group **`paperclip`** (GID 61000), which owns the trees both must write.
2. **One way in: `sudo` to a launcher.**
   - **The agent tools are installed under `/opt/agent-clis`**, owned by `pcagent`, mode `0700`. The
     `cloudron` user cannot run them directly, even through group membership.
   - **Wrappers named after each tool** (`claude`, `codex`, `opencode`) sit in `/usr/local/bin`,
     ahead of anything else on the server's `PATH`. Each runs `sudo -n -u pcagent
     /app/pkg/agent-launch.sh <tool> "$@"`.
   - **The `sudoers` file holds exactly one rule:** `cloudron ALL=(pcagent) NOPASSWD:SETENV:
     /app/pkg/agent-launch.sh *`.
   - **The launcher, running as `pcagent`,** deletes a denylist of variables (`CLOUDRON_*`,
     `DATABASE_*`, `BETTER_AUTH_*`, `PAPERCLIP_AGENT_JWT_SECRET`, `PAPERCLIP_SECRETS_*`,
     `PAPERCLIP_TOOL_ACTION_SIGNING_SECRET`, `LD_*`, `NODE_OPTIONS`). It then sets `HOME` to the
     agent home and the resource limits (`ulimit -u 256`, `-f` 2 GiB, `-c 0`), and `exec`s the real
     tool.
   - **Why an environment denylist and not an allowlist:** users give agents arbitrary environment
     variables through Paperclip's agent settings, and those names cannot be listed in advance. The
     denylist is backed by a server environment that is minimal by construction (point 4) and by a
     test that fails if any secret-shaped value reaches an agent (point 7).
3. **Firewall on the agent's UID, installed by the root entrypoint before privileges drop.** Requires
   `capabilities: ["net_admin"]`. Rules, in this order, for `--uid-owner 61001`:
   - IPv4:
     1. ACCEPT the container resolver (`127.0.0.11`, read from `/etc/resolv.conf`) on UDP and TCP 53.
     2. ACCEPT `127.0.0.1:3100` (Paperclip's own API, which agents call).
     3. ACCEPT `172.18.0.1:443`, **the reverse proxy only**. Agents may reach other apps through the
        front door, where each app's own authentication applies; this is how agents are wired to an
        LLM or a gateway on the same Cloudron.
     4. REJECT `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` and
        `100.64.0.0/10`.
     5. REJECT TCP 25, 465 and 587.
   - IPv6 (`ip6tables`): REJECT `fc00::/7` and `fe80::/10`, and TCP 25, 465 and 587. **The Cloudron
     network is dual-stack; IPv4-only rules were measured to leak.**
   - Everything else, meaning the public internet, is allowed. Agents need model APIs, git hosts and
     package registries.
   - **If the rules cannot be installed** (no `net_admin`, no `iptables`, no owner match), start.sh
     **refuses to start agents**. It does this by not installing the wrappers, so local adapters fail
     with "command not found", and it logs why. The UI and gateway adapters keep working. Local
     agents are never run unconfined.
4. **A minimal server environment.**
   - `start.sh` passes the database URL through `config.json`, never through the environment, and
     passes the auth secret as `PAPERCLIP_AGENT_JWT_SECRET`. Upstream's own sanitiser strips that
     name from child processes.
   - It `unset`s every `CLOUDRON_*` variable before it `exec`s the server.
5. **File ownership, reasserted on every boot** (a restore returns files owned by an unmapped UID;
   measured):
   - `cloudron:cloudron`, `0700`/`0600`: the secrets directory (master key, JWT secret, tool-signing
     secret, first-admin invite) and `config.json`.
   - `cloudron:paperclip`, setgid `2770`: the trees both users write, meaning the agent home, the
     server's home and the workspaces. Both processes run with `umask 0007`.
   - **Which exact paths the adapters write is established at P6** by running a real agent and
     reading every `EACCES`. The first real run fixes that list.
6. **The native runner is not shipped.** `paperclip-runnerd` is built by upstream's Rust stage and
   launched by the server itself. It is experimental and applies only to agents explicitly configured
   for it. Leaving it out removes an unwrapped launch path and the Rust toolchain from the build (ADR
   0001). The experimental toggle is hidden (`PAPERCLIP_HIDDEN_SETTINGS=instance.experimental.enableNativeRunner`),
   and the documentation says native-runner agents are unsupported.
7. **`test/containment.sh` is a permanent gate**, run on every build and every upstream bump. It runs a
   stand-in agent through the real wrapper and asserts every item below. Any item passing becomes a
   failure of the build:
   - It **cannot** read the master key, `config.json`, `/proc/<server>/environ` or `/proc/1/environ`.
   - It **cannot** see `CLOUDRON_*`, `DATABASE_*` or `BETTER_AUTH_*`, or any value equal to a
     generated secret.
   - It **cannot** reach the add-on databases by name or by any resolved IPv4 or IPv6 address, another
     app's container address, or outbound mail ports.
   - It **can** reach `127.0.0.1:3100`, `172.18.0.1:443`, DNS and the public internet.
   - The server user **cannot** execute a real tool directly, and `sudo` to root is refused.
   - `find / -xdev -perm -4000` lists `sudo` and nothing else. This is enforced at build time too.
   - On the box only, where `net_admin` exists: the firewall counters prove the rules fired.

## Consequences

- **Agents are cut down to three things:** their workspace, Paperclip's API with their own run token,
  and the internet (plus other apps through the front door, with those apps' own authentication).
- **What remains, stated in the listing:**
  - agents share one UID, so one agent can read another's workspace and saved logins;
  - anything an agent can read, it can send to the internet;
  - an agent can fill the disk; `RLIMIT_FSIZE` caps single files, not the total;
  - `sudo` is a setuid-root binary, and a flaw in it would give an agent root in the container;
  - board users can run any command through the `process` adapter, so treat them as administrators.
- **It depends on Cloudron granting `net_admin`.** Proven for an `--image` install; for a store install
  it is checked at gate 5.
- **The gateway adapters (OpenClaw, Hermes, HTTP) are unaffected**, and remain the recommendation for
  work on untrusted input, beside upstream's remote sandboxes.

## History

**2026-09-24, P4 build 4: the base image's setuid and setgid binaries are stripped.** The build-time
assertion "only `sudo` is setuid" failed, as designed. `cloudron/base:5.1.0` plus `sudo`, `iptables`
and `openssh-client` ship twelve setuid binaries (`su`, `passwd`, `chsh`, `chfn`, `gpasswd`,
`newgrp`, `mount`, `umount`, `ssh-keysign`, the dbus and polkit helpers, and `sudo`) and six setgid
ones (`chage`, `crontab`, `expiry`, `ssh-agent`, `unix_chkpwd`, `pam_extrausers_chkpwd`). App
containers run with `NoNewPrivs=0`, so every one is a possible escalation path from `pcagent`.

**Decision:** strip the setuid bit from everything except `sudo`, and the setgid bit from
everything. Nothing needs them:
- `su` is only ever run by root (the build checks and `test/containment.sh`);
- the `sudo` rule is `NOPASSWD`, so no password helper runs.

The assertion and the containment gate now also require **no setgid binaries**. The other checks in
the same step already held on the first real build:
- no `paperclip-runnerd`;
- all three tools run as `pcagent`;
- `cloudron` has no execute permission on them, and `pcagent` does.

**2026-09-24, P4 build 6: the published `paperclipai` package vendors its own runnerd too.** After
installing `paperclipai` globally (ADR 0004 History) to fix the missing CLI dependencies, the
build-time assertion caught a paperclip-runnerd binary again, this time at
`/opt/paperclip-cli/lib/node_modules/paperclipai/node_modules/@paperclipai/server/dist/vendor/paperclip-runner/bin/paperclip-runnerd`.
The published `@paperclipai/server` npm package that `paperclipai` depends on ships a pre-built
runnerd for the resolved platform; the builder stage's cleanup runs before this second install
exists, so it never saw this copy. The rule (no native runner, from any source) is unchanged; the
cleanup now also runs under `/opt/paperclip-cli` after that install.

**2026-09-24 — per-run temp directories (P6, first real agent run).** The first real OpenCode run
(test-environment probe on the Proving Ground) failed with `EACCES: mkdir
'/tmp/paperclip-opencode-config-…/opencode'`. Paperclip's adapters create private per-run directories
with `mkdtemp` under the temp dir (mode 0700, owned by the server user, all prefixed `paperclip-`) and
hand them to the agent through environment variables (`XDG_CONFIG_HOME`, `CODEX_HOME`,
`CLAUDE_CONFIG_DIR` and others). The agent user could not enter them. The wrappers now call
`/app/pkg/agent-wrapper.sh`, which runs as the server user before the sudo crossing and grants the
`paperclip` group read/write (and setgid on directories) to exactly the directories this run was
handed: named in this run's environment, directly under the temp dir, prefixed `paperclip-`, owned by
the server user. Nothing else in the temp dir changes. Symlinks are not followed. This widens nothing
beyond the residual already accepted under Consequences (agents share one UID and can read each other's workspaces).

**2026-09-25: the ACP engine bypassed the door; closed, and the instance root opened just enough.**

*The bypass.* claude_local and codex_local default to `engine: "acp"`. The server starts an ACP
bridge (`claude-agent-acp`, `codex-acp`) as the server user, and the bridge runs its **own bundled
copy** of the agent (the Claude Agent SDK's platform package, the codex npm vendor binary) unless
`CLAUDE_CODE_EXECUTABLE` / `CODEX_PATH` say otherwise. So an ACP agent ran as `cloudron`, outside the
firewall and able to read the master key and the database settings. The gate missed it because it
exercised only the door we built. It surfaced on the first real task, which failed on sign-in before
any tool ran (0 tool calls, no model call).

*Closed by three layers:*
1. `start.sh` exports `CLAUDE_CODE_EXECUTABLE` and `CODEX_PATH` pointing at the wrappers.
   `agent-launch.sh` re-points them at `/opt/agent-clis` inside the agent, which has no sudo rule.
2. `shim-bundled-agents.sh` replaces **every** bundled claude, codex and opencode (18 of them: SDK
   binaries, vendor binaries, pnpm launchers) with a shim that execs the wrapper. It runs in the build
   step that creates them, so the originals never reach a layer (the image went from 9.48 to 7.44 GB).
   A final catch-all and a build assertion fail the build if any copy above 4 KB remains.
3. /opt/agent-clis is pinned to exactly upstream's bundled versions (Claude Code 2.1.263, codex
   0.153.4, opencode 1.18.29), because the SDK and the CLI speak one control protocol.

The bridges stay under the server user, as relays. Their shell and file tools run inside the agent
binary. acpx offers ACP clients fs and terminal capabilities that it serves **in the server
process**, but claude-agent-acp 0.73 and codex-acp 1.6.2 never call them. **Residual, checked on
every bump:** a bridge version that routes tools through the client would reopen the bypass; grep the
bridges for `readTextFile` / `createTerminal` calls.

*The instance root.* The server hands agents paths through
`/app/data/paperclip/instances/default`: the workspace and project links, and the Claude settings that
widen Claude's read roots to the run's company directory (`writePaperclipClaudeSettings`). Upstream
has no setting to move them. So:
- the three ancestors are `0710 cloudron:paperclip`: traverse, no listing;
- everything below stays private: the server's umask is 0007, pcagent is not in the cloudron group,
  and a boot sweep removes "other" bits, because copies out of the image keep 0644;
- `agent-wrapper.sh` grants just in time, for paths this run was handed, inside an allowlist: the
  run's **own** company directory read-only (`PAPERCLIP_COMPANY_ID`, validated as a UUID), its
  `codex-home` read-write, and skills and runtime-context bundles read-only. Paths with `.` or `..`
  components, and symlinks, are never granted. Other companies and `data/` (run logs, traces,
  storage) stay private.
- `INST/projects` links to `/app/workspaces/projects`, so project checkouts are out of the backup,
  as the manifest checklist says.

*Two traps found on the way.* (1) sudo is setuid, and the C library strips `TMPDIR` from setuid
programs, so the run's scratch directory never reached the agent. The wrapper carries it as
`PAPERCLIP_AGENT_TMPDIR`, and the launcher restores it only if it is `/tmp/paperclip-*` without `..`.
(2) The temp root must be fixed at `/tmp`: Paperclip points `TMPDIR` at the scratch directory itself.

*New gate checks (test/containment.sh 1b and 4):*
- no bundled copy remains;
- the server's bridge variables point at the wrappers;
- a **witness**: in test mode, the launcher prints `LAUNCHED <tool> AS <uid>`. A version-string check
  passed on the broken build, because the versions matched;
- the agent cannot list the instance root, its data or the companies, and cannot write its company
  directory;
- nothing under the Paperclip home is open to other users.

Proven on the Proving Ground: in a real ACP run, the bridge runs as cloudron and
`/opt/agent-clis/bin/claude` runs as pcagent, under `sudo … agent-launch.sh`. The run reaches the
model sign-in, and the gate reports 0 failures (36 checks).
A debugging aid ships with it: `touch /run/paperclip/debug-agent` (root only) logs each agent run's
arguments (tokens masked), environment names and stderr to `/tmp/paperclip-agent-debug-*.log`.

**2026-09-25: hardening of adapter launch settings.** `patches/agent-adapter-launch-guard.py` extends upstream's own guard to more of an
adapter's launch settings; it is applied in the builder before the server compiles and fails the build if an anchor moved. Proven on the
Proving Ground each round, and the gate greps the compiled string (test/containment.sh 1c). Drop the patch when a released version
covers them. Defence-in-depth also shipped: agent-wrapper.sh as `bash -p`, an explicit PATH, absolute tool paths.
