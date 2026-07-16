# Ajouter un skill commun

Les skills sont **embarqués dans l'image A** et distribués à toute l'équipe. Au démarrage,
l'entrypoint copie `/opt/dist/config/` dans `~/.claude/` — donc un skill placé dans
`profiles/claude/config/skills/` se retrouve dans `~/.claude/skills/` de chaque sandbox.

> Un skill = un dossier avec un fichier `SKILL.md` (frontmatter YAML `name` + `description`,
> puis le corps en markdown). Voir la [doc skills de Claude Code](https://code.claude.com/docs).

---

## 1. Créer le skill

```sh
mkdir -p profiles/claude/config/skills/mon-skill
```

`profiles/claude/config/skills/mon-skill/SKILL.md` :

```markdown
---
name: mon-skill
description: >
  Décrit QUAND utiliser ce skill (mots-clés, situations). C'est ce texte qui
  déclenche le chargement — sois précis et orienté déclencheurs.
---

# Mon skill

## Quand l'utiliser
…

## Étapes
1. …
2. …

## Exemples
…
```

Tu peux ajouter des scripts/fichiers d'appui dans le dossier et les référencer en **chemin
relatif** (résolus depuis le dossier du skill).

## 2. Embarquer & tester

Les skills sont **cuits dans l'image** → rebuild puis relance :

```sh
make build-harness PROFILE=claude
cd ~/mon-repo && claude
```

Dans la session : demande à Claude ce que déclenche ton skill, ou liste-les
(`/help` / gestion des skills selon la version). Le fichier doit être présent :
```
~/.claude/skills/mon-skill/SKILL.md
```

## 3. Commiter

Contrairement aux `servers.d/*.env`, les skills **sont versionnés** (rien ne les ignore dans
`.gitignore`) — c'est le but : les partager à l'équipe.

```sh
git add profiles/claude/config/skills/mon-skill
git commit -m "feat(skills): ajoute mon-skill"
```

---

## Bonnes pratiques

- **Un skill = un workflow / un domaine.** Pas de skill fourre-tout.
- La `description` est le déclencheur : mets-y des mots-clés et des situations concrètes.
- Garde-le court ; s'il dépasse ~500 lignes, découpe-le.
- Les skills sont exécutés **dans le sandbox** : un skill qui appelle le réseau devra passer
  par le proxy (allowlist) ou par un MCP — pense-y.
