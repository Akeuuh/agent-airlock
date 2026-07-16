# Documentation — agent-airlock

Guides for **using, extending, and contributing** to the sandbox.

## Understand
- [`architecture.md`](architecture.md) — threat model, diagrams, design decisions.
- [`profiles.md`](profiles.md) — multi-harness support: profiles, resolution, adding a harness.
- [`network.md`](network.md) — internal network, DNS, static IPs, MCP socat tunnel.
- [`web-access.md`](web-access.md) — WebSearch / WebFetch / MCP: what Claude can fetch.
- [`authentication.md`](authentication.md) — subscription login, clock resync, volumes.
- The [README](../README.md) — overview + installation.

## Extend
- [`profiles.md`](profiles.md) — **adding a harness** (pi, opencode…) = creating a profile.
- [`add-mcp.md`](add-mcp.md) — connecting an MCP server (via container B).
- [`add-skill.md`](add-skill.md) — adding a shared skill for the team.
- [`add-command.md`](add-command.md) — adding a slash-command / plugin.
- [`egress-allowlist.md`](egress-allowlist.md) — authorizing an egress domain.
- [`build-and-images.md`](build-and-images.md) — build, tag, team registry.

## Operate
- [`onboarding.md`](onboarding.md) — installing the sandbox on a new machine.
- [`troubleshooting.md`](troubleshooting.md) — troubleshooting.

## Contribute
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — workflow, conventions, PR checklist.

---

## 🧭 Where Does My Change Go, and How Do I Apply It?

Key point: **two update mechanisms** depending on which file is touched.

| What you change | File / directory | Mechanism | How to apply |
|---|---|---|---|
| Allowed egress domain | `profiles/<name>/allowlist.conf` | runtime render + bind-mount | restart the egress sidecar |
| MCP server | `containers/mcp-remote/servers.d/*.env` | bind-mount (runtime) | restart the mcp-remote sidecar |
| Harness-side MCP declaration | `profiles/<name>/config/` | **baked into image** | `make build-harness PROFILE=<name>` |
| Skill / command / plugin | `profiles/<name>/config/…` | **baked into image** | `make build-harness PROFILE=<name>` |
| New harness | `profiles/<name>/` (4-5 files) | profile | `make build-harness PROFILE=<name>` · see [`profiles.md`](profiles.md) |
| Entrypoint / Containerfile | `containers/*/` | **baked into image** | `make build-*` |
| Launcher / doctor | `bin/*.sh` | host script | nothing (immediate effect) |

**Restart a sidecar** (recreated on next `claude`):
```sh
podman rm -f egress-proxy      # or mcp-remote
```

**Rebuild the Claude image** (embedded config):
```sh
make build-harness PROFILE=claude
```

> Reminder: `config/` is copied into the image (`/opt/dist/config`) then re-copied into
> `~/.claude` on each run by the entrypoint — **without** overwriting `.credentials.json`.
> So a skill/command/mcp.json change requires a rebuild to be embedded.

After any change, validate with:
```sh
agent-doctor
```
