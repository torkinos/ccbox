#!/usr/bin/env bash
#
# install-tools.sh — the single place to extend the toolset.
#
# To add a tool: write an install_<name> function, then add it to the call list
# at the bottom. Each function runs as root during the image build. Keep them
# self-contained so they're easy to reason about.
#
# Originally adapted from ralozkolya/ccbox (MIT) — see docs/origins.md.
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt_update_once() {
  if [ -z "${_APT_UPDATED:-}" ]; then
    apt-get update -y
    _APT_UPDATED=1
  fi
}

# ----------------------------------------------------------------------------
# Base tools — ssh and the small CLIs Claude leans on constantly. git is built
# separately (see install_git) because the distro version is too old.
# ----------------------------------------------------------------------------
install_base() {
  apt_update_once
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    openssh-client \
    jq \
    ripgrep \
    less \
    netcat-openbsd \
    procps \
    tzdata

  # Point the clock at the requested zone now (TZ is exported in the Dockerfile)
  # so every later build step runs on local time.
  local tz="${TZ:-UTC}"
  ln -snf "/usr/share/zoneinfo/${tz}" /etc/localtime
  echo "$tz" > /etc/timezone
}

# ----------------------------------------------------------------------------
# git — built from source. Debian bookworm ships 2.39, which predates relative
# worktree links (git 2.48+, `worktree.useRelativePaths`). Claude Code creates
# worktrees, and without relative links a worktree made inside the container
# records absolute container paths and breaks on the host.
#
# This is the slow step (~2-4 min). It is layer-cached, so you pay it once —
# `./ccbox update` does not re-run it.
#
# Build deps are purged afterwards; the runtime shared libs the binary links
# against are installed explicitly so the purge can't autoremove them.
# ----------------------------------------------------------------------------
install_git() {
  apt_update_once
  local ver="2.51.0"
  local build_deps="build-essential libssl-dev libcurl4-openssl-dev libexpat1-dev zlib1g-dev libpcre2-dev"
  local make_flags="USE_LIBPCRE=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease"

  apt-get install -y --no-install-recommends $build_deps
  apt-get install -y --no-install-recommends libcurl4 libexpat1 zlib1g libpcre2-8-0

  local src; src="$(mktemp -d)"
  # PORT: upstream pipes the tarball straight into tar. Downloading it first
  # lets us record what we got; see the note in README about verification.
  curl -fsSL -o "$src/git.tar.gz" \
    "https://mirrors.edge.kernel.org/pub/software/scm/git/git-${ver}.tar.gz"
  echo "git-${ver}.tar.gz sha256: $(sha256sum "$src/git.tar.gz" | cut -d' ' -f1)"
  tar -xzf "$src/git.tar.gz" -C "$src"

  make -C "$src/git-${ver}" -j"$(nproc)" prefix=/usr/local $make_flags all
  make -C "$src/git-${ver}" prefix=/usr/local $make_flags install
  rm -rf "$src"

  # Relative worktree links are the whole point of the newer git, so make it the
  # container-wide default. System scope keeps the preference out of the home
  # volume and out of every repo, so nothing leaks to the host side of the mount.
  install -d /usr/local/etc
  git config --system worktree.useRelativePaths true

  apt-get purge -y $build_deps
  apt-get autoremove -y --purge
  hash -r
  git --version
}

# ----------------------------------------------------------------------------
# gh — GitHub CLI (official apt repo, signed).
# ----------------------------------------------------------------------------
install_gh() {
  apt_update_once
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -y
  apt-get install -y --no-install-recommends gh
}

# ----------------------------------------------------------------------------
# Egress firewall tooling, used only by ccbox-init-firewall in the entrypoint:
# iptables/ip6tables to filter, ipset for the allowlist, dig to resolve it,
# aggregate to collapse GitHub's CIDR list, ip to read the container's own
# subnet. The `node` user has no capabilities, so none of it is usable from
# inside the sandbox — installing them costs nothing but disk.
#
# jq, curl and ca-certificates come from install_base, and setpriv (the
# privilege drop) is already in the base image's util-linux, so none are listed.
#
# Called LAST: install_git ends with `apt-get autoremove -y --purge`, and
# ordering after it keeps these packages clear of that sweep.
# ----------------------------------------------------------------------------
install_firewall() {
  apt_update_once
  apt-get install -y --no-install-recommends \
    iptables \
    ipset \
    dnsutils \
    aggregate \
    iproute2
}

# ----------------------------------------------------------------------------
# Socket Firewall — npm supply-chain filtering, used only when the launcher
# passes CCBOX_SOCKET=on. `sfw` proxies a package manager's fetches and asks
# Socket about each package before it lands, which catches malicious versions
# ahead of the registry's own takedowns.
#
# The FREE build: no Socket seat, no API token, same filtering. Enterprise
# (org policy, reporting, shared cache) lives in SocketDev/firewall-release
# with the asset prefix `sfw-` instead of `sfw-free-`, and wants
# SOCKET_API_TOKEN at run time — pass it with CCBOX_ENV, never bake it in.
#
# Version-pinned rather than :latest for the same reason the plugin seed is
# pinned to a commit: an image should not change what it enforces underneath
# you. The sha256 is echoed the way install_git records its tarball.
#
# The shims that put this in front of npm are fanned out in the Dockerfile —
# they need a COPY, which this file (it runs from /tmp alone) cannot do.
# ----------------------------------------------------------------------------
install_socket_firewall() {
  local ver="v1.15.0" arch asset
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    arm64) asset="sfw-free-linux-arm64" ;;
    amd64) asset="sfw-free-linux-x86_64" ;;
    *) echo "socket firewall: no published asset for $arch" >&2; return 1 ;;
  esac

  install -d /usr/local/lib/socket-firewall
  curl -fsSL -o /usr/local/lib/socket-firewall/sfw \
    "https://github.com/SocketDev/sfw-free/releases/download/${ver}/${asset}"
  echo "${asset} ${ver} sha256: $(sha256sum /usr/local/lib/socket-firewall/sfw | cut -d' ' -f1)"
  chmod 0755 /usr/local/lib/socket-firewall/sfw

  # Smoke test: a truncated download or a wrong-arch asset fails the build here
  # rather than at the first `npm install` inside somebody's container.
  /usr/local/lib/socket-firewall/sfw --version
}

# ----------------------------------------------------------------------------
# gcloud — Google Cloud CLI (official apt repo, signed).
# PORT: upstream enables this. Left available but NOT called below — it adds
# ~1 GB and isn't used in this project. Add `install_gcloud` to the list to
# enable, then `./ccbox build`.
# ----------------------------------------------------------------------------
install_gcloud() {
  apt_update_once
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
  echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update -y
  apt-get install -y --no-install-recommends google-cloud-cli
}

# ----------------------------------------------------------------------------
# Call list — add new tools here.
# ----------------------------------------------------------------------------
install_base
install_git
install_gh
install_firewall
install_socket_firewall

# Cleanup to keep the image small.
apt-get clean
rm -rf /var/lib/apt/lists/*
