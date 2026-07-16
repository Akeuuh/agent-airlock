# Adding a Slash-Command (& Plugin Concept)

Like skills, **custom commands** are embedded in image A and distributed to the team
via `profiles/claude/config/`. The entrypoint copies them to `~/.claude/` on each run.

A Claude Code slash-command = a markdown file in `~/.claude/commands/<name>.md`.
Invoke it with `/<name>` during a session.

---

## 1. Create the Command

```sh
mkdir -p profiles/claude/config/commands
```

`profiles/claude/config/commands/review.md`:

```markdown
---
description: Review the current diff (bugs, security, style) and suggest fixes.
---

Analyze `git diff` in /workspace. For each issue:
- severity (bug / security / style)
- file:line
- suggested fix

Stay concise. Don't modify anything without my approval.
```

- The **frontmatter** `description` shows in `/` autocompletion.
- The **body** is the injected prompt. You can use arguments (`$ARGUMENTS`) and
  placeholders depending on the Claude Code version.
- Subdirectories = namespaces: `commands/git/review.md` → `/git:review`.

## 2. Embed & Test

```sh
make build-harness PROFILE=claude
cd ~/my-repo && claude
# in the session:
/review
```

The file should be present: `~/.claude/commands/review.md`.

## 3. Commit

```sh
git add profiles/claude/config/commands/review.md
git commit -m "feat(commands): add /review"
```

---

## What About Plugins / Marketplace?

Claude Code can load **plugins** (bundles of skills + commands + config) from a
marketplace. Two ways to distribute them here:

1. **Embedded files** (recommended for a stable team set): place the plugin content under
   `profiles/claude/config/` (e.g. `plugins/…`) — it will be copied to `~/.claude` like
   everything else. Rebuild the image required.
2. **Remote marketplace**: if you point to an online marketplace (GitHub…), remember to
   **add its domain to the allowlist** (`profiles/<name>/allowlist.conf`, see
   [`egress-allowlist.md`](egress-allowlist.md)) otherwise the fetch will be blocked.
   `raw.githubusercontent.com` is already authorized; `github.com`/`objects.githubusercontent.com`
   are not by default.

> Prefer embedding: it's reproducible, versioned, and doesn't open a new network channel.
