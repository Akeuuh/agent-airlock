# Authorizing an Egress Domain (Egress Allowlist)

The harness (container A) has **no direct internet route**. Its only egress goes through
the squid proxy in container C, under a **strict allowlist**. Each harness has **its own
allowlist** (`profiles/<name>/allowlist.conf`); the launcher injects it into the shared
base (`egress/squid.base.conf`) to produce the runtime `squid.conf`. Any domain absent from
the list is denied (`403`). This is the anti-exfiltration barrier: **only add a domain if
truly necessary**, and always prefer an MCP (container B) for application access.

> **Strict per profile**: the egress sidecar carries a label
> `agent-airlock.profile=<name>`. When the harness changes, the launcher **recreates**
> the sidecar with the correct allowlist (no list merging → minimal surface, preserved
> isolation).

> **Two layers** composed at the `@@ALLOWLIST@@` marker: the profile **infra**
> (`allowlist.conf`, versioned) + the **active provider domains** (catalog `providers/`).
> The label `agent-airlock.providers=<sig>` triggers sidecar recreation when the provider
> set changes. **MCP does NOT go through this allowlist**: MCP servers are reached by the
> **mcp-proxy sidecar** (direct egress, token injected), not by the harness — see
> [`profiles.md`](profiles.md) § MCP.

---

## Adding a Domain

Edit the allowlist **of the relevant profile** — e.g. `profiles/claude/allowlist.conf`:

```
acl allowed_domains dstdomain .anthropic.com
acl allowed_domains dstdomain .claude.ai
acl allowed_domains dstdomain .claude.com
acl allowed_domains dstdomain raw.githubusercontent.com
acl allowed_domains dstdomain .npmjs.org registry.npmjs.org   # ← example added
```

- `.example.com` (with the dot) = the domain **and** its subdomains.
- `example.com` (without dot) = only the exact host.
- Multiple hosts on one line, space-separated.

The shared base (`egress/squid.base.conf`) carries the ports/`deny` rules; don't touch it
to add a domain.

## Apply

The allowlist is **rendered at runtime** then bind-mounted (no rebuild). Restart the
egress sidecar; it is recreated on next launch with the updated allowlist:

```sh
podman rm -f egress-proxy
cd ~/my-repo && claude
```

## Verify

```sh
agent-doctor         # the "egress allowlist" section tests known domains
```

Manual test of a specific domain (from a container on the internal network):

```sh
podman run --rm --network agent-net --entrypoint "" localhost/agent-claude:latest \
  curl -s -o /dev/null -w '%{http_code}\n' -x http://10.89.0.10:3128 https://registry.npmjs.org
# 200/301/403… = authorized and reachable; 403 from squid = denied by the allowlist
```

---

## Common Cases

| Need | Typical Domains |
|---|---|
| `mise install` of tools at runtime | `mise.jdx.dev`, `github.com`, `objects.githubusercontent.com` |
| `npm install` | `registry.npmjs.org`, `.npmjs.org` |
| GitHub plugin marketplace | `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com` |
| pip / PyPI | `pypi.org`, `files.pythonhosted.org` |

## ⚠️ Before Adding

Each added domain widens the exfiltration surface. Ask yourself:

1. **Can this go through an MCP** (container B) instead of A's egress? If so, prefer that.
2. **Is it a read endpoint** (registry, CDN) or a service that accepts *writes* (where the
   agent could push data)? Be wary of the latter.
3. **Can you restrict to the exact subdomain** rather than a wildcard?

Document every addition in the commit (why this domain is needed).
