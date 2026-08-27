# ccbox — Claude Code in a Docker container

Run Claude Code inside a container with `git`, `gh`, and `ripgrep` preinstalled.
Only the current directory is bind-mounted; your Claude login, `gh` token, and
an SSH key live in a named Docker volume and never touch your host home.

## Features

- **One-directory blast radius** — the agent sees the directory you launch
  from, mounted at `/workspace`, and nothing else from your host. Widen it
  deliberately with [`CCBOX_DIRS`](docs/directories.md), read-only if you like.
- **Credentials in a volume, not your home** — sign in once with `ccbox auth`;
  logins and an SSH key persist in a named volume you can swap or destroy.
  Separate volumes give you [separate identities](docs/environments.md).
- **Opt-in egress firewall** — `CCBOX_FIREWALL=on` turns on a default-deny
  allowlist enforced by iptables before the agent starts, installed by root and
  unreachable from uid 1000. It [fails closed](docs/firewall.md).
- **Opt-in npm supply-chain firewall** — `CCBOX_SOCKET=on` routes `npm`/`npx`/
  `yarn` through [Socket Firewall](docs/socket-firewall.md) as a PATH shim, so
  it also covers installs the agent runs on its own.
- **Locked-down managed settings** — deny rules on credential paths and
  settings files, hostile-repo hook protection, and no sideloading, pinned at
  the [highest settings precedence](docs/security.md#managed-settings).
- **Destructive-command hook, pinned** — the CC Safety Net plugin is
  [vendored at an exact commit](docs/safety-net.md), force-enabled, root-owned,
  and byte-verifiable against upstream.
- **Your skills, mounted read-only** — point [`CCBOX_SKILLS`](docs/skills.md)
  at a skills repo; edits apply on the next run, no rebuild.
- **Figma without credentials in the sandbox** — the desktop app's local MCP
  server does the auth on the host; the container [just connects](docs/figma.md).
- **Fast version bumps** — `ccbox update` bumps Claude Code in seconds by
  reusing the tools layer; `ccbox update <version>` pins one.

## Quick start

You need Docker installed and running (Docker Desktop on macOS). Clone this
repository, then:

```bash
cd ccbox               # the repo directory
./ccbox build          # first build ~40s (git is compiled from source)
./ccbox auth           # one-time: sign in to Claude, gh; generates an SSH key
```

Note the layout: the script is `ccbox/ccbox` — the **file** inside the
directory of the same name. Pointing at the directory won't run anything.

You launch ccbox from whatever project you want to work on, so put it on your
PATH:

```bash
ln -s ~/path/to/ccbox/ccbox ~/.local/bin/ccbox
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
volume, including across Docker restarts and reboots. If the browser sign-in
completes but the container never notices, copy the code shown in the browser
and paste it at the terminal prompt.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CCBOX_IMAGE` | `ccbox:latest` | Image tag |
| `CCBOX_VOLUME` | `ccbox-home` | Credential volume name |
| `CCBOX_NET` | `bridge` | Docker network to join — e.g. [your compose network](docs/environments.md#joining-your-apps-docker-network) |
| `CCBOX_PORTS` | — | Publish ports, comma-separated: `CCBOX_PORTS=3000,8080:80 ccbox` |
| `CCBOX_ENV` | — | Variable **names** to forward from your shell: `CCBOX_ENV=GH_TOKEN ccbox` |
| `CCBOX_SKILLS` | — | Host dirs of skills to mount read-only into `~/.claude/skills` — see [skills](docs/skills.md) |
| `CCBOX_DIRS` | — | Extra host dirs to work on, mounted at `/mnt/<name>` and passed as `--add-dir` — see [directories](docs/directories.md) |
| `CCBOX_USER` | — | Run as `uid:gid` (Linux only, see [caveats](#caveats)) |
| `CCBOX_FIREWALL` | — | `on` enables the default-deny egress allowlist — [all firewall variables](docs/firewall.md#configuration) |
| `CCBOX_SOCKET` | — | `on` routes npm installs through Socket Firewall — [all Socket variables](docs/socket-firewall.md#configuration) |

## Security model in one paragraph

The container boundary keeps the agent away from your host; the only host paths
inside are `$PWD` and whatever you name in `CCBOX_DIRS`/`CCBOX_SKILLS` — and
those first two are **read-write by design**: Claude edits your real files.
Egress is unrestricted unless you turn the firewall on, so by default anything
in the container can reach the internet, credentials in hand. Managed settings
remove the easy credential grabs but are not OS-enforced. The full picture,
verified property by property, is in [Security model](docs/security.md);
read-only GitHub tokens are covered in
[GitHub access](docs/github-access.md).

## Documentation

| Doc | Covers |
|---|---|
| [Egress firewall](docs/firewall.md) | Default-deny allowlist: how it holds, what's allowed, extending it, fail-closed rules |
| [npm supply-chain firewall](docs/socket-firewall.md) | Socket Firewall shim: why a PATH shim, fail-closed behaviour, limits |
| [Security model](docs/security.md) | Verified isolation properties, managed settings policy |
| [Vendored safety-net plugin](docs/safety-net.md) | Why vendored, bumping the pin, verifying the bytes |
| [Multiple environments](docs/environments.md) | Separate logins, toolchains, concurrent sessions, wrappers |
| [Several directories](docs/directories.md) | `CCBOX_DIRS`, read-only mounts, worktrees |
| [Skills](docs/skills.md) | Mounting your skills, why per-skill mounts |
| [Figma](docs/figma.md) | Reading designs via the desktop app's MCP server, no credentials inside |
| [GitHub access](docs/github-access.md) | Read-only fine-grained tokens, ephemeral vs persistent |
| [Origins](docs/origins.md) | Provenance, what changed from the original project |

## Adding tools

`install-tools.sh` is the single seam. Write an `install_<name>` function and add
it to the call list at the bottom, then `./ccbox build`. Functions run as root
during the build. Some functions ship uncalled — add `install_gcloud` to the
call list if you want it (~1 GB). The image timezone is a build arg:
`./ccbox build --build-arg TZ=Europe/Berlin`.

## Caveats

- **The workspace is writable.** Claude's edits land on your real disk. Launch
  from the project you intend it to change.
- **Egress is unrestricted unless you ask.** `CCBOX_FIREWALL` is opt-in — see
  [Egress firewall](docs/firewall.md).
- **Linux uid mapping.** Docker on Linux does not remap uids the way Docker
  Desktop does, so files would land owned by uid 1000. If your host uid isn't
  1000, use `CCBOX_USER="$(id -u):$(id -g)" ccbox`. Not needed on macOS.
- **Git worktrees**: launch from the main repo root, host git ≥ 2.48 — see
  [directories](docs/directories.md).
- **Claude Code can't self-update in here** — npm's global dir is root-owned by
  design. Use `ccbox update`.
- **Deny rules are not OS-enforced** — see
  [what they actually reach](docs/security.md#managed-settings).
- **git tarball isn't signature-verified** — fetched over HTTPS from
  `mirrors.edge.kernel.org`, sha256 printed but not checked against a pinned
  value. Worth tightening if you care about that supply-chain link.
- **The safety-net hook spawns a node process per Bash tool call** — small, but
  not free.
- **First build compiles git**, so `--no-cache` rebuilds are not instant.

## Credits

ccbox started as a Docker port of
[ralozkolya/ccbox](https://github.com/ralozkolya/ccbox) (MIT) and has since
diverged substantially; the firewalls, managed settings policy, and plugin seed
are new here. Details in [Origins](docs/origins.md). The egress firewall is
adapted from Anthropic's devcontainer `init-firewall.sh`; the vendored
[CC Safety Net](https://github.com/kenryu42/cc-safety-net) plugin is MIT by its
own author.
