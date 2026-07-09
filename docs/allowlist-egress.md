# Autoriser un domaine de sortie (allowlist egress)

Claude (conteneur A) n'a **aucune route internet directe**. Sa seule sortie passe par le
proxy squid du conteneur C, en **allowlist stricte** (`egress/squid.conf`). Tout domaine
absent de la liste est refusé (`403`). C'est la barrière anti-exfiltration : **n'ajoute un
domaine que si c'est réellement nécessaire**, et privilégie toujours un MCP (conteneur B)
pour l'accès applicatif.

---

## Ajouter un domaine

Édite `egress/squid.conf`, section allowlist :

```
acl allowed_domains dstdomain .anthropic.com
acl allowed_domains dstdomain .claude.ai
acl allowed_domains dstdomain .claude.com
acl allowed_domains dstdomain raw.githubusercontent.com
acl allowed_domains dstdomain .npmjs.org registry.npmjs.org   # ← exemple ajouté
```

- `.exemple.com` (avec le point) = le domaine **et** ses sous-domaines.
- `exemple.com` (sans point) = uniquement l'hôte exact.
- Plusieurs hôtes sur une ligne, séparés par des espaces.

## Appliquer

`squid.conf` est **bind-monté** (pas de rebuild). Redémarre juste le sidecar egress ; il est
recréé au prochain lancement :

```sh
podman rm -f egress-proxy
cd ~/mon-repo && claude
```

## Vérifier

```sh
claude-doctor         # la section « allowlist egress » teste les domaines connus
```

Test manuel d'un domaine précis (depuis un conteneur sur le réseau interne) :

```sh
podman run --rm --network claude-net --entrypoint "" localhost/claude-sandbox:latest \
  curl -s -o /dev/null -w '%{http_code}\n' -x http://10.89.0.10:3128 https://registry.npmjs.org
# 200/301/403… = autorisé et joignable ; 403 par squid = refusé par l'allowlist
```

---

## Cas courants

| Besoin | Domaines typiques |
|---|---|
| `mise install` d'outils au runtime | `mise.jdx.dev`, `github.com`, `objects.githubusercontent.com` |
| `npm install` | `registry.npmjs.org`, `.npmjs.org` |
| Marketplace de plugins GitHub | `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com` |
| pip / PyPI | `pypi.org`, `files.pythonhosted.org` |

## ⚠️ Avant d'ajouter

Chaque domaine ajouté élargit la surface d'exfiltration. Demande-toi :

1. **Est-ce que ça peut passer par un MCP** (conteneur B) plutôt que par la sortie de A ? Si
   oui, préfère ça.
2. **Est-ce un endpoint de lecture** (registry, CDN) ou un service qui accepte des *écritures*
   (où l'agent pourrait pousser des données) ? Méfiance sur le second.
3. **Peut-on restreindre au sous-domaine exact** plutôt qu'au wildcard ?

Documente tout ajout dans le commit (pourquoi ce domaine est nécessaire).
