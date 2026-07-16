# Ajouter une slash-command (et notion de plugin)

Comme les skills, les **commandes personnalisées** sont embarquées dans l'image A et
distribuées à l'équipe via `profiles/claude/config/`. L'entrypoint les copie dans
`~/.claude/` à chaque run.

Une slash-command Claude Code = un fichier markdown dans `~/.claude/commands/<nom>.md`.
L'invoquer se fait avec `/<nom>` dans la session.

---

## 1. Créer la commande

```sh
mkdir -p profiles/claude/config/commands
```

`profiles/claude/config/commands/review.md` :

```markdown
---
description: Relit le diff courant (bugs, sécurité, style) et propose des correctifs.
---

Analyse `git diff` dans /workspace. Pour chaque problème :
- niveau (bug / sécu / style)
- fichier:ligne
- correctif proposé

Reste concis. Ne modifie rien sans mon accord.
```

- Le **frontmatter** `description` s'affiche dans l'autocomplétion de `/`.
- Le **corps** est le prompt injecté. Tu peux utiliser des arguments (`$ARGUMENTS`) et des
  placeholders selon la version de Claude Code.
- Sous-dossiers = namespaces : `commands/git/review.md` → `/git:review`.

## 2. Embarquer & tester

```sh
make build-harness PROFILE=claude
cd ~/mon-repo && claude
# dans la session :
/review
```

Le fichier doit être présent : `~/.claude/commands/review.md`.

## 3. Commiter

```sh
git add profiles/claude/config/commands/review.md
git commit -m "feat(commands): ajoute /review"
```

---

## Et les plugins / marketplace ?

Claude Code sait charger des **plugins** (bundles de skills + commandes + config) depuis une
marketplace. Deux façons de les distribuer ici :

1. **Fichiers embarqués** (recommandé pour un set stable d'équipe) : place le contenu du
   plugin sous `profiles/claude/config/` (ex. `plugins/…`) — il sera copié dans `~/.claude`
   comme le reste. Rebuild de l'image nécessaire.
2. **Marketplace distante** : si tu pointes vers une marketplace en ligne (GitHub…), pense à
   **ajouter son domaine à l'allowlist** (`profiles/<name>/allowlist.conf`, cf.
   [`allowlist-egress.md`](allowlist-egress.md)) sinon le fetch sera bloqué. `raw.githubusercontent.com`
   est déjà autorisé ; `github.com`/`objects.githubusercontent.com` ne le sont pas par défaut.

> Garde une préférence pour l'embarqué : c'est reproductible, versionné, et ça n'ouvre pas de
> nouveau canal réseau.
