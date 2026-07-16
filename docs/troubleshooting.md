# Dépannage

Commence toujours par :

```sh
agent-doctor
```

Il localise 90 % des problèmes (machine, images, réseau, isolation, allowlist, tunnel, auth).

## Symptômes courants

| Symptôme | Cause / fix |
|---|---|
| `Error: statfs /tmp/… no such file or directory` | Podman machine ne monte que `$HOME`. Mets le repo **sous `$HOME`**, ou `podman machine set --volume`. |
| `ERR_SOCKET_CLOSED` / `Unable to connect to Anthropic` | Un domaine requis manque à l'allowlist `profiles/<name>/allowlist.conf` → voir [`allowlist-egress.md`](allowlist-egress.md). |
| `krunkit: executable file not found` au `machine start` | Réinitialise avec le provider Apple : `podman machine rm -f podman-machine-default && podman machine init --provider applehv`. |
| Proxy `HIER_NONE/503` | DNS des sidecars cassé → réseau doit être `--disable-dns` + IP statiques (déjà géré par le launcher). Détails : [`reseau.md`](reseau.md). |
| `The input device is not a TTY` | `claude` doit être lancé depuis un **vrai terminal**, pas un pipe. |
| **Déconnecté juste après un réveil du Mac** | Dérive d'horloge de la VM → token OAuth rejeté. Relance `claude` (resync auto). Détails : [`authentification.md`](authentification.md). |
| Login redemandé à chaque run | Le volume `agent-home-claude` n'est pas monté / a été supprimé. |
| `/mcp` montre « failed » / « has no OAuth config » | Token pas importé. Vérifie `podman logs mcp-proxy` (pi) ou `mcp-remote` (claude/opencode) pour les instructions. Voir [`profils.md`](profils.md) § MCP. |
| L'OAuth n'aboutit pas | La plupart des serveurs ne supportent pas la discovery auto → les instructions sont dans `podman logs`. Fallback : login hôte + `agent-import-auth.sh --mcp <serveur>`. |
| `mise install` échoue au démarrage | Les registries ne sont pas dans l'allowlist squid → [`allowlist-egress.md`](allowlist-egress.md). |
| Une modif de `mcp.json`/skill/commande n'a aucun effet | Config **cuite dans l'image** : il faut `make build-harness PROFILE=claude` (pas juste relancer) → [`build-et-images.md`](build-et-images.md). |

## Inspecter à la main

```sh
podman ps                          # les 3 conteneurs tournent ?
podman logs egress-proxy           # squid : voir les TCP_DENIED/403
podman logs mcp-remote             # proxy MCP (servers.d)
podman logs mcp-proxy              # proxy MCP (servers.d-proxy, pour pi)
podman network inspect agent-net  # internal=true, dns=false ?
```

Tester un domaine à travers le proxy (depuis le réseau interne) :

```sh
podman run --rm --network agent-net --entrypoint "" localhost/agent-claude:latest \
  curl -s -o /dev/null -w '%{http_code}\n' -x http://10.89.0.10:3128 https://api.anthropic.com
```

## Repartir de zéro

```sh
make clean                 # stoppe/supprime sidecars + réseau
# (optionnel) oublier login/tokens :
podman volume rm agent-home-claude agent-mcp-auth
# (optionnel) supprimer les sidecars proxy :
podman rm -f mcp-remote mcp-proxy
# (optionnel) rebuild complet :
make build
```
