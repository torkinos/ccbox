# Reading Figma designs

The good route needs no credentials inside the container at all.

## Route A: the Figma desktop app's MCP server (recommended)

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

## Add the Figma skills too

The Figma plugin's skills are what tell the agent *how* to use those tools —
`figma-design-to-code` declares itself a mandatory prerequisite to
`get_design_context`. Mount them with `CCBOX_SKILLS`:

```bash
# ~/.zshrc — the glob keeps working after the plugin updates
export CCBOX_SKILLS="$HOME/path/to/your-skills/skills,$(ls -d $HOME/.claude/plugins/cache/claude-plugins-official/figma/*/skills | tail -1)"
```

All 12 skills mount cleanly. They cross-reference each other with relative paths
like `../figma-use/references/gotchas.md`, and those still resolve, because
per-skill mounts land them all as siblings under `~/.claude/skills/` — verified
inside a container.

## Caveats

- **Needs the network.** `CCBOX_NET=none` cuts this off, as it should.
- **The host reachability is a real hole in the sandbox.** Anything in the
  container can talk to *any* service listening on your Mac's loopback, not just
  Figma — databases, dev servers, other local APIs. That's the price of this
  route. `CCBOX_NET=none` closes it for runs that don't need Figma, and
  [`CCBOX_FIREWALL_LOCAL=off`](firewall.md#configuration) closes it while
  keeping internet egress — though closing it also breaks Route A.
- **Works with the [egress firewall](firewall.md) on.** `host.docker.internal`
  stays reachable by default, and the Figma asset hosts are in the baked-in
  allowlist.
- **The plugin path is version-pinned** (e.g. `figma/2.2.87/skills`). The glob
  above handles updates; a hardcoded path silently stops mounting after an
  upgrade.

## Route B: the hosted Figma MCP server

The Figma plugin on your host actually points at `https://mcp.figma.com/mcp`,
which the container can also reach. The problem is auth: it uses OAuth, and the
callback lands on localhost *inside* the container, where your Mac's browser
can't reach it. You'd need to publish the callback port with `CCBOX_PORTS`, and
the port isn't fixed. Route A avoids the whole problem.

## Route C: no MCP at all

Export the frames from Figma to PNG/SVG on the host, and mount the folder:

```bash
CCBOX_DIRS=~/Desktop/design-exports:ro ccbox
```

Claude reads images directly. Zero credentials, zero network, nothing on
loopback — but you re-export by hand whenever the design changes.
