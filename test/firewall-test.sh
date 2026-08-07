#!/usr/bin/env bash
#
# firewall-test.sh — acceptance tests for the ccbox egress firewall.
#
#   ./test/firewall-test.sh             hermetic tier: no credentials needed
#   ./test/firewall-test.sh --with-auth also git-over-SSH and a real install,
#                                       which need CCBOX_VOLUME to hold a
#                                       working SSH key
#   ./test/firewall-test.sh --build     rebuild the image first (slow: git is
#                                       compiled from source)
#
# Needs outbound network on the host — the point is to prove that specific
# destinations are reachable and others are not.
#
# The launcher is SOURCED rather than reimplemented, so these assertions run
# against the same run_flags() the real thing uses and cannot drift from it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${CCBOX_IMAGE:-ccbox:latest}"

WITH_AUTH=0
BUILD=0
for arg in "$@"; do
  case "$arg" in
    --with-auth) WITH_AUTH=1 ;;
    --build)     BUILD=1 ;;
    -h|--help)   sed -n '3,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'NOT OK  %s\n' "$*"; }
skip() { printf 'skip %s\n' "$*"; }
note() { printf '\n# %s\n' "$*"; }

# Assert on a command's exit status. `expect_ok`/`expect_fail` keep the intent
# readable at the call site, which matters when half the assertions here are
# "this must NOT work".
expect_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
expect_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
docker info >/dev/null 2>&1  || { echo "the Docker daemon isn't running" >&2; exit 1; }

if [ "$BUILD" = 1 ]; then
  note "building $IMAGE"
  docker build -t "$IMAGE" "$HERE" || exit 1
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "no such image: $IMAGE — run with --build" >&2; exit 1; }

# A scratch workspace and a scratch home volume, so a test run never touches the
# repo you launched from or the credentials in your real ccbox-home.
WORK="$(mktemp -d)"
TEST_VOLUME="ccbox-firewall-test"
cleanup() {
  rm -rf "$WORK"
  [ "$WITH_AUTH" = 1 ] || docker volume rm -f "$TEST_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Build the real docker flags for a given configuration by sourcing the
# launcher. `-it` is dropped: these run unattended, and docker refuses -t
# without a terminal.
ccbox_flags() {
  ( cd "$WORK" && set -e && source "$HERE/ccbox" && load_flags \
    && printf '%s\n' "${FLAGS[@]}" | grep -vx -e '-it' -e '-i' -e '-t' )
}

# Run a shell snippet in a container built with those flags.
ccbox_sh() {
  local flags=()
  local line
  while IFS= read -r line; do flags+=("$line"); done < <(ccbox_flags) || return 1
  [ ${#flags[@]} -gt 0 ] || return 1
  docker run "${flags[@]}" "$IMAGE" bash -lc "$1"
}

# =============================================================================
note "firewall OFF — must be indistinguishable from before this feature existed"
# =============================================================================

unset CCBOX_FIREWALL
export CCBOX_VOLUME="$TEST_VOLUME"

off_flags="$(ccbox_flags | tr '\n' ' ')"
case "$off_flags" in
  *--cap-add*)   bad "firewall off: no --cap-add is added" ;;
  *)             ok  "firewall off: no --cap-add is added" ;;
esac
case "$off_flags" in
  *--user*)      bad "firewall off: no --user is forced" ;;
  *)             ok  "firewall off: no --user is forced" ;;
esac
case "$off_flags" in
  *no-new-privileges*) bad "firewall off: no --security-opt is added" ;;
  *)                   ok  "firewall off: no --security-opt is added" ;;
esac

off_probe="$(ccbox_sh '
  printf "uid=%s home=%s code=%s\n" \
    "$(id -u)" "$HOME" \
    "$(curl -sS -o /dev/null -w "%{http_code}" --max-time 20 https://example.com || echo ERR)"
' 2>/dev/null)"
case "$off_probe" in
  *"uid=1000"*)      ok  "firewall off: runs as uid 1000" ;;
  *)                 bad "firewall off: runs as uid 1000 (got: $off_probe)" ;;
