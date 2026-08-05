#!/usr/bin/env bash
#
# vendor-safety-net.sh — vendor CC Safety Net into plugin-seed/ at a pinned commit.
#
#   ./tools/vendor-safety-net.sh <tag> <sha>   re-vendor at that tag, pinned to that commit
#   ./tools/vendor-safety-net.sh --verify      prove the committed tree matches PROVENANCE
#
# Why a script instead of a bare `git clone` in the Dockerfile: the plugin ships a
# pre-built, minified dist/ and no build step, so `git diff` on a version bump is
# 350KB of unreviewable bundle. The real review is the upstream src/ diff between
# tags on GitHub. This script is what makes that review *mean* something — it
# records the commit, and --verify re-fetches that commit and proves the bytes we
# shipped are the bytes at the SHA you reviewed.
#
# Bash 3.2 compatible (macOS ships 3.2) — same constraint as ./ccbox.
#
set -euo pipefail

REPO_URL="https://github.com/kenryu42/cc-safety-net.git"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="$ROOT/plugin-seed"
DEST="$SEED/marketplaces/cc-marketplace/safety-net"
PROVENANCE="$SEED/PROVENANCE"

# The runtime file set. dist/bin/cc-safety-net.js is a self-contained bundle —
# it imports only node: builtins — so dist/index.js, dist/pi/index.js and every
# .d.ts are dead weight here, as are src/, tests/ and a 130KB screenshot.
# Upstream's own .claude-plugin/marketplace.json is deliberately excluded: it
# declares a second marketplace named safety-net-dev that we don't want seen.
VENDOR_FILES="
.claude-plugin/plugin.json
hooks/hooks.json
dist/bin/cc-safety-net.js
skills/cc-safety-net/SKILL.md
LICENSE
"

SCRATCH=""
trap 'rm -rf "${SCRATCH:-}"' EXIT

die() { printf 'vendor-safety-net: %s\n' "$*" >&2; exit 1; }

# Clone <sha> into SCRATCH. Clones the tag shallowly and then checks the resolved
# commit, so a moved tag fails loudly instead of silently shipping different bytes.
fetch() {
  local tag="$1" sha="$2" got
  SCRATCH="$(mktemp -d)"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" \
      "$REPO_URL" "$SCRATCH/src" \
    || die "clone of $tag failed"
  got="$(git -C "$SCRATCH/src" rev-parse HEAD)"
  [ "$got" = "$sha" ] \
    || die "tag $tag resolves to $got, expected $sha — the tag moved, or the SHA is wrong"
}

# Prove the vendored bundle still runs standalone and still blocks. A future
# release that splits the bundle would break the pruned file set above, and this
# is what catches it — a version check alone would not.
smoke_test() {
  local root="$1" ver out
  ver="$(node "$root/dist/bin/cc-safety-net.js" --version 2>&1)" \
    || die "vendored bundle does not run — the pruned file set is probably incomplete"
  out="$(node -e 'process.stdout.write(JSON.stringify({
        session_id:"vendor-smoke-test", transcript_path:"/dev/null", cwd:process.cwd(),
        hook_event_name:"PreToolUse", tool_name:"Bash",
        tool_input:{command:"find . -name \"*.nope\" -delete"}}))' \
    | CLAUDE_PLUGIN_ROOT="$root" node "$root/dist/bin/cc-safety-net.js" hook --claude-code)"
  case "$out" in
    *"BLOCKED by CC Safety Net"*) : ;;
    *) die "hook did not block a destructive command; got: ${out:-<empty>}" ;;
  esac
  printf '%s\n' "$ver"
}

cmd_vendor() {
  local tag="$1" sha="$2" src ver f
  command -v node >/dev/null 2>&1 || die "node is required for the smoke test"

  fetch "$tag" "$sha"; src="$SCRATCH/src"

  rm -rf "$DEST"
  for f in $VENDOR_FILES; do
    [ -f "$src/$f" ] || die "$f is missing at $tag — the upstream layout changed"
    mkdir -p "$DEST/$(dirname "$f")"
    cp "$src/$f" "$DEST/$f"
  done

  ver="$(smoke_test "$DEST")"
  [ "$ver" = "${tag#v}" ] \
    || die "plugin.json/bundle report $ver but the tag is $tag"

  cat >"$PROVENANCE" <<EOF
plugin:  safety-net
source:  $REPO_URL
tag:     $tag
commit:  $sha
version: $ver

Vendored by tools/vendor-safety-net.sh. Only the runtime file set is kept:
$(printf '%s' "$VENDOR_FILES" | sed '/^$/d;s/^/  /')

Run 'tools/vendor-safety-net.sh --verify' to prove these files match the commit.
EOF

  printf 'vendored safety-net %s (%s), %s\n' "$tag" "$sha" "$(du -sh "$DEST" | cut -f1)"
}

cmd_verify() {
  local tag sha src f rc=0
  [ -f "$PROVENANCE" ] || die "no $PROVENANCE — run the vendor mode first"
  tag="$(awk '$1=="tag:"    {print $2}' "$PROVENANCE")"
  sha="$(awk '$1=="commit:" {print $2}' "$PROVENANCE")"
  [ -n "$tag" ] && [ -n "$sha" ] || die "could not read tag/commit from $PROVENANCE"

  fetch "$tag" "$sha"; src="$SCRATCH/src"

  for f in $VENDOR_FILES; do
    if ! cmp -s "$src/$f" "$DEST/$f"; then
      printf 'DIFFERS: %s\n' "$f" >&2
      rc=1
    fi
  done
  # Anything extra in the vendored tree is unreviewed by definition.
  for f in $(cd "$DEST" && find . -type f | sed 's|^\./||' | sort); do
    case "
$VENDOR_FILES" in
      *"
$f
"*) : ;;
      *) printf 'UNEXPECTED: %s\n' "$f" >&2; rc=1 ;;
    esac
  done

  [ "$rc" -eq 0 ] || die "vendored tree does not match $tag ($sha)"
  smoke_test "$DEST" >/dev/null
  printf 'verified: plugin-seed matches %s (%s)\n' "$tag" "$sha"
}

case "${1:-}" in
  --verify) cmd_verify ;;
  -h|--help|"") sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    [ $# -eq 2 ] || die "usage: $0 <tag> <sha>  |  $0 --verify"
    cmd_vendor "$1" "$2"
    ;;
esac
