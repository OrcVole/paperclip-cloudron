# 0001: Build from source on cloudron/base; pin every agent CLI; no native runner

Status: accepted, 2026-09-24. Resolved values are re-checked at the start of the build phase.

## Context

Upstream publishes `ghcr.io/paperclipai/paperclip` (the tag has **no** `v`: `:2026.916.1` exists,
`:v2026.916.1` does not). It is 1.83 GB compressed, built on `node:24-trixie-slim`.
- **Its agent CLIs are unpinned.** It installs five of them with `npm install --global ...@latest`,
  refreshed weekly by a cache-busting build argument, so one upstream tag can ship different agent
  CLIs depending on the week it was built.
- **Its runtime libraries target the wrong OS.** Its `node_modules` hold native modules compiled
  against Debian trixie's glibc 2.41. The Cloudron base (`cloudron/base:5.1.0`, Ubuntu 24.04) has
  glibc 2.39, so copying the built tree across risks `GLIBC_2.4x not found` at runtime.
- **The upstream server build is a pnpm monorepo** (pnpm 9.15.4, Node 24.11 or later). The server's
  own `build` script first builds the runner package's TypeScript (`prepare:runner-vendor`). The
  Rust `paperclip-runnerd` binary is a separate `build:binary` step.

## Decision

1. **Build from the upstream source tag, in a builder stage FROM the same `cloudron/base:5.1.0`**
   (pinned by digest; at the time of writing
   `sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e`). Native modules then
   compile against the glibc they run on. The base ships Node 24.13.1. pnpm comes from `corepack`,
   pinned to the `packageManager` field.
2. **Mirror upstream's build order:** `pnpm install --frozen-lockfile`, then the UI, the plugin SDK and
   the server. **No Rust stage.** If the TypeScript build proves to need Rust output, add upstream's
   pinned-rustup stage **for the build only**. Either way the final image must contain no
   `paperclip-runnerd` (a build check fails otherwise; see ADR 0002 on the native runner).
3. **The final stage is `cloudron/base:5.1.0`** with the built `/app/code` tree, `tini`, `sudo`,
   `iptables` (base ships neither `sudo` nor `iptables`), `git`, `openssh-client`, `ripgrep` and
   `jq`. `6.0.0` (Ubuntu 26.04) exists, but a new OS is an operator decision, not an update.
4. **Three agent CLIs, each pinned to an exact version, installed into `/opt/agent-clis`** (npm
   `--prefix`), never globally:
   - `@anthropic-ai/claude-code` (2.1.282 at the time of writing);
   - `@openai/codex` (0.156.1);
   - `opencode-ai` (1.18.32), which takes an OpenAI-compatible base URL, so it is the one that talks
     to a local model or gateway.

   Gemini CLI and Kimi Code are left out to keep the image and the containment surface smaller; they
   can be added the same way on request. The pins move deliberately, with the changelog, like any
   other dependency.
5. **Minimum Cloudron version 10.0.0.** The package is only ever tested on 10.x. It relies on
   `persistentDirs` and the `net_admin` capability.
6. **The server starts as upstream does:**
   `node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js`, under `tini` (agent
   runs leave orphans; upstream measured about 79 zombie processes an hour without a reaper).

## Consequences

- **Reproducible:** the same upstream tag gives the same image, including the agent CLIs.
- **The build is heavy:** a full pnpm monorepo, and upstream gives its server build a 4 GB heap
  (`NODE_OPTIONS=--max-old-space-size=4096`). Budget the build time.
- **Native-runner agents are unsupported**, and the documentation says so.
- **Every weekly upstream release is a rebuild:** re-resolve the tag, re-run `pnpm install
  --frozen-lockfile`, and re-run the containment and smoke suites. This is update-ladder work the
  local runner can execute.

## History

**2026-09-24, P4: the build needs Rust after all; section 2's fallback is taken.** The executor found,
from source at v2026.916.1, that `server`'s `build` runs `prepare:runner-vendor`, which is the runner
package's full `build`. That script's `&&` chain includes `build:binary` (`cargo build --release ...
--bin paperclip-runnerd`), and `stage-runner-binary.mjs` copies the result into the runner's
`dist/bin`, which the server then vendors. There is no skip flag.

Decided, at the reasoning tier:
- **A Rust toolchain in the builder stage only.** It uses upstream's rustup pin exactly
  (1.29.0, amd64 checksum `4acc9acc…`) and the runner's own `rust-toolchain.toml` (1.97.1,
  minimal).
- **No `cargo-chef`.** Upstream uses it so CI rebuilds on every commit stay cheap; this package
  rebuilds once per upstream bump, so its three extra stages are complexity without benefit.
- **amd64 only,** like every other package in this fleet.
- **The compiled `paperclip-runnerd` is deleted in the builder,** and its absence is asserted in the
  final image (ADR 0002 §6 and §7 are unchanged).
- **Rejected: patching `server/package.json`** to call the runner's `build:typescript` instead. That
  would skip upstream's protocol and contract checks, which also run in that chain, and silently
  fork the build.

**2026-09-24, P4 secret scan: the final image ships no test suite.** With its image half genuinely
running, `test/secret-scan.sh` failed on 99 credential-shaped strings. Every one was one of
upstream's own test fixtures (`SYNTHETIC...`, `...never-persist`, `documentationfixture`, labelled
fake PEM blocks), present because the final stage copies the whole builder checkout, and `tsc`
compiles `*.test.ts` into `dist/` as well.

**Decided, at the reasoning tier:**
- **Delete test artefacts in the builder, before the copy:** `*.test.*` and `*.spec.*` files outside
  `node_modules` (source, compiled `.js`, `.d.ts` and `.map`), `__tests__/` directories, and the
  `tests/` and `evals/` trees.
- **The regex was checked on sample names first.** It spares `testing.js` (the runner's real entry
  point) and names such as `latest.ts` and `contest.ts`.
- **Rejected for now: `pnpm deploy --prod`.** It would shrink the image further, but it restructures
  the tree, and upstream's own comment in `verify-runner-vendor-dependencies.mjs` warns that
  restructuring breaks the runner's `import.meta.url`-relative lookups; adapters also find skills by
  relative path. It is logged as a later size round with a full re-gate.
- **Rejected: bulk allowlisting.** The allowlist is for our own deliberately public strings, each
  entry reviewed individually.
- **The scanner is the arbiter.** Any hit that remains in a non-test file after this is reviewed on
  its own, never waved through.

**2026-09-24, same evening: the 17 hits left after pruning, each reviewed.** Pruning the test suite
took the scan from 99 hits to 17.
- **10 were inline Rust `#[cfg(test)]` fixtures** in `packages/paperclip-runner/runner/.../state.rs`.
  That crate's source exists only to build `paperclip-runnerd`, which is never shipped, so the whole
  `runner/` crate source is now deleted in the builder. The runner's `protocol/` directory stays,
  because it is loaded at runtime.
- **6 were legitimate upstream code that mentions a PEM header without holding a key**: the GitHub
  app's form placeholder (JSON source, JSON dist, and the minified UI bundle), a redaction regex, a
  validation message, and the same placeholder in an ingest script.
- **All six are allowlisted individually,** anchored on content that cannot hold a real key (a
  `"placeholder": "…"`, a `.replace(…, "[REDACTED_PRIVATE_KEY]")`, a sentence of prose). The ingest
  script's bare-header line is anchored on its **path and line number** instead. That entry fails
  closed and forces a re-review whenever upstream edits the file.
- **Never allowlisted: the bare PEM header**, because that would hide a real leaked key.