esac
case "$off_probe" in
  *"home=/home/node"*) ok  "firewall off: HOME is /home/node" ;;
  *)                   bad "firewall off: HOME is /home/node (got: $off_probe)" ;;
esac
case "$off_probe" in
  *"code=200"*)      ok  "firewall off: example.com is reachable (egress unrestricted)" ;;
  *)                 bad "firewall off: example.com is reachable (got: $off_probe)" ;;
esac

# =============================================================================
note "launcher guards"
# =============================================================================

expect_fail "CCBOX_NET=host is refused before docker is ever called" \
  env CCBOX_FIREWALL=on CCBOX_NET=host bash -c \
    "cd '$WORK' && source '$HERE/ccbox' && load_flags"

printf 'example.org\n' > "$WORK/allow.txt"
expect_fail "an allowlist inside the workspace is refused" \
  env CCBOX_FIREWALL=on CCBOX_ALLOWLIST_FILE="$WORK/allow.txt" bash -c \
    "cd '$WORK' && source '$HERE/ccbox' && load_flags"

expect_fail "an allowlist that doesn't exist is refused" \
  env CCBOX_FIREWALL=on CCBOX_ALLOWLIST_FILE=/nope/allow.txt bash -c \
    "cd '$WORK' && source '$HERE/ccbox' && load_flags"

# CCBOX_NET=none degrades rather than failing: there is no egress to restrict.
none_flags="$(CCBOX_FIREWALL=on CCBOX_NET=none ccbox_flags 2>/dev/null | tr '\n' ' ')"
case "$none_flags" in
  *--cap-add*) bad "CCBOX_NET=none skips the firewall" ;;
  "")          bad "CCBOX_NET=none skips the firewall (launcher exited)" ;;
  *)           ok  "CCBOX_NET=none skips the firewall" ;;
esac

# =============================================================================
note "firewall ON — refusing to start is the correct outcome for these"
# =============================================================================

expect_fail "a domain that will not resolve stops the container booting" \
  docker run --rm --user 0:0 --cap-add=NET_ADMIN \
    -e CCBOX_FIREWALL=on -e CCBOX_ALLOWED_DOMAINS=does-not-resolve.invalid \
    -e CCBOX_FIREWALL_REFRESH=0 "$IMAGE" bash -lc 'echo SHOULD-NOT-REACH-HERE'

expect_fail "without --cap-add=NET_ADMIN the container refuses to start" \
  docker run --rm --user 0:0 \
    -e CCBOX_FIREWALL=on -e CCBOX_FIREWALL_REFRESH=0 \
    "$IMAGE" bash -lc 'echo SHOULD-NOT-REACH-HERE'

expect_fail "CCBOX_FIREWALL=on as a non-root entrypoint refuses to start" \
  docker run --rm -e CCBOX_FIREWALL=on "$IMAGE" bash -lc 'echo SHOULD-NOT-REACH-HERE'

# =============================================================================
note "firewall ON — the allowlist itself"
# =============================================================================

export CCBOX_FIREWALL=on
export CCBOX_FIREWALL_REFRESH=0     # deterministic: no background re-resolve

