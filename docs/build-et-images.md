# Build, images & registry

## Les trois images

| Image | Source | Contenu |
|---|---|---|
| `claude-sandbox` | `containers/claude/` | node + Claude Code + mise + socat + config embarquée |
| `mcp-remote` | `containers/mcp-remote/` | node + mcp-remote + socat |
| `egress-proxy` | image squid officielle re-taggée | proxy, config montée au runtime |

## Commandes Make

```sh
make build          # build les 3 images
make build-claude   # image A seule (après modif config/skills/commandes/mcp.json)
make build-mcp      # image B seule
make build-egress   # pull + tag squid
make clean          # stoppe/supprime les sidecars + le réseau
```

Variables :

```sh
make build REGISTRY=registry.example.com TAG=2025-07
```

Par défaut `REGISTRY=localhost` et `TAG=latest`.

---

## Quand rebuilder ?

Voir aussi le [tableau « où va ma modif »](README.md#-où-va-ma-modif-et-comment-lappliquer).

- **Rebuild `claude`** : toute modif de `containers/claude/` — `Containerfile`, `entrypoint.sh`,
  ou `config/` (mcp.json, skills, commandes, plugins). La config est **copiée dans l'image**,
  donc un simple redémarrage ne suffit pas.
- **Rebuild `mcp-remote`** : modif du `Containerfile`/`entrypoint.sh` de B. En revanche
  `servers.d/*.env` est bind-monté → pas de rebuild, juste `podman rm -f mcp-remote`.
- **Pas de rebuild `egress`** : `squid.conf` est bind-monté → `podman rm -f egress-proxy`.

Après un rebuild de `claude`, relance simplement `claude` (le launcher fait le `pull` puis
retombe sur le cache local frais). Vérifie avec `claude-doctor`.

---

## Registry d'équipe (à mettre en place)

Aujourd'hui les images restent en `localhost` : chaque personne fait `make build`. Pour
distribuer une image commune (skills/plugins à jour pour tous, plus de build local) :

```sh
# 1. Builder en taggant vers le registry d'équipe
make build REGISTRY=registry.example.com

# 2. Pousser
make push REGISTRY=registry.example.com

# 3. Côté équipe : pointer le launcher vers ce registry
export CLAUDE_SANDBOX_REGISTRY=registry.example.com
claude        # podman pull l'image commune à chaque lancement
```

Le launcher lit `CLAUDE_SANDBOX_REGISTRY` (défaut `localhost`) et `pull` au démarrage ; si le
pull échoue (offline), il retombe sur le cache local avec un `WARN`.

> ⚠️ Le domaine du registry doit être joignable par l'hôte (pas par Claude) — c'est le
> launcher qui pull, hors sandbox. Pas besoin de l'ajouter à l'allowlist egress.

---

## Vérification post-build

```sh
podman images | grep -E 'claude-sandbox|mcp-remote|egress-proxy'
claude-doctor        # images présentes + toute la chaîne
```
