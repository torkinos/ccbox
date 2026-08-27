# Loading your own skills

Point `CCBOX_SKILLS` at a directory of skills on the host. Every subdirectory
containing a `SKILL.md` is mounted read-only into `~/.claude/skills`:

```bash
CCBOX_SKILLS=~/path/to/your-skills/skills ccbox
```

To have it always on, put it in your shell profile:

```bash
# ~/.zshrc
export CCBOX_SKILLS=~/path/to/your-skills/skills
```

Edits to the source repo take effect on the next run — no rebuild, no re-copy.
A newly added skill is picked up automatically. Mounts are read-only, so a
session can read your skills but can't rewrite them.

## Why per-skill mounts, not one mount

Each skill directory is mounted individually rather than mounting the parent at
`~/.claude/skills`. That single parent mount would **shadow** the directory and
hide everything already installed inside the volume. Per-skill mounts are
additive — verified: a volume already holding installed skills plus 6 mounted
ones shows both sets, all readable.

## What doesn't work

Mounting the host's own `~/.claude/skills` looks like the obvious move, but that
directory is a farm of symlinks into `/Users/...`, which doesn't exist inside the
container — every one of them dangles. Mount the real skills directory the
symlinks point at, not the symlink farm.

Baking a `git clone` into the image doesn't work reliably either: `~/.claude`
lives inside the `ccbox-home` volume, and Docker only seeds a volume from the
image when that volume is **empty**. An existing volume silently keeps the old
contents, so image-baked skills appear on fresh volumes and never update on
established ones.

Plugins have a supported way around this that skills don't:
`CLAUDE_CODE_PLUGIN_SEED_DIR` points Claude Code at a read-only directory
*outside* `$HOME`, which it reads at startup on every run regardless of volume
state. That is how the safety-net hook is shipped — see
[Vendored safety-net plugin](safety-net.md).