# One boot, every runtime assertion. Booting once per assertion would multiply
# a ~15s firewall setup by a dozen for no extra signal.
BATCH='
  curl -sS --max-time 15 -o /dev/null https://example.com          && e4=T || e4=F
  curl -sS -6 --max-time 15 -o /dev/null https://example.com       && e6=T || e6=F
  curl -sS --max-time 20 -o /dev/null https://api.anthropic.com    && an=T || an=F
  curl -sS --max-time 20 -o /dev/null https://registry.npmjs.org   && np=T || np=F
  curl -sS --max-time 20 -o /dev/null https://raw.githubusercontent.com && gh=T || gh=F
  getent hosts example.com >/dev/null                              && dns=T || dns=F
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8 \
      -T git@example.com >/dev/null 2>&1                           && sh22=T || sh22=F
  command -v sudo >/dev/null                                       && sudo=T || sudo=F
  iptables -L -n >/dev/null 2>&1                                   && ipt=T || ipt=F
  ipset list >/dev/null 2>&1                                       && ips=T || ips=F

  echo "EXAMPLE4=$e4 EXAMPLE6=$e6 ANTHROPIC=$an NPM=$np GHRAW=$gh DNS=$dns"
  echo "SSH22=$sh22 SUDO=$sudo IPTABLES=$ipt IPSET=$ips"
  echo "UID=$(id -u) HOME=$HOME"
  grep -E "^(CapEff|CapPrm|CapBnd|NoNewPrivs):" /proc/1/status \
    | sed "s/:[[:space:]]*/=/" | tr "\n" " "
  echo
  echo "LOGLINES=$(grep -c . /var/log/ccbox-firewall.log 2>/dev/null || echo 0)"
  grep -q "api.anthropic.com" /var/log/ccbox-firewall.log && echo "AUDIT=T" || echo "AUDIT=F"

  # Image-level policy: the agent must be able to read what confines it and
  # unable to rewrite it. Same argument as CapBnd above — if uid 1000 can edit
  # the managed settings or the vendored hook, neither is a control.
  seed=/opt/claude-code/plugin-seed
  ms=/etc/claude-code/managed-settings.json
  [ -r "$ms" ]                                    && msr=T   || msr=F
  ( : >>"$ms" ) 2>/dev/null                       && msw=T   || msw=F
  ( : >>"$seed/known_marketplaces.json" ) 2>/dev/null && sdw=T || sdw=F
  ( touch "$seed/marketplaces/x" ) 2>/dev/null    && sdn=T   || sdn=F
  echo "MSREAD=$msr MSWRITE=$msw SEEDWRITE=$sdw SEEDNEW=$sdn"
  echo "SEEDVER=$(node "$seed/marketplaces/cc-marketplace/safety-net/dist/bin/cc-safety-net.js" --version 2>/dev/null)"
'

note "booting the firewall (this takes a few seconds)"
BOOT_LOG="$WORK/boot.log"
OUT="$(ccbox_sh "$BATCH" 2>"$BOOT_LOG")"
BOOT_RC=$?

if [ "$BOOT_RC" -ne 0 ] || [ -z "$OUT" ]; then
  bad "the container boots with the firewall on"
  echo "--- container stderr ---" >&2
  cat "$BOOT_LOG" >&2
  echo "------------------------" >&2
else
  ok "the container boots with the firewall on"

  has() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
  check() { if has "$1"; then ok "$2"; else bad "$2  (got: $(printf '%s' "$OUT" | tr '\n' ' '))"; fi; }

  check "EXAMPLE4=F"  "curl https://example.com fails"
  check "EXAMPLE6=F"  "curl -6 https://example.com fails (IPv6 is covered)"
  check "ANTHROPIC=T" "curl https://api.anthropic.com connects"
  check "NPM=T"       "curl https://registry.npmjs.org connects"
  check "GHRAW=T"     "curl https://raw.githubusercontent.com connects"
  check "DNS=T"       "DNS still resolves"
  check "SSH22=F"     "ssh to a non-GitHub host fails (port 22 is not blanket-allowed)"
  check "SUDO=F"      "sudo is absent"
  check "IPTABLES=F"  "iptables -L fails as node"
  check "IPSET=F"     "ipset list fails as node"
  check "UID=1000"    "runs as uid 1000"
  check "HOME=/home/node" "HOME is /home/node (credentials land in the volume)"

  # The whole control rests on this: if the process that runs Claude Code holds
  # NET_ADMIN, or can regain it through a setuid binary, the firewall is theatre.
  check "CapEff=0000000000000000" "CapEff is zero"
  check "CapPrm=0000000000000000" "CapPrm is zero"
  check "CapBnd=0000000000000000" "CapBnd is zero (NET_ADMIN is not even reachable)"
  check "NoNewPrivs=1"            "NoNewPrivs is set (setuid binaries are inert)"

  check "AUDIT=T"     "the effective allowlist is logged and readable"

  # Image-level policy survives the home volume and outranks everything in it.
  check "MSREAD=T"    "managed settings are readable"
  check "MSWRITE=F"   "managed settings are not writable by node"
  check "SEEDWRITE=F" "the vendored plugin seed is not writable by node"
  check "SEEDNEW=F"   "no new files can be dropped into the plugin seed"
  check "SEEDVER=$(awk '$1=="version:" {print $2}' "$HERE/plugin-seed/PROVENANCE")" \
                      "the seeded plugin is the pinned version"
