# Origins and provenance

ccbox began as a Docker port of [ccbox](https://github.com/ralozkolya/ccbox) by
Nikoloz Razmadze (MIT) and has since diverged substantially — the egress
firewall, npm supply-chain firewall, managed settings policy, and vendored
plugin seed are all new here. The original's core architecture survives: single
bind mount, credentials in a named volume, tools baked into the image, and a
version-pinned Claude Code layer that can be bumped without a full rebuild.

Deviations made during the original port are marked `PORT:` in the source.

## What changed from the original

| Original (podman) | Here (Docker) | Why |
|---|---|---|
| `podman` throughout | `docker` | Different runtime |
| rootless-podman enforcement | daemon-reachable check | Docker has no rootful/rootless split of that kind |
| `--userns=keep-id:uid=1000,gid=1000` | dropped | Docker Desktop on macOS already maps container uid 1000 to your host user — verified. Linux users see `CCBOX_USER` in the [README caveats](../README.md#caveats) |
| default network `podman` | `bridge` | Docker's default |
| `TZ=Asia/Tbilisi` hardcoded | `ARG TZ=UTC` | Original author's locale. `./ccbox build --build-arg TZ=Europe/Berlin` |
| Atlassian MCP auto-registered | removed | Third-party endpoint not part of this project |
| `gcloud` installed | function kept, not called | Adds ~1 GB and unused here. Add `install_gcloud` to the call list in `install-tools.sh` to enable |
| no egress control | opt-in `CCBOX_FIREWALL=on` | New here. Adapted from Anthropic's devcontainer `init-firewall.sh`; the deviations (IPv6, scoped SSH, scoped DNS, no sudo, fail-closed) are documented in the `ccbox-init-firewall` header. See [Egress firewall](firewall.md) |
| no permission policy | deny rules in managed settings | New here. Credential paths and settings files, applied to every project — see [Security model](security.md) |
| no plugins | safety-net vendored at a pinned commit | New here. Was a per-project install on one volume; now image-level — see [Vendored safety-net plugin](safety-net.md) |

Kept deliberately: the git-from-source build, the SELinux `:z` logic (correct on
Docker too, and already skipped on macOS), and the bash 3.2 `load_flags`
workaround, since macOS still ships bash 3.2.

## Fixed relative to the original

The original dispatches with `case "${1:-run}"` and then `shift`s in the `run)`
branch. `${1:-run}` *expands* to `run` without setting `$1`, so with no
arguments `shift` runs against an empty positional list, returns 1, and
`set -e` exits before `cmd_run` is reached — bare `ccbox`, the documented
default invocation, silently does nothing and exits 1. Here the dispatch
matches `"${1:-}"` so no-args falls through to `*)`, and every branch that
shifts is guaranteed a positional to shift.

## Security review of the ported code

The original repo was reviewed at commit `d23cf7d` before porting: 7 text files,
no binaries, single author, MIT licensed, 15 coherent commits. No obfuscation,
no `eval`, no `curl | bash`, no `/dev/tcp`, no base64 blobs. Every URL is an
official source (github cli apt, kernel.org, Google Cloud apt, Atlassian MCP).
Only two mounts, no socket exposure, no `--privileged`. The generated SSH key
never leaves the volume — only the `.pub` is ever printed.

That review covers a point in time, not future commits. For the review story of
the one third-party component committed into this repo, see
[Vendored safety-net plugin](safety-net.md#reviewing-what-ships).
