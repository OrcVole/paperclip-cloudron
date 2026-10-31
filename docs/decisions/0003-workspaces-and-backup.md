# 0003: Agent workspaces live outside the backup

Status: accepted, 2026-09-24 (operator decision).

## Context

Agents work in git checkouts and worktrees under `$PAPERCLIP_HOME/instances/default/workspaces`
(`server/src/home-paths.ts`). They are large and change constantly while agents run. Under
`/app/data` they would make every Cloudron backup large and slow, and the backup would copy trees
that git is rewriting.

**The durable copy of the work is the project's git repository**: workspaces are checkouts of it,
and Paperclip re-creates them.

Paperclip has no setting for the workspace root. The `PAPERCLIP_WORKSPACE_*` variables are per-run
values it injects into agents. Cloudron's `persistentDirs` are kept across updates and **excluded
from backups**, and may not sit under `/app/data`.

## Decision

- Declare `persistentDirs: ["/app/workspaces"]`.
- `start.sh` makes `$PAPERCLIP_HOME/instances/default/workspaces` a symlink to `/app/workspaces`,
  replacing a real directory if one exists: move its contents across once, then link. A backup copies
  the link, not the tree.
- Ownership is `cloudron:paperclip`, setgid `2770` (ADR 0002).
- Upstream's own database dumps are off (`PAPERCLIP_DB_BACKUP_ENABLED=false`), because Cloudron backs
  up the PostgreSQL add-on.

## Consequences

- **Update:** workspaces kept.
- **In-place restore:** workspaces kept. They may be newer than the restored database; Paperclip
  reconciles, and this is checked at gate 3.
- **Clone or restore elsewhere:** workspaces start empty, and Paperclip re-creates them from the
  repositories.
- **What is lost is uncommitted or unpushed agent work.** This is stated in the manifest checklist, in
  POSTINSTALL and in the announcement. Users are advised to have agents push branches as they go.
- **Optional object storage:** attachments, chat files, exports and runner handoffs can go to any
  S3-compatible store through `PAPERCLIP_STORAGE_S3_*`, set in `/app/data/env`. Those files then leave
  Cloudron's backup and must be backed up where they live. Workspaces cannot go there: they need a real
  filesystem.
- **Upstream is asked** for a durable work-in-progress policy (push a branch, or save a `git bundle`
  to the storage provider) and for a workspace-root setting. Either would remove the loss boundary.
