#!/usr/bin/env python3
"""Build-time patch (ADR 0002 History, 2026-09-25): hardening of adapter launch settings. Extends upstream's own guard
to cover more of them, on every route that calls it. Fails the build if an anchor has moved, rather than shipping an
unpatched image. Remove when a released version covers them.
"""
import sys, pathlib

root = pathlib.Path(sys.argv[1])
authz = root / "server/src/routes/workspace-command-authz.ts"
agents = root / "server/src/routes/agents.ts"

MARK = "collectAgentAdapterLaunchPaths"

def die(msg): raise SystemExit(f"agent-adapter-launch-guard: FAILED: {msg}")

a = authz.read_text()
if MARK in a:
    die("already patched (workspace-command-authz.ts) — unexpected on a clean clone")
if "export function assertNoAgentHostWorkspaceCommandMutation" not in a:
    die("anchor gone in workspace-command-authz.ts; upstream changed, re-verify the guard")
a += '''
// --- Cloudron package hardening (ADR 0002): adapter launch settings ---
// See docs/decisions/0002-agent-containment.md.
const AGENT_FORBIDDEN_ADAPTER_LAUNCH_KEYS = [
  "command",
  "agentCommand",
  "acpAgentCommand",
  "env",
] as const;

export function collectAgentAdapterLaunchPaths(
  adapterConfig: unknown,
  prefix = "adapterConfig",
): string[] {
  if (!isRecord(adapterConfig)) return [];
  return AGENT_FORBIDDEN_ADAPTER_LAUNCH_KEYS.filter((key) => hasOwn(adapterConfig, key)).map((key) =>
    prefixPath(prefix, key),
  );
}

export function assertNoAgentAdapterLaunchMutation(req: Request, paths: string[]) {
  if (req.actor.type !== "agent" || paths.length === 0) return;
  throw forbidden(
    `Agent keys cannot modify the adapter launch command or environment (${paths.join(", ")}).`,
  );
}
'''
authz.write_text(a)

g = agents.read_text()
if MARK in g:
    die("already patched (agents.ts)")
imp_old = '''import {
  assertNoAgentHostWorkspaceCommandMutation,
  collectAgentAdapterWorkspaceCommandPaths,
} from "./workspace-command-authz.js";'''
imp_new = '''import {
  assertNoAgentAdapterLaunchMutation,
  assertNoAgentHostWorkspaceCommandMutation,
  collectAgentAdapterLaunchPaths,
  collectAgentAdapterWorkspaceCommandPaths,
} from "./workspace-command-authz.js";'''
if imp_old not in g:
    die("import anchor gone in agents.ts")
g = g.replace(imp_old, imp_new, 1)

call_old = '''    assertNoAgentHostWorkspaceCommandMutation(
      req,
      collectAgentAdapterWorkspaceCommandPaths(adapterConfig, path),
    );
  }'''
call_new = '''    assertNoAgentHostWorkspaceCommandMutation(
      req,
      collectAgentAdapterWorkspaceCommandPaths(adapterConfig, path),
    );
    assertNoAgentAdapterLaunchMutation(
      req,
      collectAgentAdapterLaunchPaths(adapterConfig, path),
    );
  }'''
if call_old not in g:
    die("guard-body anchor gone in agents.ts")
g = g.replace(call_old, call_new, 1)
agents.write_text(g)
print("agent-adapter-launch-guard: applied")
