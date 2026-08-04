# ccbox — Claude Code in a Docker container

Run Claude Code inside a container with `git`, `gh`, and `ripgrep` preinstalled.
Only the current directory is bind-mounted; your Claude login, `gh` token, and
an SSH key live in a named Docker volume and never touch your host home.

This is a **Docker port of [ccbox](https://github.com/ralozkolya/ccbox)** by
Nikoloz Razmadze (MIT). The architecture is theirs: single bind mount,
credentials in a named volume, tools baked into the image, and a version-pinned
Claude Code layer that can be bumped without a full rebuild. Deviations are
marked `PORT:` in the source and summarised below.

## Quick start

Note the layout: the script is `ccbox/ccbox` — the **file** inside the
directory of the same name. Pointing at the directory won't run anything.

```bash
cd ccbox               # the repo directory
./ccbox build          # first build ~40s (git is compiled from source)
./ccbox auth           # one-time: sign in to Claude, gh; generates an SSH key
```

### Put it on your PATH

You launch ccbox from whatever project you want to work on, so it needs to be
callable from anywhere. Either use the full path to the *file*:

```bash
cd ~/some/project
~/work/personal/ccbox/ccbox          # note: .../ccbox/ccbox, not .../ccbox
```

or symlink it once and forget the path:

```bash
ln -s ~/work/personal/ccbox/ccbox ~/.local/bin/ccbox   # ~/.local/bin is already on your PATH
```

Then day to day, from any project directory:

```bash
ccbox                  # run Claude Code in $PWD
ccbox auto             # run with --permission-mode auto
ccbox shell            # bash shell in the container
ccbox update           # bump Claude Code (seconds — reuses the tools layer)
ccbox update 2.1.215   # pin a specific version
ccbox build --no-cache # full clean rebuild
ccbox help
```

`ccbox auth` only needs to run once. Everything persists in the `ccbox-home`
volume, including across Docker restarts and reboots.

If the browser sign-in completes but the container never notices, copy the code
shown in the browser and paste it at the terminal prompt.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `CCBOX_IMAGE` | `ccbox:latest` | Image tag |
| `CCBOX_VOLUME` | `ccbox-home` | Credential volume name |
| `CCBOX_NET` | `bridge` | Docker network to join |
| `CCBOX_PORTS` | — | Publish ports, comma-separated: `CCBOX_PORTS=3000,8080:80 ccbox` |
| `CCBOX_ENV` | — | Variable **names** to forward from your shell: `CCBOX_ENV=GH_TOKEN ccbox` |
| `CCBOX_SKILLS` | — | Host dirs of skills to mount read-only into `~/.claude/skills` |
| `CCBOX_DIRS` | — | Extra host dirs to work on, mounted at `/mnt/<name>` and passed as `--add-dir` |
| `CCBOX_USER` | — | Run as `uid:gid` (Linux only, see caveats) |

To let the agent reach your app's database and services by hostname, join your
compose network:

```bash
docker compose up -d
docker network ls                      # find it, e.g. myapp_default
CCBOX_NET=myapp_default ccbox
```

## Multiple environments

Three independent axes, all driven by the environment variables above. No code
changes needed.

**Separate logins** — different Claude/gh accounts, or a throwaway identity for
testing untrusted code. Each volume is a completely separate home directory:

```bash
CCBOX_VOLUME=cc-work     ccbox auth    # sign in as work
CCBOX_VOLUME=cc-personal ccbox auth    # sign in as personal
CCBOX_VOLUME=cc-work     ccbox         # uses the work login
```

Verified: writing to one volume leaves the other untouched. Deleting a volume
(`docker volume rm cc-work`) logs that identity out and destroys its SSH key,
without affecting the others.

**Separate toolchains** — copy this directory, edit its `install-tools.sh`, and
build under a different tag. `ccbox build` respects `CCBOX_IMAGE`:

```bash
cp -R ccbox ccbox-solana
# edit ccbox-solana/install-tools.sh — add install_solana, install_anchor, ...
cd ccbox-solana && CCBOX_IMAGE=ccbox:solana ./ccbox build
CCBOX_IMAGE=ccbox:solana ccbox            # run with that toolchain
```

**Concurrent sessions** — several containers can run at once, including on the
same volume. Verified: two containers sharing `ccbox-home` both start, and each
sees the other's writes live. That is the same situation as running `claude` in
two terminals on your host, and behaves the same way: fine in practice, but two
sessions are writing one `~/.claude`, so use separate volumes if you want their
histories and settings genuinely independent.

Mixing axes works as expected:

```bash
CCBOX_IMAGE=ccbox:solana CCBOX_VOLUME=cc-work CCBOX_PORTS=3000 ccbox
```

### Wrappers

Typing the variables gets old. Either alias them:

```bash
alias ccwork='CCBOX_VOLUME=cc-work ccbox'
alias ccsol='CCBOX_IMAGE=ccbox:solana CCBOX_VOLUME=cc-solana ccbox'
```

or drop a two-line launcher on your PATH per environment:

```bash
#!/usr/bin/env bash
# ~/.local/bin/ccwork
exec env CCBOX_VOLUME=cc-work ~/work/personal/ccbox/ccbox "$@"
```

## Working on several directories at once

By default a session sees exactly one host directory: the one you launched from,
mounted at `/workspace`. There are two ways to widen that.

### Launch from a common parent

If the directories are siblings, the simplest answer needs no configuration:

```bash
cd ~/work          # parent of api/, web/, shared/
ccbox
```

The whole tree is mounted as one workspace. The trade-off is that *everything*
under the parent is exposed, and Claude's working directory is the parent rather
than a project — so relative paths, `git` commands, and build tools all start
one level up from where you probably want them.

### `CCBOX_DIRS` — pick the directories explicitly

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

Details worth knowing:

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

## Loading your own skills

Point `CCBOX_SKILLS` at a directory of skills on the host. Every subdirectory
containing a `SKILL.md` is mounted read-only into `~/.claude/skills`:

```bash
CCBOX_SKILLS=~/work/personal/agent-skills/skills ccbox
```

To have it always on, put it in your shell profile:

```bash
# ~/.zshrc
export CCBOX_SKILLS=~/work/personal/agent-skills/skills
```

Edits to the source repo take effect on the next run — no rebuild, no re-copy.
A newly added skill is picked up automatically. Mounts are read-only, so a
session can read your skills but can't rewrite them.

### Why per-skill mounts, not one mount

Each skill directory is mounted individually rather than mounting the parent at
`~/.claude/skills`. That single parent mount would **shadow** the directory and
hide everything already installed inside the volume. Per-skill mounts are
additive — verified: a volume holding 35 skills plus 6 mounted ones shows 41,
with both sets readable.

### What doesn't work

Mounting the host's own `~/.claude/skills` looks like the obvious move, but that
directory is a farm of symlinks into `/Users/...`, which doesn't exist inside the
container — every one of them dangles. Mount the real skills directory the
symlinks point at, not the symlink farm.

Baking a `git clone` into the image doesn't work reliably either: `~/.claude`
lives inside the `ccbox-home` volume, and Docker only seeds a volume from the
image when that volume is **empty**. An existing volume silently keeps the old
contents, so image-baked skills appear on fresh volumes and never update on
established ones.

## Reading Figma designs

Yes — and the good route needs no credentials inside the container at all.

### Route A: the Figma desktop app's MCP server (recommended)

The Figma desktop app runs a local **Dev Mode MCP server** on `127.0.0.1:3845`.
The container can reach it, and **authentication stays on the host** — the
desktop app is already signed in, so no token, OAuth flow, or browser is needed
inside the sandbox.

Prerequisites on the host: Figma desktop running, with the Dev Mode MCP server
enabled (Figma menu → Preferences → Enable Dev Mode MCP Server). It needs a paid
Dev/Full seat.

One-time, inside the container:

```bash
ccbox shell
claude mcp add --scope user --transport http figma http://host.docker.internal:3845/mcp
```

`--scope user` writes it to `~/.claude.json` in the volume, so it persists and
applies to every project. `host.docker.internal` is the Docker Desktop hostname
for "the machine running Docker" — verified reachable from the container, and
verified to complete a full MCP handshake with the Figma server.

Confirm it's live:

```bash
claude mcp list      # figma: ... - ✔ Connected
```

The server exposes six tools, all read-only — exactly the design-reading side:

`get_design_context` · `get_metadata` · `get_screenshot` · `get_variable_defs` ·
`get_motion_context` · `get_figjam`

### Add the Figma skills too

The Figma plugin's skills are what tell the agent *how* to use those tools —
`figma-design-to-code` declares itself a mandatory prerequisite to
`get_design_context`. Mount them with `CCBOX_SKILLS`:

```bash
# ~/.zshrc — the glob keeps working after the plugin updates
export CCBOX_SKILLS="$HOME/work/personal/agent-skills/skills,$(ls -d $HOME/.claude/plugins/cache/claude-plugins-official/figma/*/skills | tail -1)"
```

All 12 skills mount cleanly. They cross-reference each other with relative paths
like `../figma-use/references/gotchas.md`, and those still resolve, because
per-skill mounts land them all as siblings under `~/.claude/skills/` — verified
inside a container.

### Caveats

- **Needs the network.** `CCBOX_NET=none` cuts this off, as it should.
- **The host reachability is a real hole in the sandbox.** Anything in the
  container can talk to *any* service listening on your Mac's loopback, not just
  Figma — databases, dev servers, other local APIs. That's the price of this
  route. `CCBOX_NET=none` closes it for runs that don't need Figma.
- **The plugin path is version-pinned** (`figma/2.2.87/skills`). The glob above
  handles updates; a hardcoded path silently stops mounting after an upgrade.

### Route B: the hosted Figma MCP server

The Figma plugin on your host actually points at `https://mcp.figma.com/mcp`,
which the container can also reach. The problem is auth: it uses OAuth, and the
callback lands on localhost *inside* the container, where your Mac's browser
can't reach it. You'd need to publish the callback port with `CCBOX_PORTS`, and
the port isn't fixed. Route A avoids the whole problem.

### Route C: no MCP at all

Export the frames from Figma to PNG/SVG on the host, and mount the folder:

```bash
CCBOX_DIRS=~/Desktop/design-exports:ro ccbox
```

Claude reads images directly. Zero credentials, zero network, nothing on
loopback — but you re-export by hand whenever the design changes.

## Giving the sandbox read-only GitHub access

Use a **fine-grained** personal access token. Classic tokens can't express
read-only for private repos — the `repo` scope is read *and* write,
all-or-nothing. (For public repos only, a classic token with **zero** scopes is
already read-only.)

### 1. Create the token

github.com → Settings → Developer settings →
[Fine-grained tokens](https://github.com/settings/personal-access-tokens/new)

- **Resource owner**: your account, or the org that owns the repos
- **Repository access**: *Only select repositories* → pick just what the agent needs
- **Expiration**: keep it short; you can always mint another
- **Repository permissions** — set only these:

| Permission | Level | Why |
|---|---|---|
| Metadata | Read-only | mandatory, auto-selected |
| Contents | Read-only | clone and read code |
| Issues | Read-only | *optional* — only if the agent should read issues |
| Pull requests | Read-only | *optional* — only if it should read PRs |

Leave everything else at *No access*. With Contents at read-only the token
physically cannot push, open PRs, or change settings.

If it's an org repo, an owner may need to approve the token before it works.

### 2. Get it into the container

**Ephemeral** — nothing stored, gone when the container exits:

```bash
export GH_TOKEN=github_pat_...          # in your shell, or read from a password manager
CCBOX_ENV=GH_TOKEN ccbox
```

`gh` and `git` both honour `GH_TOKEN` with no extra setup. `CCBOX_ENV` takes
variable *names*, so the secret never lands in your shell history, the command
line, or `ps` output.

**Persistent** — log in once, remembered in the volume:

```bash
ccbox shell
gh auth login --with-token              # paste the token, then Ctrl-D
gh auth setup-git                       # so `git clone/fetch` over HTTPS uses it
exit
```

`gh` stores this under `~/.config/gh` **inside the volume**, never on your host.

### 3. Isolate it

Give the read-only identity its own volume, so it can't reach a fuller-privileged
login you use elsewhere:

```bash
CCBOX_VOLUME=cc-readonly ccbox shell    # set the token up in here
CCBOX_VOLUME=cc-readonly ccbox          # work with it
docker volume rm cc-readonly            # revoke locally, instantly
```

### What this does and doesn't buy you

Read-only genuinely prevents the agent from **changing** anything on GitHub — no
pushes, no force-pushes, no deleted branches, no edited workflows.

It does **not** stop private code the token can read from *leaving*. The
container has outbound network by default, so anything readable is exfiltratable
by a determined prompt injection. If that's your threat model, scope the token to
the minimum set of repos, and consider `CCBOX_NET=none` for runs that don't need
the network at all.

Also note: a forwarded variable is visible via `docker inspect` on the running
container. That's local-root-equivalent access, so it isn't a meaningful leak on
your own machine, but it's not a secret store either. Revoke tokens at
github.com/settings/tokens when you're done with them.

## Verified isolation properties

Checked on this machine against the built image:

| Property | Result |
|---|---|
| Host home (`/Users`, `~`) visible inside? | no |
| Host `~/.ssh` reachable? | no |
| Docker socket exposed? | no — no socket mount, no `--privileged`, no `--cap-add` |
| Runs as root? | no — uid 1000 (`node`) |
| Files written to the workspace | owned by **you** on the host, not root or 1000 |
| `git` on the mounted repo | works, no "dubious ownership" error |
| Credentials survive container exit | yes, in the volume |
| Credentials survive without the volume | no — fresh home, as intended |

The only host path that crosses the boundary by default is `$PWD` — plus
whatever you name in `CCBOX_DIRS` and `CCBOX_SKILLS`, which mount nothing unless
set. Note that `$PWD` and `CCBOX_DIRS` entries are read-write by design:
**Claude can edit files in those directories, for real.** That is the point of
the tool, but it means the sandbox protects everything *except* the directories
you point it at. `CCBOX_SKILLS` mounts are always read-only, and a `CCBOX_DIRS`
entry can be made read-only with a `:ro` suffix.

## What changed from upstream

| Upstream (podman) | Here (Docker) | Why |
|---|---|---|
| `podman` throughout | `docker` | Different runtime |
| rootless-podman enforcement | daemon-reachable check | Docker has no rootful/rootless split of that kind |
| `--userns=keep-id:uid=1000,gid=1000` | dropped | Docker Desktop on macOS already maps container uid 1000 to your host user — verified. Linux users see `CCBOX_USER` below |
| default network `podman` | `bridge` | Docker's default |
| `TZ=Asia/Tbilisi` hardcoded | `ARG TZ=UTC` | Author's locale. `./ccbox build --build-arg TZ=Europe/Berlin` |
| Atlassian MCP auto-registered | removed | Third-party endpoint not part of this project |
| `gcloud` installed | function kept, not called | Adds ~1 GB and unused here. Add `install_gcloud` to the call list in `install-tools.sh` to enable |

Kept deliberately: the git-from-source build, the SELinux `:z` logic (correct on
Docker too, and already skipped on macOS), and the bash 3.2 `load_flags`
workaround, since macOS still ships bash 3.2.

## Adding tools

`install-tools.sh` is the single seam. Write an `install_<name>` function and add
it to the call list at the bottom, then `./ccbox build`. Functions run as root
during the build.

## Managed settings

`managed-settings.json` is baked into `/etc/claude-code/`, which sits *outside*
the home volume, so it applies to every run including a fresh volume. Claude Code
reads it at the highest precedence in the settings hierarchy — **nothing in
`~/.claude` or a project's `.claude/settings.json` can override it.**

That makes it the right place to pin policy that a project (or a third-party
skill bundle that edits settings on install) must not be able to loosen. It
currently sets only `respondToBashCommands: false`, inherited from upstream.

## Caveats

- **The workspace is writable.** Claude's edits land on your real disk. Launch
  from the project you intend it to change.
- **Linux uid mapping.** Docker on Linux does not remap uids the way Docker
  Desktop does, so files would land owned by uid 1000. If your host uid isn't
  1000, use `CCBOX_USER="$(id -u):$(id -g)" ccbox`. Not needed on macOS.
- **Git worktrees.** Launch from the main repo root, not from inside a worktree,
  so the whole repo mounts as a unit. Host git must be ≥ 2.48 to read repos
  using relative worktrees.
- **git tarball isn't signature-verified.** Fetched over HTTPS from
  `mirrors.edge.kernel.org` and the observed sha256 is printed during the build,
  but not checked against a pinned value or kernel.org's signature. Same as
  upstream; worth tightening if you care about that supply-chain link.
- **Claude Code can't self-update in here** — npm's global dir is root-owned by
  design. Use `ccbox update`.
- **First build compiles git**, so `--no-cache` rebuilds are not instant.

## Fixed relative to upstream

Upstream dispatches with `case "${1:-run}"` and then `shift`s in the `run)`
branch. `${1:-run}` *expands* to `run` without setting `$1`, so with no
arguments `shift` runs against an empty positional list, returns 1, and
`set -e` exits before `cmd_run` is reached — bare `ccbox`, the documented
default invocation, silently does nothing and exits 1. Here the dispatch
matches `"${1:-}"` so no-args falls through to `*)`, and every branch that
shifts is guaranteed a positional to shift.

## Upstream security review

The upstream repo was reviewed at commit `d23cf7d` before porting: 7 text files,
no binaries, single author, MIT licensed, 15 coherent commits. No obfuscation,
no `eval`, no `curl | bash`, no `/dev/tcp`, no base64 blobs. Every URL is an
official source (github cli apt, kernel.org, Google Cloud apt, Atlassian MCP).
Only two mounts, no socket exposure, no `--privileged`. The generated SSH key
never leaves the volume — only the `.pub` is ever printed.

That review covers a point in time, not future commits.
