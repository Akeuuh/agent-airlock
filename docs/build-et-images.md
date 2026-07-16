# Build, images & registry

## Les images

| Image | Source | Contenu |
|---|---|---|
| `agent-base` | `containers/base/` | node + mise + socat + git + user `agent` (socle commun, **sans harness**) |
| `agent-<profil>` | `containers/harness/` + `profiles/<profil>/` | base + binaire du harness (`install.sh`) + bundle config |
| `mcp-remote` / `mcp-proxy` | `containers/mcp-remote/` | Node.js proxy MCP + OAuth automatique (PKCE) |
| `egress-proxy` | image squid officielle re-taggée | proxy, config montée au runtime |

Exemple : le profil `claude` produit `agent-claude` par-dessus `agent-base`.

## Commandes Make

```sh
make build          # base + harness (PROFILE=claude) + mcp + egress
make build-base     # image socle commune seule
make build-harness PROFILE=claude   # image d'un harness (après modif config/skills/commandes/mcp.json)
make build-mcp      # image sidecar MCP seule (utilisée par mcp-remote ET mcp-proxy)
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

- **Rebuild un harness** : toute modif de `profiles/<profil>/` (`install.sh`, `config/` :
  mcp.json, skills, commandes, plugins) ou de `containers/harness/Containerfile`. La config
  est **copiée dans l'image**, donc un simple redémarrage ne suffit pas :
  `make build-harness PROFILE=<profil>`.
- **Rebuild la base** : modif de `containers/base/` (`Containerfile`, `entrypoint.sh`,
  git-hooks-template) → `make build-base` puis rebuild des harness qui en dépendent.
- **Rebuild le sidecar MCP** : modif du `Containerfile`/`entrypoint.sh`/`proxy.js`.
  `servers.d/*.env` et `servers.d-proxy/*.env` sont bind-montés → pas de rebuild, juste
  `podman rm -f mcp-remote mcp-proxy`.
- **Pas de rebuild `egress`** : le `squid.conf` runtime est généré (base + allowlist du profil) et bind-monté → `podman rm -f egress-proxy`.

Le launcher **construit automatiquement** l'image base et l'image du harness si elles
sont absentes (message « pas encore construit, build en cours… »). Après un rebuild manuel,
relance simplement le launcher. Vérifie avec `agent-doctor`.

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
export AGENT_SANDBOX_REGISTRY=registry.example.com
claude        # podman pull l'image commune à chaque lancement
```

Le launcher lit `AGENT_SANDBOX_REGISTRY` (défaut `localhost`). Si l'image du harness est
absente localement, il la **build** ; avec un registry d'équipe configuré, adapte le flux
pour `pull` l'image commune.

> ⚠️ Le domaine du registry doit être joignable par l'hôte (pas par le harness) — c'est le
> launcher qui pull, hors sandbox. Pas besoin de l'ajouter à l'allowlist egress.

---

## Vérification post-build

```sh
podman images | grep -E 'agent-base|agent-claude|mcp-remote|mcp-proxy|egress-proxy'
agent-doctor        # images présentes + toute la chaîne
```
