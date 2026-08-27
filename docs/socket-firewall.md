# npm supply-chain firewall

Off by default. Turn it on per run, or export it:

```bash
CCBOX_SOCKET=on ccbox
```

With it on, `npm`, `npx` and `yarn` run through [Socket
Firewall](https://docs.socket.dev/) (`sfw`), which proxies the fetch and checks
each package against Socket before it lands. It catches malicious versions ahead
of the registry's own takedowns, which is the window that actually matters —
recent npm supply-chain attacks were live for hours before removal.

This is a different axis from the [egress firewall](firewall.md). That one
controls *where the container may talk*; this one controls *what may be
installed from a place it is already allowed to talk to*. They compose, and
neither substitutes for the other.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `CCBOX_SOCKET` | — | `on` routes `npm`/`npx`/`yarn` through Socket Firewall |
| `SFW_FAIL_ACTION` | `block` | `block` \| `allow` — what happens when Socket is unreachable. Forward with `CCBOX_ENV` |
| `SFW_DISABLE` | — | Set on a single command to bypass the shim |
| `SOCKET_API_TOKEN` | — | Enterprise seats only; the image ships the free build. Forward with `CCBOX_ENV` |

## It's a PATH shim, not an alias

Socket's own docs suggest `alias npm="sfw npm"`. That reaches a human at a
prompt and nothing else. Claude Code snapshots the shell at session start and the
snapshot opens with:

```sh
unalias -a 2>/dev/null || true
...
shopt -u expand_aliases
```

Every Bash tool call runs against that snapshot, so an alias-based setup leaves
exactly the traffic most worth filtering — packages the agent installs on its own
— unfiltered. `ccbox-entrypoint` prepends `/usr/local/lib/socket-shims` to `PATH`
instead. The shims are real executables, so they apply to agent commands, npm
lifecycle scripts, husky hooks and interactive shells alike.

They are root-owned and live in the image, never on a volume — the same argument
as the firewall scripts. Prepending `PATH` in the entrypoint rather than as a
Dockerfile `ENV` is what keeps the feature opt-in.

## It fails closed

`sfw`'s own default is to fail **open**: on a failed lookup it reports "not
blocked", and npm cheerfully prints `Protected by Socket Firewall` over a package
nobody checked. ccbox sets `SFW_FAIL_ACTION=block` so an unreachable Socket API
stops the install instead. Override it for a genuine Socket outage:

```bash
SFW_FAIL_ACTION=allow CCBOX_ENV=SFW_FAIL_ACTION CCBOX_SOCKET=on ccbox
```

With `CCBOX_FIREWALL=on` as well, `firewall-api.socket.dev` and `api.socket.dev`
are added to the allowlist automatically, and the boot self-test asserts the
first is reachable. Without that the allowlist would REJECT sfw's lookups and —
before `SFW_FAIL_ACTION=block` — every package would have passed unscanned while
still reporting itself protected.

## What it is not

**A supply-chain guard, not a containment boundary.** The shims cannot be edited
from inside, but anything running as `node` can call `/usr/local/bin/npm`
directly or set `SFW_DISABLE=1` — and so can the agent. That gap cannot be
closed here: sfw's own proxy needs `registry.npmjs.org` egress from the same uid,
so no allowlist can tell sfw's traffic from a bypass. It stops malicious
packages; it does not stop a deliberately evasive agent.

`SFW_DISABLE=1` is also the intended escape hatch when the proxy is in the way:

```bash
SFW_DISABLE=1 npm install       # bypass once
/usr/local/bin/npm install      # same thing, via the absolute path
```

## Notes

- **Free build.** No Socket seat or token needed. Enterprise (org policy,
  reporting, shared cache) means swapping the release repo in
  `install_socket_firewall` and forwarding a token:
  `CCBOX_ENV=SOCKET_API_TOKEN`. It accepts `SOCKET_API_TOKEN` or
  `SOCKET_API_KEY`; Socket's docs name one and their rollout notes the other.
- **Version-pinned** in `install-tools.sh`, for the same reason the plugin seed is
  pinned to a commit: an image should not change what it enforces underneath you.
  The layer sits above `CC_VERSION`, so `ccbox update` never re-downloads it.
- **~340 ms per wrapped invocation**, against ~50 ms for a bare `npm --version`.
  A nested `npm run` reuses the parent's proxy rather than starting a second, so
  the cost is once per tree, not once per script.
- **Non-registry hosts pass through.** Expo, React Native and Gradle download
  hosts are unaffected.
