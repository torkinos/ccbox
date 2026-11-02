# Working on several directories at once

By default a session sees exactly one host directory: the one you launched from,
mounted at `/workspace/<name>-<hash>`: its basename plus a hash of the full
host path, e.g. `~/work/api` → `/workspace/api-e1263742`. There are two ways to
widen that.

The path is per directory on purpose. Claude Code files session history,
auto-memory and per-project state under the working directory's path, so a
shared fixed path would merge every project on the volume into one: `ccbox -c`
in one repo could resume another repo's conversation. Launching from the same
directory gives the same path, so `ccbox -c` and `--resume` find its earlier
sessions. (On macOS, type the path with the same case each time: `cd ~/code/API`
and `cd ~/code/api` reach one folder but can hash differently.)

## Launch from a common parent

If the directories are siblings, the simplest answer needs no configuration:

```bash
cd ~/work          # parent of api/, web/, shared/
ccbox
```

The whole tree is mounted as one workspace. The trade-off is that *everything*
under the parent is exposed, and Claude's working directory is the parent rather
than a project — so relative paths, `git` commands, and build tools all start
one level up from where you probably want them.

## `CCBOX_DIRS` — pick the directories explicitly

```bash
cd ~/work/api
CCBOX_DIRS=~/work/shared,~/work/web ccbox
```

The workspace is still `~/work/api`, and the extra directories appear at
`/mnt/shared` and `/mnt/web`. Each one is also passed to Claude Code as
`--add-dir`, which is the part that matters: a mount alone only makes files
*visible*, while `--add-dir` makes the directory a real working directory the
agent can read and edit without a prompt per file.

Append `:ro` to mount a directory read-only:

```bash
CCBOX_DIRS=~/work/shared:ro,~/work/web ccbox
```

Read-only is enforced by the kernel, not by Claude's permission system — a write
attempt fails with `Read-only file system` no matter what the agent decides.

Always working across the same set? Put it in your shell profile, same as
`CCBOX_SKILLS`:

```bash
# ~/.zshrc
export CCBOX_DIRS=~/work/shared:ro
```

## Details worth knowing

- **Mount names come from the directory's basename.** Collisions are numbered:
  `~/a/src` and `~/b/src` become `/mnt/src` and `/mnt/src-2`.
- **Tilde paths are expanded by ccbox.** In `CCBOX_DIRS=~/a,~/b` the shell only
  expands the *first* `~`, so ccbox expands the rest itself. Both forms work.
- **A missing directory warns and is skipped**, rather than killing the run.
  Passing `$PWD` is skipped too — it's already the workspace.
- **`/mnt`, not a subdirectory of the workspace.** Nesting a mount inside the
  workspace would create its mountpoint inside your real project directory on
  the host.
- **Moving or renaming a directory gives it a new path**, and so a fresh start
  for everything Claude Code keeps per project.
- **Upgrading from the old fixed `/workspace` path.** Everything Claude Code
  kept per project was filed under that one shared path, so after the upgrade
  it no longer applies anywhere: earlier sessions (`ccbox -c` won't find
  them), auto-memory, local-scope MCP servers from `claude mcp add`, and
  per-project allowed tools. Nothing is deleted. Sessions and memory stay in
  the volume at `~/.claude/projects/-workspace/`; to keep the memory for one
  project, copy its `memory/` folder into that project's new directory under
  `~/.claude/projects/` from `ccbox shell`. Re-add MCP servers with
  `--scope user` so they apply to every project.
- **Git worktrees are the exception.** For those, launch from the main repo root
  so the repo mounts as a unit; the bundled git records relative worktree links
  so they resolve on both sides.

You can also add a directory mid-session with Claude Code's `/add-dir` — but
only for paths already mounted, so `/mnt/...` after `CCBOX_DIRS`, or something
under the workspace. Nothing else from the host exists inside the container.