fi

# The startup log has to reach the operator, not just the log file.
if grep -q "effective allowlist" "$BOOT_LOG" 2>/dev/null; then
  ok "the effective allowlist is printed at startup"
else
  bad "the effective allowlist is printed at startup"
fi
# ...and it must be on stderr, or `ccbox update` would splice it into a version.
ver="$(docker run --rm "$IMAGE" npm view @anthropic-ai/claude-code version 2>/dev/null | tr -d '[:space:]')"
case "$ver" in
  [0-9]*.[0-9]*.[0-9]*) ok "ccbox update still reads a clean version from stdout" ;;
  *)                    bad "ccbox update still reads a clean version from stdout (got '$ver')" ;;
esac

# =============================================================================
note "firewall ON — extending the allowlist from the host"
# =============================================================================

EXTRA="$(CCBOX_ALLOWED_DOMAINS=example.com ccbox_sh \
  'curl -sS --max-time 20 -o /dev/null https://example.com && echo REACHED || echo BLOCKED' 2>/dev/null)"
case "$EXTRA" in
  *REACHED*) ok  "CCBOX_ALLOWED_DOMAINS widens the allowlist" ;;
  *)         bad "CCBOX_ALLOWED_DOMAINS widens the allowlist (got: $EXTRA)" ;;
esac

# =============================================================================
note "Socket Firewall (CCBOX_SOCKET)"
# =============================================================================
#
# Every case here runs in a subshell with its own env prefix. CCBOX_FIREWALL is
# left exported as the section above set it, because the authenticated tier
# below still expects it on.

# Off is off. The assertion that this is genuinely opt-in rather than merely
# documented as such.
sock_off="$( (unset CCBOX_FIREWALL; ccbox_sh 'command -v npm') 2>/dev/null )"
case "$sock_off" in
  */usr/local/bin/npm) ok  "CCBOX_SOCKET unset: npm is the real npm, PATH untouched" ;;
  *)                   bad "CCBOX_SOCKET unset: npm is the real npm (got: $sock_off)" ;;
esac

# A stale image — sfw missing while the flag says filter — must refuse to boot,
# not run the package manager unfiltered. An empty, non-executable file bind
# mounted over the binary reproduces that without rebuilding.
: > "$WORK/not-sfw"
expect_fail "CCBOX_SOCKET=on without sfw in the image refuses to start" \
  docker run --rm -e CCBOX_SOCKET=on \
    -v "$WORK/not-sfw:/usr/local/lib/socket-firewall/sfw:ro" \
    "$IMAGE" bash -lc 'echo SHOULD-NOT-REACH-HERE'

# On, egress firewall off: the common case.
sock_on="$( (unset CCBOX_FIREWALL; CCBOX_SOCKET=on ccbox_sh '
  echo "NPM=$(command -v npm)"
  echo "FAIL=$SFW_FAIL_ACTION"
  d=$(mktemp -d) && cd "$d"
  printf "{\"name\":\"s\",\"version\":\"1.0.0\"}\n" > package.json
  SFW_VERBOSE=true npm install lodash --no-audit --no-fund 2>&1 \
    | grep -qi "Protected by Socket Firewall" && echo SCANNED=T || echo SCANNED=F
  SFW_DISABLE=1 npm --version >/dev/null 2>&1 && echo BYPASS=T || echo BYPASS=F
