# Contribuer

Merci de contribuer au sandbox ! Ce projet enferme un agent en qui on n'a pas confiance —
donc **toute contribution touchant au réseau, aux volumes ou aux privilèges doit être relue
avec le modèle de menace en tête** ([`docs/architecture.md`](docs/architecture.md)).

## Prérequis

Voir le [README](README.md) : Podman + `make build` + alias. Vérifie ton install :

```sh
agent-doctor
```

## Workflow

1. **Branche** depuis `main` : `git checkout -b feat/mon-sujet`.
2. **Modifie** en suivant le [tableau « où va ma modif »](docs/README.md#-où-va-ma-modif-et-comment-lappliquer)
   (bind-mount vs rebuild image).
3. **Teste** : rebuild si besoin, relance `claude` dans un vrai repo, et **`agent-doctor`
   doit rester vert** (surtout isolation réseau + allowlist).
4. **Commit** en [Conventional Commits](#convention-de-commit).
5. **PR** avec la [checklist](#checklist-pr) remplie.

## Convention de commit

Format `type(scope): sujet` — sujet ≤ ~70 car., à l'impératif, sans point final.

| type | usage |
|---|---|
| `feat` | nouvelle capacité (skill, commande, MCP, option launcher) |
| `fix` | correction |
| `docs` | documentation |
| `harden` | durcissement sécurité / réduction de surface |
| `chore` | tooling, build, ménage |

Exemples : `feat(mcp): ajoute le serveur linear`, `harden(egress): retire le wildcard github`.

Le corps explique le **pourquoi** (pas le quoi). Pour toute modif réseau/sécu, justifie.

## Checklist PR

- [ ] `agent-doctor` **vert** (isolation, allowlist, sidecars).
- [ ] Aucun secret commité (tokens, `.env` réels, clés) — cf. `.gitignore`.
- [ ] Modif réseau (allowlist / port publié) **justifiée** dans le commit + a minima
      possible (sous-domaine exact plutôt que wildcard).
- [ ] Un nouveau MCP a un `ALLOWED_TOOLS` restrictif (pas de tool destructeur exposé).
- [ ] Doc à jour si le comportement change (guides dans `docs/`).
- [ ] Pas d'élévation de privilèges dans les conteneurs (pas de `--privileged`, pas de
      montage hôte superflu, l'agent reste user `claude`).

## Principes de design (à ne pas casser)

- **Le conteneur A n'a jamais internet direct** — uniquement via le proxy egress.
- **Les credentials ne vivent jamais dans A** : login abonnement dans `agent-home-claude`, tokens
  MCP dans `agent-mcp-auth` (monté seulement dans B).
- **Allowlist par défaut fermée** : on ajoute au cas par cas, jamais de « allow all ».
- **Réduire la surface du canal MCP** via `ALLOWED_TOOLS`.
- **Rien d'exécuté par l'agent ne doit s'échapper** (hooks git neutralisés, volumes maîtrisés).

## Où mettre quoi

| Contribution | Guide |
|---|---|
| Serveur MCP | [`docs/ajouter-un-mcp.md`](docs/ajouter-un-mcp.md) |
| Skill | [`docs/ajouter-un-skill.md`](docs/ajouter-un-skill.md) |
| Slash-command / plugin | [`docs/ajouter-une-commande.md`](docs/ajouter-une-commande.md) |
| Domaine de sortie | [`docs/allowlist-egress.md`](docs/allowlist-egress.md) |
| Build / images / registry | [`docs/build-et-images.md`](docs/build-et-images.md) |
