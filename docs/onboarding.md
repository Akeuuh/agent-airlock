# Onboarding — Installing the Sandbox on a New Machine

The sandbox is **per-machine**: each person builds their images locally and connects with
**their own** Claude subscription (their credentials stay in *their* volumes, nothing
is shared).

> ℹ️ As long as no **team registry** is configured (`AGENT_SANDBOX_REGISTRY`), images
> are not pushed: everyone runs `make build` after cloning. The launcher tries a
> `podman pull` then falls back to the local cache if the pull fails — that's normal in
> "localhost" mode. See [`build-and-images.md`](build-and-images.md) for the team registry.

## Steps

```sh
# 1. Podman + VM (native Apple provider, no external dependencies)
brew install podman
podman machine init --provider applehv && podman machine start

# 2. Clone + build images (~5 min first time)
git clone <this-repo> ~/agent-airlock
cd ~/agent-airlock
make build

# 3. Alias in shell rc
echo "alias claude='~/agent-airlock/bin/agent-sandbox.sh'" >> ~/.zshrc
echo "alias agent-doctor='~/agent-airlock/bin/agent-doctor.sh'" >> ~/.zshrc
source ~/.zshrc

# 4. Verify
agent-doctor      # should be all green except "auth" (not yet logged in)

# 5. Log in (own account)
cd ~/a-repo-under-home
claude             # subscription login on 1st run → persisted in THEIR agent-home-claude volume
```

## Checklist

- [ ] Working repo **under `$HOME`** (a mount from `/tmp` fails — see
      [`troubleshooting.md`](troubleshooting.md)).
- [ ] `agent-doctor`: internal network, isolation, allowlist → green.
- [ ] Login done once (doctor shows "auth" green afterwards —
      see [`authentication.md`](authentication.md)).
- [ ] For **MCPs**: each person does their own OAuth flow (stored in *their*
      `agent-mcp-auth`). Copy the necessary `servers.d/<name>.env` files (not versioned)
      — see [`add-mcp.md`](add-mcp.md).

## When There's a Team Registry

`make push` once, then teammates only need
`export AGENT_SANDBOX_REGISTRY=<registry>` — the launcher `podman pull`s the shared image
at each launch (skills/plugins always up to date), no more local `make build` needed.
Details: [`build-and-images.md`](build-and-images.md).
