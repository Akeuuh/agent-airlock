# Build, Images & Registry

## Images

| Image | Source | Content |
|---|---|---|
| `agent-base` | `containers/base/` | node + mise + socat + git + `agent` user (shared base, **no harness**) |
| `agent-<profile>` | `containers/harness/` + `profiles/<profile>/` | base + harness binary (`install.sh`) + config bundle |
| `mcp-remote` / `mcp-proxy` | `containers/mcp-remote/` | Node.js MCP proxy + automatic OAuth (PKCE) |
| `egress-proxy` | official squid image retagged | proxy, config mounted at runtime |

Example: the `claude` profile produces `agent-claude` on top of `agent-base`.

## Make Commands

```sh
make build          # base + harness (PROFILE=claude) + mcp + egress
make build-base     # shared base image only
make build-harness PROFILE=claude   # harness image (after config/skills/commands/mcp.json changes)
make build-mcp      # MCP sidecar image only (used by both mcp-remote AND mcp-proxy)
make build-egress   # pull + tag squid
make clean          # stop/remove sidecars + network
```

Variables:

```sh
make build REGISTRY=registry.example.com TAG=2025-07
```

Defaults: `REGISTRY=localhost` and `TAG=latest`.

---

## When to Rebuild?

See also the ["where does my change go" table](README.md#-where-does-my-change-go-and-how-do-i-apply-it).

- **Rebuild a harness**: any change to `profiles/<profile>/` (`install.sh`, `config/`:
  mcp.json, skills, commands, plugins) or `containers/harness/Containerfile`. Config is
  **copied into the image**, so a simple restart is not enough:
  `make build-harness PROFILE=<profile>`.
- **Rebuild the base**: changes to `containers/base/` (`Containerfile`, `entrypoint.sh`,
  git-hooks-template) → `make build-base` then rebuild dependent harnesses.
- **Rebuild the MCP sidecar**: changes to `Containerfile`/`entrypoint.sh`/`proxy.js`.
  `servers.d/*.env` and `servers.d-proxy/*.env` are bind-mounted → no rebuild, just
  `podman rm -f mcp-remote mcp-proxy`.
- **No `egress` rebuild**: the runtime `squid.conf` is generated (base + profile allowlist)
  and bind-mounted → `podman rm -f egress-proxy`.

The launcher **auto-builds** the base image and harness image if they are missing
("not yet built, building…" message). After a manual rebuild, simply relaunch the
launcher. Verify with `agent-doctor`.

---

## Team Registry (To Set Up)

Currently images stay at `localhost`: everyone runs `make build`. To distribute a shared
image (up-to-date skills/plugins for all, no local build):

```sh
# 1. Build tagging for the team registry
make build REGISTRY=registry.example.com

# 2. Push
make push REGISTRY=registry.example.com

# 3. Team side: point the launcher to this registry
export AGENT_SANDBOX_REGISTRY=registry.example.com
claude        # podman pull the shared image at each launch
```

The launcher reads `AGENT_SANDBOX_REGISTRY` (default `localhost`). If the harness image
is absent locally, it **builds** it; with a team registry set up, adapt the flow to
`pull` the shared image.

> ⚠️ The registry domain must be reachable by the host (not by the harness) — the launcher
> pulls outside the sandbox. No need to add it to the egress allowlist.

---

## Post-Build Verification

```sh
podman images | grep -E 'agent-base|agent-claude|mcp-remote|mcp-proxy|egress-proxy'
agent-doctor        # images present + whole chain
```
