# Profils — support multi-harness

Le sandbox est **agnostique du harness**. Tout ce qui est spécifique à un agent
(Claude Code, pi, opencode…) vit dans un **profil** ; le socle (réseau interne,
sidecars, egress, entrypoint) est générique et ne connaît aucun harness en dur.

> TL;DR : **ajouter un harness = créer un dossier `profiles/<name>/` (4-5 fichiers).**
> Aucun script à modifier.

---

## Anatomie d'un profil

```
profiles/<name>/
├── profile.env          # TOUTES les variables du harness (sourcé par launcher/doctor)
├── install.sh           # comment installer le binaire dans l'image (exécuté en root au build)
├── allowlist.conf       # fragment squid : domaines d'INFRA du harness (les providers viennent du catalogue)
├── secrets.env.sample   # (auth apikey) modèle de clés — copier en secrets.env (gitignoré)
└── config/              # bundle "managé" seedé dans le config-dir au run (mcp, skills, settings…)
```

### `profile.env`

| Variable | Rôle |
|---|---|
| `HARNESS_NAME` | nom du profil (= dossier) |
| `HARNESS_BIN` | binaire lancé dans le conteneur |
| `HARNESS_LAUNCH_ARGS` | arguments passés au binaire (word-splittés) |
| `HARNESS_CONFIG_DIR` | dossier de config dans le conteneur (monté sur volume persistant) |
| `HARNESS_CONFIG_ENV` | nom de la variable d'env qui localise la config (vide si chemin fixe) |
| `HARNESS_HOME_VOL` | volume persistant du login/config — **un par harness** |
| `HARNESS_AUTH_MODE` | `oauth` (login navigateur + credentials persistés) ou `apikey` |
| `HARNESS_CREDENTIALS_FILE` | (oauth) fichier prouvant le login, ex. `.credentials.json` |
| `HARNESS_HOST_CONFIG_DIR` | config-dir du harness sur l'**hôte** — source d'`agent-import-auth.sh`/`agent-import-config.sh` |
| `HARNESS_HOST_CONFIG_ITEMS` | allowlist d'items de config importés depuis l'hôte (symlinks déréférencés, secrets exclus) |
| `HARNESS_PROVIDERS` | (apikey) providers actifs par défaut, ex. `"anthropic openai"` (catalogue `providers/`) |
| `HARNESS_ENV_KEYS` | (apikey) clés **hors catalogue** à injecter en plus — optionnel |
| `HARNESS_RUN_ENV` | variables d'env additionnelles au run (`KEY=VAL` séparés par espaces) |

---

## Résolution du harness au lancement

Priorité (implémentée dans `lib/profiles.sh` → `profile_resolve`) :

1. **`--profile X`** en argument → override ponctuel (« juste ce coup-ci »).
2. **`--choose` / `--menu`** → force le sélecteur même si un défaut est défini.
3. **`$AGENT_PROFILE`** (dans le shell rc) → lance directement ce harness, sans menu
   (« toujours celui-ci »).
4. Sinon → **sélecteur à choix unique** (↑/↓ déplace, Entrée valide) listant les profils.
   Sans TTY (pipe/CI), fallback en menu numéroté.

Si l'image du harness n'existe pas encore, le launcher la **build automatiquement**
(base + `install.sh`). Si le profil demandé n'existe pas, il propose de **scaffolder**
un squelette pré-rempli.

Pas de mémorisation sur disque du dernier choix : le défaut, c'est `$AGENT_PROFILE`.

```sh
# Défaut « toujours ce harness » + launcher générique
export AGENT_PROFILE=claude
alias agent='~/agent-airlock/bin/agent-sandbox.sh'

agent                    # → claude (défaut)
agent --profile pi       # → pi, ce coup-ci seulement
agent --choose           # → menu interactif
```

---

## Auth : `oauth` vs `apikey`

Le mode est piloté par `HARNESS_AUTH_MODE` (voir aussi
[`authentification.md`](authentification.md)).

