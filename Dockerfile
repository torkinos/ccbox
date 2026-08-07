# Claude Code in a Docker container.
#
# Docker port of ccbox by Nikoloz Razmadze (MIT licensed):
#   https://github.com/ralozkolya/ccbox
# The architecture — single bind mount, credentials in a named volume, tools
# baked into the image, version-pinned Claude Code layer — is theirs.
# Deviations from upstream are marked "PORT:".
#
# Build:  ./ccbox build
FROM node:24-bookworm-slim

# PORT: upstream hardcodes the author's timezone (Asia/Tbilisi). Parameterised
# here. Set at build time: ./ccbox build --build-arg TZ=Europe/Berlin
ARG TZ=UTC
ENV TZ=${TZ}

# --- base tools (git, ssh, gh, ...) ---------------------------------------
# install-tools.sh is the single seam for extending the toolset: add an
# install_<name> function there and call it in the list at the bottom.
COPY install-tools.sh /tmp/install-tools.sh
RUN chmod +x /tmp/install-tools.sh && /tmp/install-tools.sh && rm /tmp/install-tools.sh

# --- vendored, version-pinned plugin seed ---------------------------------
# The CC Safety Net PreToolUse hook, baked into the image instead of installed
# per-project into ~/.claude/plugins. That directory lives on the home volume,
# so a per-project install is invisible to every other project and to every
# fresh volume — the same reason skills can't be baked (see README "What
# doesn't work"). CLAUDE_CODE_PLUGIN_SEED_DIR is Claude Code's supported way
# out: a read-only seed it reads at startup, from a path no volume shadows.
# /opt is image storage and root-owned, so the `node` user cannot rewrite the
# hook that constrains it — the same argument as /etc/claude-code below.
#
# Pinned by COMMIT, not by tag: v1.0.6 is a lightweight tag and tags can be
# moved. plugin-seed/PROVENANCE records the commit; regenerate the tree with
# tools/vendor-safety-net.sh and prove it still matches with its --verify mode.
#
# Deliberately ABOVE the CC_VERSION layer so `ccbox update` never rebuilds it.
COPY plugin-seed /opt/claude-code/plugin-seed
RUN chmod -R a-w,a+rX /opt/claude-code/plugin-seed
ENV CLAUDE_CODE_PLUGIN_SEED_DIR=/opt/claude-code/plugin-seed

# --- Socket Firewall ------------------------------------------------------
# Opt-in npm supply-chain filtering, off unless the launcher passes
# CCBOX_SOCKET=on. The binary comes from install-tools.sh; this block fans one
# shim out over the package managers that actually exist in the image.
#
# The `command -v` guard is load-bearing, not tidiness: a pnpm shim with no
# pnpm behind it makes `command -v pnpm` succeed, and both Expo and the RN CLI
# probe that way to choose a package manager. node:24-bookworm-slim has npm,
# npx, yarn and yarnpkg; pnpm and bun it does not.
#
# Root-owned and inside the image, never on a volume, so `node` cannot rewrite
# the thing that filters it — the same argument as the firewall scripts below.
#
# PATH is deliberately NOT set here. The entrypoint prepends the shim dir when
# CCBOX_SOCKET=on, which is what makes this opt-in; setting it as an image ENV
# would also wrap the build's own `npm install -g` two steps down, which would
# need socket.dev reachable at build time for no benefit.
#
# Deliberately ABOVE the CC_VERSION layer so `ccbox update` never re-downloads
# the ~130 MB binary — same reason as the plugin seed.
COPY socket-shim /usr/local/lib/socket-shim
RUN set -eux; \
    chmod 0755 /usr/local/lib/socket-shim; \
    mkdir -p /usr/local/lib/socket-shims; \
    for c in npm npx yarn yarnpkg pnpm bun; do \
      command -v "$c" >/dev/null 2>&1 || continue; \
      cp /usr/local/lib/socket-shim "/usr/local/lib/socket-shims/$c"; \
      echo "socket-firewall: wrapping $c"; \
    done; \
    rm /usr/local/lib/socket-shim

# --- Claude Code ----------------------------------------------------------
# Deliberately the last expensive step, and keyed on CC_VERSION so `ccbox
# update` rebuilds this layer alone — everything above it, including git built
# from source, stays cached.
#
# Claude Code cannot self-update in here: npm's global dir is root-owned and the
# container runs as `node`, so its in-app updater fails with "no_permissions".
# That is intentional — the image is the version pin. Use `./ccbox update`.
ARG CC_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CC_VERSION}

# Fail the build if the seeded marketplace doesn't parse against THIS Claude
# Code version. Offline, needs no login, sub-second. It sits below the CC layer
# on purpose: it checks the pair, so a version bump re-runs it.
RUN claude plugin validate /opt/claude-code/plugin-seed/marketplaces/cc-marketplace

# Managed (policy) settings live at /etc/claude-code, OUTSIDE the home volume,
# so they survive the mount and apply to every run including a fresh volume.
# Claude Code reads this at the highest precedence in the settings hierarchy:
# nothing in ~/.claude or a project's .claude/ can override it.
COPY managed-settings.json /etc/claude-code/managed-settings.json

# --- egress firewall ------------------------------------------------------
# Opt-in, off unless the launcher passes CCBOX_FIREWALL=on. Both scripts live in
# root-owned /usr/local/bin — inside the image, never on a volume — so the
# `node` user cannot rewrite the thing that confines it. /etc/ccbox is the
# mount point for an optional host-supplied allowlist; it is deliberately NOT
# under /workspace, /home/node or /mnt, all of which the agent can write.
COPY ccbox-entrypoint ccbox-init-firewall /usr/local/bin/
RUN chmod 0755 /usr/local/bin/ccbox-entrypoint /usr/local/bin/ccbox-init-firewall \
 && mkdir -p /etc/ccbox

# --- non-root runtime user ------------------------------------------------
# The base image's built-in `node` user (uid 1000, home /home/node). Never root:
# Claude Code refuses --dangerously-skip-permissions as root, and root would
# leave root-owned files in your bind-mounted repo.
#
# This stays even with the firewall on. In that mode the launcher overrides it
# with `--user 0:0` so the entrypoint can install iptables rules, and the
# entrypoint immediately drops back to uid 1000 with setpriv — CapEff and CapBnd
# both zero. With the firewall off nothing is overridden, the entrypoint sees it
# is not root, and execs straight through.
#
# Registering the plugin seed writes ~/.claude/plugins/known_marketplaces.json
# at startup, so ~/.claude has to be writable by uid 1000. Docker creates a
# missing bind-mount target as root:root, and CCBOX_SKILLS mounts land at
# ~/.claude/skills/<name> — on an EMPTY volume that would otherwise leave
# ~/.claude itself root-owned and the seed silently unregistered. Image content
# under /home/node only applies when the volume is empty, which is exactly the
# case this covers; established volumes keep what they already have.
RUN mkdir -p /home/node/.claude/skills /home/node/.claude/plugins \
 && chown -R node:node /home/node/.claude

USER node

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/ccbox-entrypoint"]
CMD ["claude"]
