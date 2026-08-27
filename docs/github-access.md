# Giving the sandbox read-only GitHub access

Use a **fine-grained** personal access token. Classic tokens can't express
read-only for private repos — the `repo` scope is read *and* write,
all-or-nothing. (For public repos only, a classic token with **zero** scopes is
already read-only.)

## 1. Create the token

github.com → Settings → Developer settings →
[Fine-grained tokens](https://github.com/settings/personal-access-tokens/new)

- **Resource owner**: your account, or the org that owns the repos
- **Repository access**: *Only select repositories* → pick just what the agent needs
- **Expiration**: keep it short; you can always mint another
- **Repository permissions** — set only these:

| Permission | Level | Why |
|---|---|---|
| Metadata | Read-only | mandatory, auto-selected |
| Contents | Read-only | clone and read code |
| Issues | Read-only | *optional* — only if the agent should read issues |
| Pull requests | Read-only | *optional* — only if it should read PRs |

Leave everything else at *No access*. With Contents at read-only the token
physically cannot push, open PRs, or change settings.

If it's an org repo, an owner may need to approve the token before it works.

## 2. Get it into the container

**Ephemeral** — nothing stored, gone when the container exits:

```bash
export GH_TOKEN=github_pat_...          # in your shell, or read from a password manager
CCBOX_ENV=GH_TOKEN ccbox
```

`gh` and `git` both honour `GH_TOKEN` with no extra setup. `CCBOX_ENV` takes
variable *names*, so the secret never lands in your shell history, the command
line, or `ps` output.

**Persistent** — log in once, remembered in the volume:

```bash
ccbox shell
gh auth login --with-token              # paste the token, then Ctrl-D
gh auth setup-git                       # so `git clone/fetch` over HTTPS uses it
exit
```

`gh` stores this under `~/.config/gh` **inside the volume**, never on your host.

## 3. Isolate it

Give the read-only identity its own volume, so it can't reach a fuller-privileged
login you use elsewhere:

```bash
CCBOX_VOLUME=cc-readonly ccbox shell    # set the token up in here
CCBOX_VOLUME=cc-readonly ccbox          # work with it
docker volume rm cc-readonly            # revoke locally, instantly
```

## What this does and doesn't buy you

Read-only genuinely prevents the agent from **changing** anything on GitHub — no
pushes, no force-pushes, no deleted branches, no edited workflows.

It does **not**, on its own, stop private code the token can read from *leaving*.
The container has outbound network by default, so anything readable is
exfiltratable by a determined prompt injection. Scope the token to the minimum
set of repos, and pick one of:

- `CCBOX_FIREWALL=on` — a default-deny egress allowlist, so there is nowhere to
  send it. See [Egress firewall](firewall.md).
- `CCBOX_NET=none` — no network at all, for runs that don't need one.

Also note: a forwarded variable is visible via `docker inspect` on the running
container. That's local-root-equivalent access, so it isn't a meaningful leak on
your own machine, but it's not a secret store either. Revoke tokens at
github.com/settings/tokens when you're done with them.
