# Catalogue de providers

Un **provider** = une clé d'auth **et** son/ses domaine(s) egress, **couplés** dans un
seul fichier. Découplé du harness : le même provider sert à `pi`, `opencode`, etc.

## Format `providers/<name>.env`

```bash
PROVIDER_KEYS="DEEPSEEK_API_KEY"        # nom(s) de variable d'env (séparés par espaces)
PROVIDER_DOMAINS="api.deepseek.com"     # domaine(s) egress ; .exemple.com = sous-domaines inclus
# PROVIDER_AUTH="oauth"                 # optionnel : provider par abonnement (login /login)
# PROVIDER_CALLBACK_PORT="53692"        # optionnel : port loopback OAuth à publier VM→hôte
# PROVIDER_RUN_ENV="PI_OAUTH_CALLBACK_HOST=0.0.0.0"  # optionnel : env injecté au run
```

Deux familles :
- **API key** (défaut) : `PROVIDER_KEYS` renseigné → la clé est injectée au run.
- **Abonnement / OAuth** (`PROVIDER_AUTH="oauth"`, `PROVIDER_KEYS=""`) : pas de clé ;
  login via `/login` dans le harness (device flow), token persisté dans le volume du
  profil. Le launcher resynchronise l'horloge VM (token horodaté) et le doctor vérifie
  le login. Ex. `github-copilot`.

## Sélection (par harness apikey)

Priorité : `--provider X` (override run) > `$AGENT_PROVIDERS` (env) >
`HARNESS_PROVIDERS` (défaut du profil, dans `profile.env`).

Le launcher, pour chaque provider actif :
- injecte ses clés (résolues depuis `profiles/<name>/secrets.env` puis l'env hôte) ;
- ajoute ses domaines à l'allowlist egress rendue (proxy recréé si le set change).

→ **La clé et le domaine ne peuvent plus diverger** : ajouter un provider = 1 sélection.

## Ajouter un provider

Crée `providers/<name>.env` avec ses 2 lignes, puis active-le
(`--provider <name>` ou `HARNESS_PROVIDERS="… <name>"`). Voir
[`../docs/profils.md`](../docs/profils.md).

## Providers fournis

anthropic · openai · google · deepseek · openrouter · groq · mistral · xai
(API key) · **github-copilot**, **claude-pro** (abonnement OAuth).
(Endpoints custom — Azure, gateways locales, base-URL maison : ajoute un `.env` dédié.)