') 2>/dev/null )"
sock_has() { case "$sock_on" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
sock_check() {
  if sock_has "$1"; then ok "$2"
  else bad "$2  (got: $(printf '%s' "$sock_on" | tr '\n' ' '))"; fi
}
sock_check "NPM=/usr/local/lib/socket-shims/npm" \
  "CCBOX_SOCKET=on: npm resolves to the shim, so the agent's installs are covered too"
sock_check "FAIL=block"  "CCBOX_SOCKET=on: SFW_FAIL_ACTION defaults to block (fails closed)"
sock_check "SCANNED=T"   "CCBOX_SOCKET=on: npm install goes through sfw"
sock_check "BYPASS=T"    "SFW_DISABLE=1 bypasses the shim"

# Both on. This is the regression guard for a silent failure: without
# firewall-api.socket.dev on the allowlist its lookups are REJECTed, sfw's own
# default is to fail OPEN, and npm reports itself protected over packages
# nobody checked. Drop the CCBOX_SOCKET block in ccbox-init-firewall and this
# is the test that catches it.
sock_fw="$( (CCBOX_SOCKET=on CCBOX_FIREWALL=on CCBOX_FIREWALL_REFRESH=0 ccbox_sh '
  curl -sS --max-time 20 -o /dev/null https://firewall-api.socket.dev/ \
    && echo SOCKETAPI=T || echo SOCKETAPI=F
  d=$(mktemp -d) && cd "$d"
  printf "{\"name\":\"s\",\"version\":\"1.0.0\"}\n" > package.json
  SFW_VERBOSE=true npm install lodash --no-audit --no-fund 2>&1 \
    | grep -qi "Protected by Socket Firewall" && echo SCANNED=T || echo SCANNED=F
') 2>/dev/null )"
case "$sock_fw" in
  *SOCKETAPI=T*) ok  "both firewalls on: firewall-api.socket.dev is allowlisted" ;;
  *)             bad "both firewalls on: firewall-api.socket.dev is allowlisted (got: $sock_fw)" ;;
esac
case "$sock_fw" in
  *SCANNED=T*) ok  "both firewalls on: npm install still resolves through sfw" ;;
  *)           bad "both firewalls on: npm install still resolves through sfw (got: $sock_fw)" ;;
esac

# =============================================================================
note "authenticated tier"
# =============================================================================

if [ "$WITH_AUTH" != 1 ]; then
  skip "git ls-remote over SSH        (needs --with-auth and a key in CCBOX_VOLUME)"
  skip "a real package install        (needs --with-auth)"
else
  export CCBOX_VOLUME="${CCBOX_VOLUME_AUTH:-ccbox-home}"
  REPO="${CCBOX_TEST_REPO:-git@github.com:anthropics/claude-code.git}"

  git_out="$(ccbox_sh "
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes git@github.com true 2>&1 | head -1
    git ls-remote '$REPO' HEAD >/dev/null 2>&1 && echo GIT_OK || echo GIT_FAIL
  " 2>/dev/null)"
  case "$git_out" in
    *GIT_OK*) ok  "git ls-remote over SSH to GitHub succeeds" ;;
    *)        bad "git ls-remote over SSH to GitHub succeeds (got: $git_out)" ;;
  esac

  inst_out="$(ccbox_sh '
    set -e
    d=$(mktemp -d) && cd "$d"
    printf "{\"name\":\"fw-test\",\"version\":\"1.0.0\",\"dependencies\":{\"left-pad\":\"1.3.0\"}}\n" > package.json
    if command -v yarn >/dev/null 2>&1 || corepack enable >/dev/null 2>&1; then
      yarn install --no-lockfile >/dev/null 2>&1 && echo YARN_OK || echo YARN_FAIL
    else
      echo YARN_SKIP
    fi
    npm install --no-audit --no-fund >/dev/null 2>&1 && echo NPM_OK || echo NPM_FAIL
  ' 2>/dev/null)"
  case "$inst_out" in
    *YARN_OK*)   ok   "yarn install completes" ;;
    *YARN_SKIP*) skip "yarn install (yarn not available in this image)" ;;
    *)           bad  "yarn install completes (got: $inst_out)" ;;
  esac
  case "$inst_out" in
    *NPM_OK*) ok  "npm install completes" ;;
    *)        bad "npm install completes (got: $inst_out)" ;;
  esac
fi

# =============================================================================
printf '\n%s\n' "-----------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
