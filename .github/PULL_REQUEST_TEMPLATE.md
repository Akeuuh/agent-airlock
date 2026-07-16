## Description

<!-- Explain the problem solved or the feature added. The "why", not the "what". -->

## Change Type

- [ ] `feat` — new capability
- [ ] `fix` — bugfix
- [ ] `harden` — security hardening / surface reduction
- [ ] `docs` — documentation
- [ ] `chore` — tooling, build, housekeeping

## PR Checklist

- [ ] `agent-doctor` **green** (network isolation, allowlist, sidecars)
- [ ] No secrets committed (tokens, real `.env` files, keys)
- [ ] Network change (allowlist / published port) **justified** in the commit and as restrictive as possible (exact subdomain, no wildcard)
- [ ] A new MCP has a restrictive `ALLOWED_TOOLS` (no destructive tool exposed)
- [ ] Docs up to date if behavior changes
- [ ] No privilege escalation in containers (`--privileged` absent, no unnecessary host mounts, agent stays as `claude` user)
