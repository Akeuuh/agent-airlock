# Adding a Shared Skill

Skills are **embedded in image A** and distributed to the whole team. At startup, the
entrypoint copies `/opt/dist/config/` into `~/.claude/` — so a skill placed in
`profiles/claude/config/skills/` ends up in `~/.claude/skills/` of every sandbox.

> A skill = a directory with a `SKILL.md` file (YAML frontmatter `name` + `description`,
> then the body in markdown). See the [Claude Code skills docs](https://code.claude.com/docs).

---

## 1. Create the Skill

```sh
mkdir -p profiles/claude/config/skills/my-skill
```

`profiles/claude/config/skills/my-skill/SKILL.md`:

```markdown
---
name: my-skill
description: >
  Describes WHEN to use this skill (keywords, situations). This text is the
  loading trigger — be precise and trigger-oriented.
---

# My Skill

## When to Use
…

## Steps
1. …
2. …

## Examples
…
```

You can add support scripts/files in the directory and reference them with **relative
paths** (resolved from the skill directory).

## 2. Embed & Test

Skills are **baked into the image** → rebuild then relaunch:

```sh
make build-harness PROFILE=claude
cd ~/my-repo && claude
```

In the session: ask Claude what triggers your skill, or list them
(`/help` / skill management depending on version). The file should be present:
```
~/.claude/skills/my-skill/SKILL.md
```

## 3. Commit

Unlike `servers.d/*.env`, skills **are versioned** (nothing ignores them in `.gitignore`)
— that's the point: share them with the team.

```sh
git add profiles/claude/config/skills/my-skill
git commit -m "feat(skills): add my-skill"
```

---

## Best Practices

- **One skill = one workflow / one domain.** No catch-all skills.
- The `description` is the trigger: put keywords and concrete situations in it.
- Keep it short; if it exceeds ~500 lines, split it up.
- Skills execute **inside the sandbox**: a skill that calls the network must go through
  the proxy (allowlist) or through an MCP — keep that in mind.
