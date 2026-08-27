# Egress firewall

Off by default. Turn it on per run, or export it:

```bash
CCBOX_FIREWALL=on ccbox
```

With it on, the container can reach the allowlist and nothing else. Everything
else is rejected immediately — no proxy to negotiate with, no timeout to wait
out. That closes the exfiltration gap described in
[read-only GitHub access](github-access.md): a prompt injection can still *read*
your GitHub token and your Claude Code credentials, but it has nowhere to send
them.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CCBOX_FIREWALL` | — | `on` enables the default-deny egress allowlist |
| `CCBOX_ALLOWED_DOMAINS` | — | Extra host names to allow, comma-separated |
| `CCBOX_ALLOWLIST_FILE` | — | Host file of extra host names, one per line. Must not be inside the directory you launch from |
| `CCBOX_ALLOWED_PORTS` | `80,443` | TCP ports allowed to allowed hosts |
| `CCBOX_FIREWALL_LOCAL` | `subnet` | `subnet` \| `gateway` \| `off` — how much of the container's own Docker network stays reachable |
| `CCBOX_FIREWALL_REFRESH` | `1800` | Re-resolve interval in seconds; `0` disables |
| `CCBOX_DNS` | — | Pin the upstream resolver. Only needed if a user-defined `CCBOX_NET` can't reach DNS otherwise |

## How it holds

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

## What's allowed

Baked into the image (`ccbox-init-firewall`):

| Group | Hosts |
|---|---|
| Claude Code | `api.anthropic.com`, `statsig.anthropic.com`, `statsig.com`, `sentry.io`, `claude.ai` |
| GitHub | `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, `ssh.github.com`, plus every IPv4 range from `api.github.com/meta` |
| Packages | `registry.npmjs.org`, `registry.yarnpkg.com`, `repo.yarnpkg.com` |
| Figma | `www.figma.com`, `api.figma.com`, and the S3 hosts that serve image assets |
| Socket | `firewall-api.socket.dev`, `api.socket.dev` — **only** with `CCBOX_SOCKET=on`; see [npm supply-chain firewall](socket-firewall.md) |

Plus, structurally: loopback, DNS to the resolvers in `/etc/resolv.conf`, the
container's own Docker network, and `host.docker.internal`. Those last two are
what keep `CCBOX_NET=<project>_default` and Figma Route A working — they are
host-local, not internet egress, and `CCBOX_FIREWALL_LOCAL=gateway` or `off`
narrows them.

Only TCP 80 and 443 are allowed to allowlisted hosts (`CCBOX_ALLOWED_PORTS`
widens that), and **port 22 only to GitHub's `git` ranges** — SSH to anywhere
else is blocked, because a blanket port 22 is an exfiltration channel with extra
steps.

## Extending it

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

## It fails closed

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

## Notes

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

## Testing it

```bash
./test/firewall-test.sh              # no credentials needed
./test/firewall-test.sh --with-auth  # also git-over-SSH and a real install
```
