# Paperclip for Cloudron. Design: docs/decisions/0001 (build route) and 0002 (containment).
# DRAFT from the design phase; the build phase proves it. Every RUN that asserts something fails the build.

# Official Node.js 24.22.1 (security release 2026-10-20), glibc build. cloudron/base 6.0.1 (Ubuntu 26.04,
# glibc 2.43) ships NO Node, so both stages copy it from here, as langfuse does. Placed at
# /usr/local/node-24.22.1 (the layout the 5.1.0 base had for 24.19.0), NOT on the image PATH.
FROM docker.io/library/node:24.22.1-bookworm-slim@sha256:2dd9a4f758e173b65fee15388f7706af6fb01ef50cf7a2c0538711d67a6981ae AS officialnode

# ---- builder: the upstream source tag, built against the same glibc it will run on ----------------
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee AS builder
# The git tag carries a `v`; upstream's own image tag does not (ADR 0001).
ARG PAPERCLIP_VERSION=2026.1023.0
ARG PNPM_VERSION=9.15.4
# cloudron/base:6.0.1 ships no Node; the official 24.22.1 is copied in (stage officialnode above).
COPY --from=officialnode /usr/local/bin/node /usr/local/node-24.22.1/bin/node
COPY --from=officialnode /usr/local/lib/node_modules /usr/local/node-24.22.1/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/node-24.22.1/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/node-24.22.1/bin/npx \
 && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/node-24.22.1/bin/corepack \
 && test "$(/usr/local/node-24.22.1/bin/node --version)" = "v24.22.1" \
 && test -x /usr/local/node-24.22.1/bin/npm && test -x /usr/local/node-24.22.1/bin/corepack
ENV PATH=/usr/local/node-24.22.1/bin:$PATH
RUN git clone --depth 1 --branch "v${PAPERCLIP_VERSION}" https://github.com/paperclipai/paperclip.git /src
WORKDIR /src
# Rust, for the BUILD ONLY (ADR 0001 section 2, decided 2026-09-24): the server's own build script
# runs the runner package's full build, which compiles paperclip-runnerd with cargo and has no skip
# flag. rustup is upstream's exact pin and checksum; the compiler is chosen by the runner's own
# rust-toolchain.toml. No cargo-chef: we rebuild once per upstream bump, not per commit. The binary
# is deleted below and asserted absent from the final image.
ARG RUSTUP_VERSION=1.29.0
ARG RUSTUP_SHA256=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc libc6-dev pkg-config \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSLo /tmp/rustup-init "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/x86_64-unknown-linux-gnu/rustup-init" \
 && echo "${RUSTUP_SHA256}  /tmp/rustup-init" | sha256sum -c - \
 && chmod +x /tmp/rustup-init && /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain none \
 && rm /tmp/rustup-init \
 && cd packages/paperclip-runner && rustup show && cargo --version
RUN corepack enable && corepack prepare "pnpm@${PNPM_VERSION}" --activate
RUN pnpm install --frozen-lockfile
RUN pnpm --filter @paperclipai/ui build && pnpm --filter @paperclipai/plugin-sdk build
# Cloudron package hardening patch (ADR 0002 History, 2026-09-25), applied before the server is compiled.
# Fails the build if an anchor moved.
COPY patches/agent-adapter-launch-guard.py /tmp/agent-adapter-launch-guard.py
RUN python3 /tmp/agent-adapter-launch-guard.py /src \
 && grep -q assertNoAgentAdapterLaunchMutation /src/server/src/routes/agents.ts
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN PAPERCLIP_BUILD_COMMIT="$(git rev-parse HEAD)" pnpm --filter @paperclipai/server build \
 && test -f server/dist/index.js \
 && grep -rq "Agent keys cannot modify the adapter launch command" server/dist
# The monorepo's own cli/ build is NOT used (ADR 0004 History, 2026-09-24): its dist/index.js is
# missing several dependencies (zod and others) that the raw workspace build does not vendor. The
# published `paperclipai` package, installed globally below, provides `auth bootstrap-ceo` instead.
# No native runner (ADR 0001 §2, ADR 0002 §6): remove the runnerd the build just compiled, wherever it
# was staged (runner dist/bin, and server/dist/vendor via the server's cp -R), and the Rust target tree.
RUN rm -rf packages/paperclip-runner/runner/target \
 && find / -xdev -name paperclip-runnerd -type f -delete 2>/dev/null; \
    test -z "$(find /src -name paperclip-runnerd -type f)"
