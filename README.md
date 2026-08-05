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

Egress firewall — opt-in, off unless `CCBOX_FIREWALL=on`. See
[Egress firewall](#egress-firewall).

| Variable | Default | Purpose |
|---|---|---|
| `CCBOX_FIREWALL` | — | `on` enables the default-deny egress allowlist |
| `CCBOX_ALLOWED_DOMAINS` | — | Extra host names to allow, comma-separated |
| `CCBOX_ALLOWLIST_FILE` | — | Host file of extra host names, one per line. Must not be inside the directory you launch from |
| `CCBOX_ALLOWED_PORTS` | `80,443` | TCP ports allowed to allowed hosts |
| `CCBOX_FIREWALL_LOCAL` | `subnet` | `subnet` \| `gateway` \| `off` — how much of the container's own Docker network stays reachable |
| `CCBOX_FIREWALL_REFRESH` | `1800` | Re-resolve interval in seconds; `0` disables |
| `CCBOX_DNS` | — | Pin the upstream resolver. Only needed if a user-defined `CCBOX_NET` can't reach DNS otherwise |

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
  route. `CCBOX_NET=none` closes it for runs that don't need Figma, and
  `CCBOX_FIREWALL_LOCAL=off` closes it while keeping internet egress (which
  also stops Route A working).
- **Works with the egress firewall on.** `host.docker.internal` stays reachable
  by default, and the Figma asset hosts are in the baked-in allowlist.
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

It does **not**, on its own, stop private code the token can read from *leaving*.
The container has outbound network by default, so anything readable is
exfiltratable by a determined prompt injection. Scope the token to the minimum
set of repos, and pick one of:

- `CCBOX_FIREWALL=on` — a default-deny egress allowlist, so there is nowhere to
  send it. See [Egress firewall](#egress-firewall) below.
- `CCBOX_NET=none` — no network at all, for runs that don't need one.

Also note: a forwarded variable is visible via `docker inspect` on the running
container. That's local-root-equivalent access, so it isn't a meaningful leak on
your own machine, but it's not a secret store either. Revoke tokens at
github.com/settings/tokens when you're done with them.

## Egress firewall

Off by default. Turn it on per run, or export it:

```bash
CCBOX_FIREWALL=on ccbox
```

With it on, the container can reach the allowlist and nothing else. Everything
else is rejected immediately — no proxy to negotiate with, no timeout to wait
out. That closes the gap the section above describes: a prompt injection can
still *read* your GitHub token and your Claude Code credentials, but it has
nowhere to send them.

### How it holds

The rules are installed by a root entrypoint **before** Claude Code starts, and
then the entrypoint drops to uid 1000 and execs it:

```
docker run --user 0:0 --cap-add=NET_ADMIN --security-opt=no-new-privileges
   └─ ccbox-entrypoint            uid 0, CAP_NET_ADMIN
        ├─ ccbox-init-firewall    resolve → ipset → iptables → self-test
        ├─ background re-resolver uid 0
        └─ exec setpriv …         → claude, uid 1000, CapEff 0, CapBnd 0
```

`NET_ADMIN` exists only for the entrypoint. By the time your agent is running,
`setpriv` has cleared the capability bounding set, so `NET_ADMIN` isn't merely
unheld — it is unreachable, even through the setuid-root binaries Debian ships.
There is no `sudo`. Both scripts live in root-owned `/usr/local/bin` inside the
image, never on a volume. Verify any of this yourself:

```bash
CCBOX_FIREWALL=on ccbox shell
grep -E 'CapEff|CapBnd|NoNewPrivs' /proc/1/status   # 0, 0, 1
iptables -L                                          # permission denied
```

Setting `CCBOX_FIREWALL=off` *inside* the container does nothing: it is read
once, by root, before privileges are dropped. The rules are already in place.

### What's allowed

Baked into the image (`ccbox-init-firewall`):

| Group | Hosts |
|---|---|
| Claude Code | `api.anthropic.com`, `statsig.anthropic.com`, `statsig.com`, `sentry.io`, `claude.ai` |
| GitHub | `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, `ssh.github.com`, plus every IPv4 range from `api.github.com/meta` |
| Packages | `registry.npmjs.org`, `registry.yarnpkg.com`, `repo.yarnpkg.com` |
| Figma | `www.figma.com`, `api.figma.com`, and the S3 hosts that serve image assets |

Plus, structurally: loopback, DNS to the resolvers in `/etc/resolv.conf`, the
container's own Docker network, and `host.docker.internal`. Those last two are
what keep `CCBOX_NET=<project>_default` and Figma Route A working — they are
host-local, not internet egress, and `CCBOX_FIREWALL_LOCAL=gateway` or `off`
narrows them.

Only TCP 80 and 443 are allowed to allowlisted hosts (`CCBOX_ALLOWED_PORTS`
widens that), and **port 22 only to GitHub's `git` ranges** — SSH to anywhere
else is blocked, because a blanket port 22 is an exfiltration channel with extra
steps.

### Extending it

Two host-controlled inputs, both merged with the defaults:

```bash
CCBOX_FIREWALL=on CCBOX_ALLOWED_DOMAINS=api.stripe.com,cdn.example.com ccbox

# or, for a list you reuse:
CCBOX_FIREWALL=on CCBOX_ALLOWLIST_FILE=~/.config/ccbox/allowed-domains ccbox
```

The file takes one host name per line, `#` comments allowed. It is mounted
read-only at `/etc/ccbox/allowed-domains` and must be owned by root and not
group- or world-writable, or the container refuses to start.

**The allowlist is never read from `/workspace`.** The launcher rejects a
`CCBOX_ALLOWLIST_FILE` that resolves inside the directory you launched from, and
the container never looks in `/workspace`, `/home/node` or `/mnt` for one. All
three are writable from inside, so an allowlist kept there would let a
checked-out repo — or the agent itself — widen its own egress, which is the
whole thing this prevents. (Same class of issue as GHSA-mmgp-wc2j-qcv7.)

Host names only. An IP, CIDR, URL or glob is rejected rather than quietly
half-applied.

### It fails closed

If the firewall cannot be applied *exactly* as asked, the container does not
start. A firewall that fails open is worse than none, because you think you
have one. Any of these is fatal:

- a domain in the allowlist doesn't resolve
- `api.github.com/meta` is unreachable or malformed
- either ipset ends up empty
- `--cap-add=NET_ADMIN` wasn't given, or the entrypoint isn't root
- the kernel can't match ipsets from iptables
- IPv6 is reachable but `ip6tables` isn't
- the boot self-test fails: `example.com` must be unreachable over both IPv4 and
  IPv6, and `api.anthropic.com` and `api.github.com` must be reachable

The effective allowlist, its sources, and every resolved address are printed at
startup and appended to `/var/log/ccbox-firewall.log`, which `node` can read but
not write.

### Notes

- **Addresses are a snapshot.** Allowlisting is by name, enforced by IP.
  Cloudflare-fronted hosts rotate, so a background root process re-resolves the
  same list every 30 minutes and adds anything new — additive only, never
  widening past the list logged at boot. `CCBOX_FIREWALL_REFRESH=0` turns it off.
- **Shared IPs are shared.** Allowing a host on a CDN can incidentally allow its
  neighbours on the same address.
- **DNS on a user-defined network.** `CCBOX_NET=<project>_default` makes Docker
  put its embedded resolver (`127.0.0.11`) in `resolv.conf`, and that forwards
  upstream from inside the container to an address nothing inside can discover.
  It's handled automatically; if DNS still fails, pin it with
  `CCBOX_DNS=<your resolver IP>`.
- **`CCBOX_NET=host` is refused** — the container would share your machine's
  network namespace and the rules would rewrite your *host's* firewall.
  `CCBOX_NET=none` skips the firewall, having no network to filter.
- **This protects egress, not the workspace.** Claude can still edit every file
  you mounted.

### Testing it

```bash
./test/firewall-test.sh              # no credentials needed
./test/firewall-test.sh --with-auth  # also git-over-SSH and a real install
```

## Verified isolation properties

Checked on this machine against the built image:

| Property | Result |
|---|---|
| Host home (`/Users`, `~`) visible inside? | no |
| Host `~/.ssh` reachable? | no |
| Docker socket exposed? | no — no socket mount, no `--privileged` |
| `--cap-add` used? | none by default. `CCBOX_FIREWALL=on` adds `NET_ADMIN` for the entrypoint only, then drops it |
| Runs as root? | no — uid 1000 (`node`). With the firewall on the entrypoint is briefly uid 0, then `setpriv` drops to 1000 with `CapEff` and `CapBnd` both zero |
| Outbound network | unrestricted by default; default-deny allowlist with `CCBOX_FIREWALL=on` |
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
| no egress control | opt-in `CCBOX_FIREWALL=on` | New here, not upstream. Adapted from Anthropic's devcontainer `init-firewall.sh`, with the fixes listed in [Egress firewall](#egress-firewall) |

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
- **Egress is unrestricted unless you ask.** `CCBOX_FIREWALL` is opt-in, so by
  default anything running in the container can reach anything on the internet —
  including with your GitHub token in hand. See
  [Egress firewall](#egress-firewall).

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
