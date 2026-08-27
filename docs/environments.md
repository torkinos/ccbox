# Multiple environments

Three independent axes, all driven by environment variables. No code changes
needed.

**Separate logins** — different Claude/gh accounts, or a throwaway identity for
testing untrusted code. Each volume is a completely separate home directory:

```bash
CCBOX_VOLUME=cc-work     ccbox auth    # sign in as work
CCBOX_VOLUME=cc-personal ccbox auth    # sign in as personal
CCBOX_VOLUME=cc-work     ccbox         # uses the work login
```

Verified: writing to one volume leaves the other untouched. Deleting a volume
(`docker volume rm cc-work`) logs that identity out and destroys its SSH key,
without affecting the others.

**Separate toolchains** — copy the ccbox repo directory, edit its
`install-tools.sh`, and build under a different tag. `ccbox build` respects
`CCBOX_IMAGE`:

```bash
cp -R ccbox ccbox-embedded
# edit ccbox-embedded/install-tools.sh — add install_rust, install_probe-rs, ...
cd ccbox-embedded && CCBOX_IMAGE=ccbox:embedded ./ccbox build
CCBOX_IMAGE=ccbox:embedded ccbox          # run with that toolchain
```

**Concurrent sessions** — several containers can run at once, including on the
same volume. Verified: two containers sharing `ccbox-home` both start, and each
sees the other's writes live. That is the same situation as running `claude` in
two terminals on your host, and behaves the same way: fine in practice, but two
sessions are writing one `~/.claude`, so use separate volumes if you want their
histories and settings genuinely independent.

Mixing axes works as expected:

```bash
CCBOX_IMAGE=ccbox:embedded CCBOX_VOLUME=cc-work CCBOX_PORTS=3000 ccbox
```

## Wrappers

Typing the variables gets old. Either alias them:

```bash
alias ccwork='CCBOX_VOLUME=cc-work ccbox'
alias ccemb='CCBOX_IMAGE=ccbox:embedded CCBOX_VOLUME=cc-embedded ccbox'
```

or drop a two-line launcher on your PATH per environment:

```bash
#!/usr/bin/env bash
# ~/.local/bin/ccwork
exec env CCBOX_VOLUME=cc-work ~/path/to/ccbox/ccbox "$@"
```

## Joining your app's Docker network

To let the agent reach your app's database and services by hostname, join your
compose network:

```bash
docker compose up -d
docker network ls                      # find it, e.g. myapp_default
CCBOX_NET=myapp_default ccbox
```