# Ship no test suite (ADR 0001 History, 2026-09-24): upstream's tests are full of credential-SHAPED
# fixtures by design, and tsc compiles *.test.ts into dist/ too, so the secret scan failed on 99 of
# them. Delete test and spec files (source and compiled, maps and .d.ts included) and the tests/ and
# evals/ trees, outside node_modules. Nothing at runtime loads them; the layout the app was proven on
# is otherwise unchanged. The runner's testing.js entry point is not a *.test.* file and stays.
RUN find /src -path '*/node_modules' -prune -o -type f \
      -regex '.*\.\(test\|spec\)\(\.d\)?\.[cm]?[jt]sx?\(\.map\)?$' -print0 | xargs -0 -r rm -f \
 && find /src -path '*/node_modules' -prune -o -type d -name __tests__ -print0 | xargs -0 -r rm -rf \
 && rm -rf /src/tests /src/evals \
# The runner's Rust crate SOURCE is only for building paperclip-runnerd, which is never shipped (ADR 0002
# section 6); its inline #[cfg(test)] fixtures tripped the scan. The runner's protocol/ fixtures are loaded at
# runtime by import.meta.url and stay.
 && rm -rf /src/packages/paperclip-runner/runner \
 && test -z "$(find /src -path '*/node_modules' -prune -o -type f -regex '.*\.\(test\|spec\)\.[cm]?[jt]sx?$' -print | head -1)" \
 && test -f /src/server/dist/index.js
# Bundled agent copies (ADR 0002 History, 2026-09-25): replaced here, in the builder, so the ~1.5 GB of
# originals never reach the shipped image. The final stage re-checks and fails closed.
COPY shim-bundled-agents.sh /tmp/shim-bundled-agents.sh
RUN n="$(/tmp/shim-bundled-agents.sh /src)" && echo "builder: replaced ${n} bundled agent copies" && test "${n}" -ge 10

# ---- final ------------------------------------------------------------------------------------------
FROM docker.io/cloudron/base:6.0.1@sha256:7b1e729960c3ca312d26e886917ba89483241bba0219ff292858e10d9d5768ee
# /opt/paperclip-cli/bin so `paperclipai` runs bare in a Web Terminal (POSTINSTALL.md refers to it
# that way); the directory is created by the npm install further down, ENV just declares the PATH.
COPY --from=officialnode /usr/local/bin/node /usr/local/node-24.22.1/bin/node
COPY --from=officialnode /usr/local/lib/node_modules /usr/local/node-24.22.1/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/node-24.22.1/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/node-24.22.1/bin/npx \
 && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/node-24.22.1/bin/corepack \
 && test "$(/usr/local/node-24.22.1/bin/node --version)" = "v24.22.1" \
 && test -x /usr/local/node-24.22.1/bin/npm && test -x /usr/local/node-24.22.1/bin/corepack
