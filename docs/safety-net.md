# Vendored safety-net plugin

The [CC Safety Net](https://github.com/kenryu42/cc-safety-net) PreToolUse hook
ships in the image. It intercepts every Bash tool call and blocks destructive
git and filesystem commands before they run — `find -delete`,
`git reset --hard`, and so on.

## Why it's vendored

Installing it the normal way (`/plugin marketplace add kenryu42/cc-marketplace`)
has two problems here. It lands in `~/.claude/plugins` on the home volume, so it
protects one project and no others. And the upstream marketplace manifest
sources the plugin unpinned:

```json
{ "source": "url", "url": "https://github.com/kenryu42/cc-safety-net.git" }
```

No `ref`, no `sha` — so it clones default-branch HEAD while reporting whatever
version the manifest claims. A container installed this way reported version
`1.0.6` with the bytes of an unreleased commit.

So the plugin is vendored instead, under `plugin-seed/`:

```
plugin-seed/
├── known_marketplaces.json                       # registers the marketplace
├── PROVENANCE                                    # tag, commit, file set
└── marketplaces/cc-marketplace/
    ├── .claude-plugin/marketplace.json           # local mirror of the manifest
    └── safety-net/                               # upstream, pruned to what runs
```

That tree is copied to `/opt/claude-code/plugin-seed` and named by
`CLAUDE_CODE_PLUGIN_SEED_DIR`. Claude Code reads a seed directory at startup on
every run, so it is immune to the volume-shadowing problem (see
[Loading your own skills](skills.md)), and it gets three properties for free:
**auto-update is forced off** for seed marketplaces,
`/plugin marketplace remove|update` **fails** against them, and the seed itself
is **never written to** — which is why it can live root-owned and read-only in
`/opt` where the `node` user cannot touch it.

Only the runtime file set is vendored: `dist/bin/cc-safety-net.js` is a
self-contained bundle importing nothing but `node:` builtins, so the other
entry points, the type declarations, `src/`, `tests/` and a screenshot are all
dropped. 380 KB instead of 2.2 MB.

## Bumping the pin

```bash
./tools/vendor-safety-net.sh v1.0.7 <commit-sha>   # re-vendor
./tools/vendor-safety-net.sh --verify              # prove it matches
./ccbox build
```

Review the upstream `src/` diff between tags on GitHub first — diffing a
minified bundle tells you nothing. The script clones the tag, **fails if the tag
resolves to a different commit than the SHA you passed**, copies the runtime
file set, and smoke-tests that the bundle still runs and still blocks a
destructive command. `--verify` re-fetches the recorded commit and compares
byte-for-byte, failing on both modified and extra files — that is what makes
"the code I reviewed is the code I shipped" checkable later.

## Migrating an existing volume

Volumes that already have the per-project install keep a stale, unpinned copy.
The seed takes precedence so the stale copy is not loaded, but it stays on disk
and will confuse you. Once per volume:

```bash
ccbox shell -c 'rm -rf ~/.claude/plugins/marketplaces/cc-marketplace \
                      ~/.claude/plugins/cache/cc-marketplace'
```

Don't run `/plugin install safety-net@cc-marketplace` afterwards. It resolves
from the seed, so the bytes are right, but it *copies* them into
`~/.claude/plugins/cache` on the volume — where the agent can edit them.
Leaving it to `enabledPlugins` uses the read-only seed in place, with no copy.

## Reviewing what ships

The safety-net plugin is the one dependency committed into this repo rather than
fetched. It is a separate project by a separate author (MIT, `LICENSE`
included), and `dist/bin/cc-safety-net.js` is a 350 KB pre-built bundle — so
unlike the rest of this repo, it is **not** something you can review by reading
it here.

What you get instead: `plugin-seed/PROVENANCE` names the exact upstream commit,
and `tools/vendor-safety-net.sh --verify` proves the committed bytes are that
commit's bytes and nothing else. Review the upstream `src/` at that tag on
GitHub; the script is what ties your review to what actually ships.
