# Onboarding — installer le sandbox sur une nouvelle machine

Le sandbox est **par machine** : chaque personne construit ses images localement et se
connecte avec **son propre** abonnement Claude (ses credentials restent dans *ses* volumes,
rien n'est partagé).

> ℹ️ Tant qu'aucun **registry d'équipe** n'est configuré (`AGENT_SANDBOX_REGISTRY`), les
> images ne sont pas poussées : chacun fait `make build` après le clone. Le launcher tente un
> `podman pull` puis retombe sur le cache local si le pull échoue — c'est normal en mode
> « localhost ». Voir [`build-et-images.md`](build-et-images.md) pour le registry d'équipe.

## Étapes

```sh
# 1. Podman + VM (provider Apple natif, aucune dépendance externe)
brew install podman
podman machine init --provider applehv && podman machine start

# 2. Cloner + builder les images (~5 min la première fois)
git clone <ce-repo> ~/agent-airlock
cd ~/agent-airlock
make build

# 3. Alias dans le shell rc
echo "alias claude='~/agent-airlock/bin/agent-sandbox.sh'" >> ~/.zshrc
echo "alias agent-doctor='~/agent-airlock/bin/agent-doctor.sh'" >> ~/.zshrc
source ~/.zshrc

# 4. Vérifier
agent-doctor      # tout doit être vert sauf « auth » (pas encore loggué)

# 5. Se connecter (son propre compte)
cd ~/un-repo-sous-home
claude             # login abonnement au 1er run → persisté dans SON volume agent-home-claude
```

## Checklist

- [ ] Repo de travail **sous `$HOME`** (un mount depuis `/tmp` échoue — cf.
      [`troubleshooting.md`](troubleshooting.md)).
- [ ] `agent-doctor` : réseau interne, isolation, allowlist → verts.
- [ ] Login effectué une fois (le doctor passe « auth » au vert ensuite —
      cf. [`authentification.md`](authentification.md)).
- [ ] Pour les **MCP** : chacun fait son propre flow OAuth (stocké dans *son*
      `agent-mcp-auth`). Copier les `servers.d/<nom>.env` nécessaires (non versionnés) —
      cf. [`ajouter-un-mcp.md`](ajouter-un-mcp.md).

## Quand il y aura un registry d'équipe

`make push` une fois, puis les collègues n'ont plus qu'à
`export AGENT_SANDBOX_REGISTRY=<registry>` — le launcher `podman pull` l'image commune à
chaque lancement (skills/plugins toujours à jour), plus besoin de `make build` local.
Détails : [`build-et-images.md`](build-et-images.md).
