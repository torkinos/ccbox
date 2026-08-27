# Security model

What the sandbox protects, what it deliberately doesn't, and the settings policy
baked into the image.

## Verified isolation properties

Checked against the built image:

| Property | Result |
|---|---|
| Host home (`/Users`, `~`) visible inside? | no |
| Host `~/.ssh` reachable? | no |
| Docker socket exposed? | no — no socket mount, no `--privileged` |
| `--cap-add` used? | none by default. `CCBOX_FIREWALL=on` adds `NET_ADMIN` for the entrypoint only, then drops it |
| Runs as root? | no — uid 1000 (`node`). With the firewall on the entrypoint is briefly uid 0, then `setpriv` drops to 1000 with `CapEff` and `CapBnd` both zero |
| Outbound network | unrestricted by default; default-deny allowlist with `CCBOX_FIREWALL=on` |
| Packages the agent installs | unchecked by default; scanned by Socket with `CCBOX_SOCKET=on`. A guard, not a boundary — `node` can still call `/usr/local/bin/npm` directly, and that is not closeable (see [npm supply-chain firewall](socket-firewall.md)) |
| Files written to the workspace | owned by **you** on the host, not root or 1000 |
| `git` on the mounted repo | works, no "dubious ownership" error |
| Credentials survive container exit | yes, in the volume |
| Credentials survive without the volume | no — fresh home, as intended |
| Agent can read the container's own credential files | no, via the Read/Edit tools — see [Managed settings](#managed-settings) for what that does and doesn't reach |
| Agent can disable the safety-net hook | no — force-enabled in managed settings, and the plugin itself is root-owned in `/opt` |
| Plugin version drifts on rebuild | no — pinned to a commit, and the build fails if the tag moved |

The only host path that crosses the boundary by default is `$PWD` — plus
whatever you name in `CCBOX_DIRS` and `CCBOX_SKILLS`, which mount nothing unless
set. Note that `$PWD` and `CCBOX_DIRS` entries are read-write by design:
**Claude can edit files in those directories, for real.** That is the point of
the tool, but it means the sandbox protects everything *except* the directories
you point it at. `CCBOX_SKILLS` mounts are always read-only, and a `CCBOX_DIRS`
entry can be made read-only with a `:ro` suffix.

## Managed settings

`managed-settings.json` is baked into `/etc/claude-code/`, which sits *outside*
the home volume, so it applies to every run including a fresh volume. Claude Code
reads it at the highest precedence in the settings hierarchy — **nothing in
`~/.claude` or a project's `.claude/settings.json` can override it.**

That makes it the right place to pin policy that a project (or a third-party
skill bundle that edits settings on install) must not be able to loosen. It is
also the only place that survives the home volume, which matters because
`/home/node` is a **per-project** volume: hardening applied by hand inside one
container does not follow you to the next repo.

It sets four things.

**Deny rules** on credential paths (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`,
`~/.docker/config.json`, `~/.config/gh/hosts.yml`, Claude Code's own
`.credentials.json`), on `.env` files anywhere under `/workspace`, on
`gh auth token`, and on the settings files the agent could otherwise use to
widen its own permissions. Each credential path is denied for `Read` *and*
`Edit` — a `Read` deny blocks the Edit tool but not Write or NotebookEdit, so
without the `Edit` half the agent could still write into `~/.ssh`.

> **What deny rules actually reach.** They cover Claude Code's own file tools
> (Read, Edit, Write, NotebookEdit), make matches invisible to Grep and Glob,
> and block Bash output redirection into a denied path. They are **not**
> OS-enforced: a Python or Node script that opens the file itself still reads
> it, and Bash file commands are on the edge — the docs describe `cat`, `head`,
> `tail` and `sed` as covered, but hard enforcement for those runs through
> Claude Code's OS sandbox, which needs bubblewrap that this image does not
> install. Treat the rules as removing the easy paths and the accidents, not as
> a boundary. **The egress firewall is what closes the exfiltration path**, and
> the container boundary is what closes the rest.

**`allowManagedHooksOnly: true`**, so a checked-out repo cannot run arbitrary
code through a `.claude/settings.json` hook. Only managed hooks and hooks from
plugins force-enabled here are loaded. Skills are unaffected — that is a
different setting, see below.

**`disableSideloadFlags: true`**, which rejects `--plugin-dir`, `--plugin-url`,
`--agents` and `--mcp-config`. Without it the agent can shell out to
`claude -p --mcp-config …` and get back the code execution the previous setting
just took away. `--add-dir` is not affected, so `CCBOX_DIRS` still works.

**`enabledPlugins`**, which force-enables the vendored safety-net plugin so it
cannot be turned off per project — see
[Vendored safety-net plugin](safety-net.md).

Three settings are deliberately **not** set, each because it would break
something this image relies on:

| Not set | Would break |
|---|---|
| `strictPluginOnlyCustomization` | Blocks skills from user sources — kills every `CCBOX_SKILLS` mount |
| `allowManagedPermissionRulesOnly` | Voids your own `allow` rules, so prompt volume jumps |
| `strictKnownMarketplaces` | An empty array is total lockdown; a non-empty allowlist also blocks the skills-dir scan unless you re-add it explicitly |

One collision worth knowing about: `Edit(~/.claude/settings.json)` also blocks
the `update-config` skill, which exists to edit that file. That is the intended
trade — the agent should not be able to widen its own permissions — but it fails
visibly rather than gracefully. Drop that one line if you'd rather keep the
skill working; the two `/workspace/.claude/...` rules are the ones that matter
against a hostile repo.
