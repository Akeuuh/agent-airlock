# Documentation — agent-airlock

Guides pour **utiliser, étendre et contribuer** au sandbox.

## Comprendre
- [`architecture.md`](architecture.md) — modèle de menace, schémas, décisions de design.
- [`reseau.md`](reseau.md) — réseau interne, DNS, IP statiques, tunnel MCP socat.
- [`acces-web.md`](acces-web.md) — WebSearch / WebFetch / MCP : ce que Claude peut fetcher.
- [`authentification.md`](authentification.md) — login abonnement, resync horloge, volumes.
- Le [README](../README.md) — vue d'ensemble + installation.

## Étendre
- [`ajouter-un-mcp.md`](ajouter-un-mcp.md) — brancher un serveur MCP (via le conteneur B).
- [`ajouter-un-skill.md`](ajouter-un-skill.md) — ajouter un skill commun à l'équipe.
- [`ajouter-une-commande.md`](ajouter-une-commande.md) — ajouter une slash-command / un plugin.
- [`allowlist-egress.md`](allowlist-egress.md) — autoriser un domaine de sortie.
- [`build-et-images.md`](build-et-images.md) — build, tag, registry d'équipe.

## Exploiter
- [`onboarding.md`](onboarding.md) — installer le sandbox sur une nouvelle machine.
- [`troubleshooting.md`](troubleshooting.md) — dépannage.

## Contribuer
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — workflow, conventions, checklist PR.

---

## 🧭 Où va ma modif, et comment l'appliquer ?

Point clé : **deux mécanismes** de mise à jour selon le fichier touché.

| Ce que tu changes | Fichier / dossier | Mécanisme | Pour l'appliquer |
|---|---|---|---|
| Domaine autorisé en sortie | `egress/squid.conf` | bind-mount (runtime) | redémarrer le sidecar egress |
| Serveur MCP | `containers/mcp-remote/servers.d/*.env` | bind-mount (runtime) | redémarrer le sidecar mcp-remote |
| MCP déclaré côté Claude | `containers/claude/config/mcp.json` | **cuit dans l'image** | `make build-claude` |
| Skill / commande / plugin | `containers/claude/config/…` | **cuit dans l'image** | `make build-claude` |
| Entrypoint / Containerfile | `containers/*/` | **cuit dans l'image** | `make build-*` |
| Launcher / doctor | `bin/*.sh` | script hôte | rien (effet immédiat) |

**Redémarrer un sidecar** (recréé au prochain `claude`) :
```sh
podman rm -f egress-proxy      # ou mcp-remote
```

**Rebuild l'image Claude** (config embarquée) :
```sh
make build-claude
```

> Rappel : `config/` est copié dans l'image (`/opt/claude-dist/config`) puis recopié dans
> `~/.claude` à chaque run par l'entrypoint — **sans** écraser `.credentials.json`. Donc une
> modif de skill/commande/mcp.json nécessite un rebuild pour être embarquée.

Après toute modif, valide avec :
```sh
claude-doctor
```
