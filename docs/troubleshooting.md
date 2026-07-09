# Dépannage

Commence toujours par :

```sh
claude-doctor
```

Il localise 90 % des problèmes (machine, images, réseau, isolation, allowlist, tunnel, auth).

## Symptômes courants

| Symptôme | Cause / fix |
|---|---|
| `Error: statfs /tmp/… no such file or directory` | Podman machine ne monte que `$HOME`. Mets le repo **sous `$HOME`**, ou `podman machine set --volume`. |
| `ERR_SOCKET_CLOSED` / `Unable to connect to Anthropic` | Un domaine requis manque à l'allowlist `egress/squid.conf` → voir [`allowlist-egress.md`](allowlist-egress.md). |
| `krunkit: executable file not found` au `machine start` | Réinitialise avec le provider Apple : `podman machine rm -f podman-machine-default && podman machine init --provider applehv`. |
| Proxy `HIER_NONE/503` | DNS des sidecars cassé → réseau doit être `--disable-dns` + IP statiques (déjà géré par le launcher). Détails : [`reseau.md`](reseau.md). |
| `The input device is not a TTY` | `claude` doit être lancé depuis un **vrai terminal**, pas un pipe. |
| **Déconnecté juste après un réveil du Mac** | Dérive d'horloge de la VM → token OAuth rejeté. Relance `claude` (resync auto). Détails : [`authentification.md`](authentification.md). |
| Login redemandé à chaque run | Le volume `claude-home` n'est pas monté / a été supprimé. |
| `/mcp` montre « failed » | PORT différent entre `mcp.json` et le `.env`, ou sidecar mcp-remote pas redémarré → [`ajouter-un-mcp.md`](ajouter-un-mcp.md). |
| L'OAuth ne s'ouvre jamais | `CALLBACK_PORT` vide, ou en **doublon** entre deux MCP (le launcher WARN), ou sidecar pas recréé après ajout → [`ajouter-un-mcp.md`](ajouter-un-mcp.md). |
| `mise install` échoue au démarrage | Les registries ne sont pas dans l'allowlist squid → [`allowlist-egress.md`](allowlist-egress.md). |
| Une modif de `mcp.json`/skill/commande n'a aucun effet | Config **cuite dans l'image** : il faut `make build-claude` (pas juste relancer) → [`build-et-images.md`](build-et-images.md). |

## Inspecter à la main

```sh
podman ps                          # les 3 conteneurs tournent ?
podman logs egress-proxy           # squid : voir les TCP_DENIED/403
podman logs mcp-remote             # les serveurs MCP chargés
podman network inspect claude-net  # internal=true, dns=false ?
```

Tester un domaine à travers le proxy (depuis le réseau interne) :

```sh
podman run --rm --network claude-net --entrypoint "" localhost/claude-sandbox:latest \
  curl -s -o /dev/null -w '%{http_code}\n' -x http://10.89.0.10:3128 https://api.anthropic.com
```

## Repartir de zéro

```sh
make clean                 # stoppe/supprime sidecars + réseau
# (optionnel) oublier login/tokens :
podman volume rm claude-home claude-mcp-auth
# (optionnel) rebuild complet :
make build
```
