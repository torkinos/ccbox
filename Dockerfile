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
USER node

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/ccbox-entrypoint"]
CMD ["claude"]
