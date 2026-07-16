# Quick Start

Get agent-airlock running in under 5 minutes on macOS.

## Prerequisites

<div class="grid" markdown>

- :material-apple: macOS (Apple Silicon)
- :material-package-variant-closed: [Homebrew](https://brew.sh)
- :simple-podman: Podman

</div>

---

## 1. Install Podman

```sh
brew install podman
podman machine init --provider applehv
podman machine start
```

!!! tip "Why Podman?"
    Open source, rootless, no license restrictions (Docker Desktop is paid beyond 250 employees).
    Plus `--internal` networks make the isolation trivial.

---

## 2. Clone & Build

```sh
git clone https://github.com/Akeuuh/agent-airlock ~/agent-airlock
cd ~/agent-airlock
make build
```

This builds three images: the base, the agent harness, and the sidecars. Takes ~2 minutes the first time.

---

## 3. Add the Alias

Add this to your `~/.zshrc` (or equivalent):

```sh
alias claude='~/agent-airlock/bin/agent-sandbox.sh --profile claude'
alias agent-doctor='~/agent-airlock/bin/agent-doctor.sh'
```

Then `source ~/.zshrc` or open a new terminal.

---

## 4. First Run

```sh
cd ~/code/my-project   # must be under $HOME!
claude
```

On first run, you'll be prompted to log in to your Claude subscription (browser-based OAuth).

!!! warning "Repo location matters"
    Podman only mounts paths under `$HOME` by default. Running from `/tmp` will fail with `statfs: no such file or directory`.

---

## 5. Verify

```sh
agent-doctor
```

Runs 16 checks: VM health, clock sync, images, network isolation, proxy allowlist, MCP tunnel, login persistence.

From inside a running Claude session: `/status`, `/mcp`, `/doctor`.

---

## What's Next?

<div class="grid cards" markdown>

-   :material-cog: **Add an MCP server**

    ---

    Connect Jira, Linear, GitHub… through the sidecar proxy.

    [:octicons-arrow-right-24: Add MCP](add-mcp.md)

-   :material-shield: **Understand the sandbox**

    ---

    How isolation works, threat model, design decisions.

    [:octicons-arrow-right-24: Architecture](architecture.md)

-   :material-account-multiple: **Onboard a teammate**

    ---

    Step-by-step for a new machine.

    [:octicons-arrow-right-24: Onboarding](onboarding.md)

-   :material-puzzle: **Switch agent**

    ---

    Use pi or opencode instead of Claude Code.

    [:octicons-arrow-right-24: Profiles](profiles.md)

</div>

---

!!! question "Something went wrong?"
    Check the [:fontawesome-solid-lifebuoy: troubleshooting guide](troubleshooting.md).
