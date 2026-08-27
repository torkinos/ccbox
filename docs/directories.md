# Working on several directories at once

By default a session sees exactly one host directory: the one you launched from,
mounted at `/workspace`. There are two ways to widen that.

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

`/workspace` is still `~/work/api`, and the extra directories appear at
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
  Passing `$PWD` is skipped too — it's already at `/workspace`.
- **`/mnt`, not a subdirectory of `/workspace`.** Nesting a mount inside the
  workspace would create its mountpoint inside your real project directory on
  the host.
- **Git worktrees are the exception.** For those, launch from the main repo root
  so the repo mounts as a unit; the bundled git records relative worktree links
  so they resolve on both sides.

You can also add a directory mid-session with Claude Code's `/add-dir` — but
only for paths already mounted, so `/mnt/...` after `CCBOX_DIRS`, or something
under `/workspace`. Nothing else from the host exists inside the container.
