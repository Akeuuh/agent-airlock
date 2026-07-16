# Contributing

Thanks for contributing to the sandbox! This project locks up an untrusted agent — so
**any contribution touching networking, volumes, or privileges must be reviewed with the
threat model in mind** ([`docs/architecture.md`](docs/architecture.md)).

## Prerequisites

See the [README](README.md): Podman + `make build` + alias. Verify your setup:

```sh
agent-doctor
```

## Workflow

1. **Branch** off `main`: `git checkout -b feat/my-topic`.
2. **Make changes** following the [“where does my change go” table](docs/README.md#-where-does-my-change-go-and-how-do-i-apply-it)
   (bind-mount vs. rebuild image).
3. **Test**: rebuild if needed, relaunch `claude` in a real repo, and **`agent-doctor`
   must stay green** (especially network isolation + allowlist).
4. **Commit** using [Conventional Commits](#commit-convention).
5. **PR** with the [checklist](#pr-checklist) filled out.

## Commit Convention

Format `type(scope): subject` — subject ≤ ~70 chars, imperative, no trailing period.

| type | usage |
|---|---|
| `feat` | new capability (skill, command, MCP, launcher option) |
| `fix` | bugfix |
| `docs` | documentation |
| `harden` | security hardening / surface reduction |
| `chore` | tooling, build, housekeeping |

Examples: `feat(mcp): add linear server`, `harden(egress): remove github wildcard`.

The body explains the **why** (not the what). For any network/security change, justify it.

## PR Checklist

- [ ] `agent-doctor` **green** (isolation, allowlist, sidecars).
- [ ] No secrets committed (tokens, real `.env` files, keys) — see `.gitignore`.
- [ ] Network change (allowlist / published port) **justified** in the commit + as minimal
      as possible (exact subdomain rather than wildcard).
- [ ] A new MCP has a restrictive `ALLOWED_TOOLS` (no destructive tool exposed).
- [ ] Docs up to date if behavior changes (guides in `docs/`).
- [ ] No privilege escalation in containers (no `--privileged`, no unnecessary host mounts,
      agent stays as `claude` user).

## Design Principles (Do Not Break)

- **Container A never has direct internet** — only via the egress proxy.
- **Credentials never live in A**: subscription login in `agent-home-claude`, MCP
  tokens in `agent-mcp-auth` (mounted only in B).
- **Allowlist is closed by default**: add on a case-by-case basis, never "allow all".
- **Reduce MCP channel surface** via `ALLOWED_TOOLS`.
- **Nothing executed by the agent must escape** (git hooks neutralized, volumes controlled).

## Where to Put What

| Contribution | Guide |
|---|---|
| MCP server | [`docs/add-mcp.md`](docs/add-mcp.md) |
| Skill | [`docs/add-skill.md`](docs/add-skill.md) |
| Slash-command / plugin | [`docs/add-command.md`](docs/add-command.md) |
| Egress domain | [`docs/egress-allowlist.md`](docs/egress-allowlist.md) |
| Build / images / registry | [`docs/build-and-images.md`](docs/build-and-images.md) |