- **`oauth`** (ex. `claude`) : login navigateur, credentials persistés dans le volume
  `HARNESS_HOME_VOL`. Le launcher **resynchronise l'horloge de la VM** (une dérive fait
  rejeter le token → logout). Le doctor vérifie la présence de `HARNESS_CREDENTIALS_FILE`.

- **`apikey`** (ex. `pi`, `opencode`) : **pas** de resync horloge (aucun token horodaté).
  Les clés viennent des **providers actifs** (voir section suivante). Injection par
  **passthrough sélectif** : seuls les **noms** de clés des providers actifs (+ ceux de
  `HARNESS_ENV_KEYS`) franchissent la frontière du conteneur (jamais tout l'env de
  l'hôte). Valeur résolue dans l'ordre :
  1. `profiles/<name>/secrets.env` (gitignoré, **prioritaire**) ;
  2. sinon l'env de l'hôte.

  ```sh
  cp profiles/pi/secrets.env.sample profiles/pi/secrets.env
  $EDITOR profiles/pi/secrets.env          # ANTHROPIC_API_KEY=sk-ant-...
  ```

---

## Providers — catalogue découplé (harness apikey)

Un **provider** = une clé d'auth **et** son/ses domaine(s) egress, **couplés** dans un
seul fichier `providers/<name>.env`. Découplé du harness : le même provider sert à `pi`,
`opencode`, etc. — impossible que la clé et le domaine divergent.

```bash
# providers/deepseek.env
PROVIDER_KEYS="DEEPSEEK_API_KEY"
PROVIDER_DOMAINS="api.deepseek.com"
```

**Sélection — sélecteur à cases au lancement (recommandé).** Sur un harness apikey, si
aucun choix n'est encore mémorisé, le launcher affiche un **sélecteur multi-choix** :
↑/↓ pour déplacer, **espace** pour cocher/décocher, **Entrée** pour valider. Ton choix est
**persisté** dans `profiles/<name>/.providers` (gitignoré) : les runs suivants ne
redemandent plus. Pas de commande magique à retenir.

```
Providers — ↑/↓ déplacer, espace cocher, Entrée valider
❯ [x] anthropic
  [ ] deepseek
  [x] github-copilot
  [ ] google
  ...
```

(pré-coché = défaut `HARNESS_PROVIDERS`. Sans TTY — pipe/CI — fallback en menu numéroté.)

**Résolution complète** (priorité) :
`--provider X` (one-shot) > `--choose-providers` (rouvre le menu + persiste) >
`$AGENT_PROVIDERS` (env, one-shot) > choix persisté `.providers` > menu (1ᵉʳ run) >
`HARNESS_PROVIDERS` (défaut du profil).

Pour chaque provider actif, le launcher injecte ses clés **et** ajoute ses domaines à
l'allowlist egress. Le sidecar egress porte un label `agent-airlock.providers=<sig>` →
recréé seulement quand le set change (choix persisté = pas de churn = login stable).

```sh
agent --profile pi                    # sélecteur au 1ᵉʳ run, puis choix mémorisé
agent --profile pi --choose-providers # rouvrir le sélecteur (ajouter / retirer)
agent --profile pi --provider deepseek # forcer deepseek ce coup-ci (sans toucher au choix)
```

**Ajouter ou retirer un provider** : `agent --profile pi --choose-providers`. Le sélecteur
se rouvre avec **ta sélection actuelle déjà cochée** — espace pour cocher un nouveau,
espace pour décocher un existant, Entrée pour valider. Le nouveau choix remplace l'ancien
dans `.providers`. (Pour un provider par abonnement, décocher = fermer ses domaines côté
sandbox ; se déconnecter côté compte = `/logout` dans le harness.)

### Activer DeepSeek (exemple complet)

```sh
# 1. Le provider existe déjà dans le catalogue (providers/deepseek.env). Sinon, le créer.
# 2. Fournir la clé
echo 'DEEPSEEK_API_KEY=sk-...' >> profiles/pi/secrets.env
# 3. L'activer : menu (--choose-providers) ou one-shot
agent --profile pi --choose-providers   # coche deepseek → persisté
# 4. Dans pi, sélectionner le modèle DeepSeek (--provider / modèle par défaut)
```

### GitHub Copilot (abonnement OAuth, PAS de clé)

Copilot est un provider **par abonnement** : pas de clé d'API, mais un login OAuth
(device flow GitHub). Le provider `github-copilot` n'ouvre que les domaines ; le login se
fait **dans pi**.

```sh
# 1. Lancer pi ; au menu providers, cocher github-copilot (numéro) → persisté
agent --profile pi --choose-providers
# 2. DANS pi : /login → GitHub Copilot → Entrée (github.com)
#    pi affiche un CODE + une URL (https://github.com/login/device).
# 3. Sur le NAVIGATEUR de l'hôte : ouvrir l'URL, coller le code, autoriser.
# 4. De retour dans pi : /model → choisir un modèle Copilot.
```

Le token est stocké dans `~/.pi/agent/auth.json` = le volume persistant `agent-home-pi`
→ **le login persiste** d'un run à l'autre (pas de re-login). Le choix `github-copilot`
étant mémorisé (`.providers`), les runs suivants ne redemandent ni le provider ni le
login. Le device flow est poll-based : **aucun port de callback à publier**. Le launcher
resync l'horloge VM (token horodaté, sinon logout immédiat).

> « model not supported » : active le modèle côté GitHub (Copilot Chat → sélecteur de
> modèle → Enable).

### Claude Pro/Max (abonnement OAuth, PAS de clé)

À distinguer du provider `anthropic` (clé `ANTHROPIC_API_KEY`, facturé au token) : le
provider **`claude-pro`** utilise ton abonnement Claude Pro/Max via OAuth. Contrairement au
device flow de Copilot, l'OAuth Anthropic utilise un **callback loopback** (port fixe
`53692`) : le launcher **publie ce port** VM→hôte et fait binder pi sur `0.0.0.0`
(`PI_OAUTH_CALLBACK_HOST`) pour que le navigateur complète le redirect.

