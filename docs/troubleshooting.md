# Troubleshooting

Always start with:

```sh
agent-doctor
```

It pinpoints 90% of issues (machine, images, network, isolation, allowlist, tunnel, auth).

## Common Symptoms

| Symptom | Cause / Fix |
|---|---|
| `Error: statfs /tmp/… no such file or directory` | Podman machine only mounts `$HOME`. Put the repo **under `$HOME`**, or `podman machine set --volume`. |
| `ERR_SOCKET_CLOSED` / `Unable to connect to Anthropic` | A required domain is missing from the allowlist `profiles/<name>/allowlist.conf` → see [`egress-allowlist.md`](egress-allowlist.md). |
| `krunkit: executable file not found` on `machine start` | Reset with the Apple provider: `podman machine rm -f podman-machine-default && podman machine init --provider applehv`. |
| Proxy `HIER_NONE/503` | Broken sidecar DNS → network must be `--disable-dns` + static IPs (already handled by the launcher). Details: [`network.md`](network.md). |
| `The input device is not a TTY` | `claude` must be launched from a **real terminal**, not a pipe. |
| **Logged out right after waking the Mac** | VM clock drift → OAuth token rejected. Relaunch `claude` (auto resync). Details: [`authentication.md`](authentication.md). |
| Login prompted every run | The `agent-home-claude` volume is not mounted / was deleted. |
| `/mcp` shows "failed" / "has no OAuth config" | Token not imported. Check `podman logs mcp-proxy` (pi) or `mcp-remote` (claude/opencode) for instructions. See [`profiles.md`](profiles.md) § MCP. |
| OAuth never completes | Most servers don't support auto-discovery → instructions are in `podman logs`. Fallback: host login + `agent-import-auth.sh --mcp <server>`. |
| `mise install` fails at startup | Registries not in the squid allowlist → [`egress-allowlist.md`](egress-allowlist.md). |
| `mcp.json`/skill/command change has no effect | Config **baked into the image**: you need `make build-harness PROFILE=claude` (not just a restart) → [`build-and-images.md`](build-and-images.md). |

## Manual Inspection

```sh
podman ps                          # all 3 containers running?
podman logs egress-proxy           # squid: see TCP_DENIED/403
podman logs mcp-remote             # MCP proxy (servers.d)
podman logs mcp-proxy              # MCP proxy (servers.d-proxy, for pi)
podman network inspect agent-net  # internal=true, dns=false?
```

Test a domain through the proxy (from the internal network):

```sh
podman run --rm --network agent-net --entrypoint "" localhost/agent-claude:latest \
  curl -s -o /dev/null -w '%{http_code}\n' -x http://10.89.0.10:3128 https://api.anthropic.com
```

## Start Fresh

```sh
make clean                 # stop/remove sidecars + network
# (optional) forget login/tokens:
podman volume rm agent-home-claude agent-mcp-auth
# (optional) remove proxy sidecars:
podman rm -f mcp-remote mcp-proxy
# (optional) full rebuild:
make build
```