ENV PATH=/usr/local/node-24.22.1/bin:/opt/paperclip-cli/bin:$PATH

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      sudo iptables tini ripgrep jq openssh-client \
 && rm -rf /var/lib/apt/lists/*

# Users (ADR 0002 §1): agents get their own high, fixed UID; server and agents share a group.
RUN groupadd -g 61000 paperclip \
 && useradd -u 61001 -g 61000 -M -d /app/data/agent-home -s /usr/sbin/nologin pcagent \
 && usermod -aG paperclip cloudron

# The agent CLIs, pinned, owned by pcagent, unreadable to anyone else (ADR 0001 §4, ADR 0002 §2).
# Pinned to EXACTLY the versions upstream bundles and tests with its ACP bridges (ADR 0002 History,
# 2026-09-25): the Claude Agent SDK 0.3.286 ships Claude Code 2.1.286, and the lockfile resolves codex
# 0.160.0 and opencode-ai 1.18.34. The bridges now run these through the wrappers, so the SDK and
# the CLI must speak the same control protocol. Bump them together with PAPERCLIP_VERSION.
ARG CLAUDE_CODE_VERSION=2.1.286
ARG CODEX_VERSION=0.160.0
ARG OPENCODE_VERSION=1.18.34
# npm 11.17+ (bundled with Node 24.22.1, npm 11.19.1) skips install scripts unless allowed. Claude Code and OpenCode
# need theirs (each fetches its platform binary), so allow exactly those two pinned packages, nothing else.
RUN npm install -g --prefix /opt/agent-clis --omit=dev --allow-scripts=@anthropic-ai/claude-code,opencode-ai \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" "opencode-ai@${OPENCODE_VERSION}" \
 && chown -R pcagent:paperclip /opt/agent-clis && chmod 0700 /opt/agent-clis \
 && for t in claude codex opencode; do test -x "/opt/agent-clis/bin/$t"; done

# The published `paperclipai` CLI, pinned to the same version as the rest of the image (ADR 0004
# History, 2026-09-24): the monorepo's own `cli/package.json` does not declare several packages its
# built dist/index.js actually imports (zod, ws, postgres, @anthropic-ai/sdk, the ACP packages),
# confirmed against the published npm package's dependency list, which does. Upstream's own
# quickstart runs the CLI this way (`npx paperclipai ...`), not the in-place monorepo build. This is
# root-owned, not agent-writable, and unrelated to ADR 0002's containment surface.
ARG PAPERCLIP_CLI_VERSION=2026.1023.0
COPY shim-bundled-agents.sh /tmp/shim-bundled-agents.sh
RUN npm install -g --prefix /opt/paperclip-cli --omit=dev "paperclipai@${PAPERCLIP_CLI_VERSION}" \
 && test -x /opt/paperclip-cli/bin/paperclipai \
 && find /opt/paperclip-cli -xdev -name paperclip-runnerd -type f -delete \
 && n="$(/tmp/shim-bundled-agents.sh /opt/paperclip-cli)" && echo "paperclip-cli: replaced ${n} bundled agent copies"
# The published paperclipai package's own @paperclipai/server dependency vendors ITS OWN pre-built
# paperclip-runnerd (ADR 0002 §6 still applies: no native runner, from any source), found here
# because the builder stage's cleanup only ever saw our own monorepo build, not this later install.

COPY --from=builder /src /app/code
COPY start.sh agent-launch.sh agent-wrapper.sh /app/pkg/
COPY test/ /app/pkg/test/
COPY wrappers/ /usr/local/bin/
COPY sudoers.paperclip /etc/sudoers.d/paperclip
RUN chmod 0755 /app/pkg/*.sh /app/pkg/test/*.sh /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/opencode \
 && chmod 0440 /etc/sudoers.d/paperclip && visudo -cf /etc/sudoers.d/paperclip

# Bundled agent binaries (ADR 0002 History, 2026-09-25). Paperclip's default engine for Claude and
# Codex is ACP: the server starts a bridge (claude-agent-acp, codex-acp) that runs its OWN bundled
# copy of the agent, from the SDK's platform packages, as the SERVER user. That bypasses the wrappers,
# the firewall and the agent UID entirely. Replace every bundled claude, codex and opencode, native
# binary or launcher script, anywhere outside /opt/agent-clis, with a shim that execs the matching
# wrapper, so every engine and every lookup path ends in containment. codex-code-mode-host has no
# wrapper and is only ever started by codex itself (the contained copy has its own), so its bundled
# copies are disabled outright. start.sh also points the bridges at the wrappers explicitly
# (CLAUDE_CODE_EXECUTABLE, CODEX_PATH); the shims are what makes a missed variable fail closed.
RUN n="$(/tmp/shim-bundled-agents.sh / 2>/dev/null)" && echo "final catch-all: replaced ${n} more" \
 && rm -f /tmp/shim-bundled-agents.sh

# Privilege surface (ADR 0002 §2, and the History note of 2026-09-24): cloudron/base plus our packages
# ship twelve setuid and six setgid binaries (su, passwd, mount, ssh-keysign, unix_chkpwd, ...). Cloudron
# containers run with NoNewPrivs=0, so each is a possible path from the agent user to root. Strip them
# all except sudo. su still works for root, which is the only caller left (build checks, the containment
# gate); the sudo rule is NOPASSWD, so no password helper is needed.
RUN find / -xdev -perm -4000 -type f ! -path /usr/bin/sudo.ws -exec chmod u-s {} + \
 && find / -xdev -perm -2000 -type f -exec chmod g-s {} +

# Build-time assertions (ADR 0002 §7).
RUN test "$(readlink -f /usr/bin/sudo)" = /usr/bin/sudo.ws \
 && test "$(find / -xdev -perm -4000 -type f 2>/dev/null | sort | tr '\n' ' ')" = "/usr/bin/sudo.ws " \
 && test -z "$(find / -xdev -type f \( -name claude -o -name claude.exe -o -name codex -o -name codex.exe \
      -o -name opencode -o -name opencode.exe -o -name codex-code-mode-host \) -size +4k \
      ! -path '/opt/agent-clis/*' ! -path '/proc/*' 2>/dev/null)" \
 && test -z "$(find / -xdev -perm -2000 -type f 2>/dev/null)" \
 && test -z "$(find / -xdev -name paperclip-runnerd -type f 2>/dev/null)" \
 && for t in claude codex opencode; do su pcagent -s /bin/bash -c "HOME=/tmp PATH=/usr/local/node-24.22.1/bin:\$PATH /opt/agent-clis/bin/$t --version" >/dev/null; done \
 && ! su cloudron -s /bin/bash -c 'test -x /opt/agent-clis/bin/claude' \
 && su pcagent -s /bin/bash -c 'test -x /opt/agent-clis/bin/claude'

WORKDIR /app/code
CMD ["/app/pkg/start.sh"]