```sh
# 1. Activer le provider claude-pro (sélecteur)
agent --profile pi --choose-providers      # cocher claude-pro
# 2. DANS pi : /login → Claude Pro/Max
# 3. Cmd+click (macOS) / Ctrl+click sur l'URL affichée → le navigateur de l'HÔTE s'ouvre
#    → autoriser → le redirect http://localhost:53692 se complète SEUL (port publié).
```

> ⚠️ **Ne copie-colle PAS l'URL** : pi l'affiche comme un **lien cliquable** (OSC 8,
> « Cmd+click to open »). Copiée à la main, l'URL est longue et se coupe au retour à la
> ligne du terminal → il manque `response_type` → erreur « response_type manquant » sur
> claude.ai. **Clique** le lien : l'URL complète s'ouvre, quelle que soit la largeur du
> terminal. (C'est exactement le comportement de Claude Code.)

**Fallbacks** si ton terminal ne gère pas les liens cliquables (OSC 8) :
- **Coller le code** : après autorisation, Anthropic affiche un code — colle-le dans pi
  (il accepte le code OU l'URL de redirect complète).
- **Dernier recours — login hôte + import** (aucune copie d'URL) : `pi` sur l'hôte →
  `/login`, puis `~/agent-airlock/bin/agent-import-auth.sh --profile pi anthropic`.

Le token va dans `~/.pi/agent/auth.json` (volume persistant) ; l'échange de token se fait
vers `platform.claude.com` (ouvert par le provider). Login persistant, resync horloge
comme pour tout provider OAuth.

### Importer sa config hôte dans le sandbox

Tu as une config pi/claude/opencode riche sur ta machine (settings, agents, extensions,
skills, memory…) et tu la retrouves **vierge** dans le sandbox ? C'est voulu : le volume
démarre propre. Pour la seeder, opt-in et one-shot :

```sh
~/agent-airlock/bin/agent-import-config.sh --profile pi            # allowlist du profil
~/agent-airlock/bin/agent-import-config.sh --profile pi --dry-run   # prévisualiser
~/agent-airlock/bin/agent-import-config.sh --profile pi skills settings.json  # sous-ensemble
```

Ce qui est importé = l'allowlist `HARNESS_HOST_CONFIG_ITEMS` du profil (dans
`profile.env`), depuis `HARNESS_HOST_CONFIG_DIR` (ta config hôte). Défauts :

| Profil | Config hôte | Items par défaut |
|---|---|---|
| pi | `~/.pi/agent` | `settings.json models.json agents AGENTS.md extensions skills trust.json pi-memory npm` |
| claude | `~/.claude` | `settings.json CLAUDE.md agents commands` |
| opencode | `~/.config/opencode` | `opencode.json AGENTS.md commands skills` |

Garanties (philosophie sandbox préservée) :

- **Explicite & persistant** : tu le lances quand tu veux, ça persiste dans le volume ;
  tu peux ensuite **diverger** dans le sandbox (pas de re-seed automatique).
- **Symlinks déréférencés** : ta config peut pointer hors du dossier (ex. `../shared`) —
  la copie résout les liens, donc **pas de lien cassé** dans le conteneur.
- **Secrets refusés** : `auth.json`, `.credentials.json`, `mcp-auth`… sont bloqués même
  passés en argument → utilise `agent-import-auth.sh` (qui couple clé ↔ egress).
- **État lourd exclu** : `sessions/`, caches, `.skill-state` ne sont jamais dans
  l'allowlist. (pi : `npm/` EST inclus — c'est le `node_modules` où pi installe les
  packages/deps ; le script crée en plus un symlink `node_modules → npm/node_modules`
  pour que les **extensions locales** résolvent leurs deps (ex. `zod`,
  `@modelcontextprotocol/sdk`) — sans lui, une extension qui `require('zod')` échoue.)
- **Merge non destructif** : seuls les items listés sont écrasés (l'hôte gagne) ; le reste
  du volume (dont ton login) est préservé.

> ⚠️ `settings.json`/`opencode.json` peuvent fixer un `defaultProvider`/`enabledModels`
> dont l'egress n'est pas ouvert dans le sandbox → le modèle échoue (fail-closed). Vérifie
> que les providers actifs couvrent tes modèles par défaut. `mcp.json` n'est **pas** copié
> tel quel (voir § MCP ci-dessous — il se câble sur le sidecar).

### MCP (pi, claude, opencode) — via le sidecar proxy avec OAuth automatique

Tous les harness passent par le même **proxy sidecar** (Node.js).

```sh
# 1. Câble tes serveurs MCP sur le sidecar :
~/agent-airlock/bin/agent-mcp-wire.sh --profile pi              # tous les serveurs distants
#    → génère servers.d-proxy/<nom>.env (NAME/URL/PORT/CALLBACK_PORT)
#    → écrit un mcp.json sandbox dans le volume

# 2. Lance le harness :
agent --profile pi

# 3. Le proxy tente l'OAuth automatique. Si le serveur ne supporte pas la
#    discovery standard (c'est le cas de Jira, Datadog…), il affiche les
#    instructions dans `podman logs mcp-proxy` et attend le token.
#
#    Sur l'hôte (pas dans le sandbox) :
#      pi → /mcp:auth jira → navigateur → autorise
#      agent-import-auth.sh --profile pi --mcp jira
#
#    Le proxy détecte le token automatiquement (poll 5s).
#    Runs suivants : token réutilisé, zéro interaction.
```

Ce que fait le proxy (proxy.js, ~300 lignes) :
- **Token présent** → injection Bearer + forward immédiat.
- **Pas de token** → OAuth discovery (sonde le serveur) + PKCE flow.
  - Si discovery OK → callback publié VM→hôte → URL → token sauvegardé.
  - Si discovery échoue (99% des cas) → instructions dans les logs + poll du
    fichier token toutes les 5s. L'utilisateur importe le token avec
    `agent-import-auth.sh --mcp <serveur>`, le proxy le détecte et démarre.

> 💡 **Premier réflexe en cas d'erreur MCP** : `podman logs mcp-proxy` (pi)
> ou `podman logs mcp-remote` (claude/opencode). Les instructions y sont.

> 🔧 **Claude/opencode** : créer manuellement `servers.d/<nom>.env` (NAME, URL,
> PORT, CALLBACK_PORT) au lieu d'utiliser `agent-mcp-wire.sh`.

### Ajouter un provider au catalogue

Crée `providers/<name>.env` avec ses deux lignes (`PROVIDER_KEYS`, `PROVIDER_DOMAINS`).
Endpoints custom (Azure, gateway locale, base-URL maison) : un `.env` dédié avec le bon
domaine. Providers fournis : anthropic, openai, google, deepseek, openrouter, groq,
mistral, xai (API key) ; github-copilot (abonnement OAuth).

> ⚠️ Responsabilité côté harness : le sandbox ouvre le réseau + injecte la clé, mais tu
> dois **sélectionner le provider correspondant DANS le harness** (pi `--provider`,
> opencode `/models`). Réseau ouvert ≠ provider actif dans l'agent.

---

## Egress : allowlist stricte **par profil**

Le proxy egress est un sidecar partagé, mais **chaque harness a sa propre allowlist**.
Le launcher rend un `squid.conf` runtime = `egress/squid.base.conf` (ports + `deny all`)
avec, injectés au marqueur `@@ALLOWLIST@@` : l'**infra** du profil
(`profiles/<name>/allowlist.conf` — ex. `models.dev`, npm/github) **+ les domaines des
providers actifs** (catalogue). Les domaines providers ne sont donc PAS dans
`allowlist.conf` : ils suivent la sélection `HARNESS_PROVIDERS`/`--provider`.

Le sidecar porte les labels `agent-airlock.profile=<name>` et
`agent-airlock.providers=<sig>`. Au lancement, s'il tourne avec un **autre** profil ou un
**autre set de providers**, il est **recréé** — on ne fusionne jamais les allowlists
(isolation, surface minimale). Détails dans [`allowlist-egress.md`](allowlist-egress.md).

---

## Ajouter un harness — pas à pas

```sh
# 1. Scaffolder (ou copier un profil existant proche)
~/agent-airlock/bin/agent-sandbox.sh --profile monharness   # répond "y" → crée le squelette
#   ↳ édite ensuite profiles/monharness/{profile.env,install.sh,allowlist.conf}

# 2. Build l'image du harness (ou laisse le launcher builder à la volée)
make build-harness PROFILE=monharness

# 3. (apikey) renseigner la clé
cp profiles/monharness/secrets.env.sample profiles/monharness/secrets.env
$EDITOR profiles/monharness/secrets.env

# 4. Vérifier
~/agent-airlock/bin/agent-doctor.sh --profile monharness

# 5. Lancer
~/agent-airlock/bin/agent-sandbox.sh --profile monharness
```

---

## Profils fournis

| Profil | Auth | Config-dir | Install | Notes |
|---|---|---|---|---|
| `claude` | oauth | `~/.claude` | `npm i -g @anthropic-ai/claude-code` | login abonnement ; MCP natif (socat) |
| `pi` | apikey | `~/.pi/agent` | `npm i -g @earendil-works/pi-coding-agent` | provider-agnostic (`HARNESS_PROVIDERS`) ; **pas de MCP natif** (extensions) |
| `opencode` | apikey | `~/.config/opencode` | `npm i -g opencode-ai` | MCP natif (`config.json`) ; sessions non persistées |

### Spécificités

- **pi** : n'a **pas** de MCP intégré (les workflows passent par des extensions), donc le
  tunnel socat du sidecar mcp-remote reste inutilisé sauf extension dédiée. Provider(s)
  via `HARNESS_PROVIDERS` / `--provider` (catalogue `providers/`) ; `allowlist.conf` ne
  contient que l'infra (npm/github si install au runtime).
- **opencode** : récupère la liste des providers/modèles depuis `models.dev` au démarrage
  (domaine déjà présent dans l'allowlist). L'auth passe par l'env (apikey) ; ses
  sessions/état vivent dans `~/.local/share/opencode` — **non persisté** par le volume de
  config (éphémère au run). Le MCP tunnel est câblé via `config/config.json`.
