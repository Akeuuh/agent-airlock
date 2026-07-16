# Plan d'action — `agent-airlock` full agnostic (multi-harness)

> Objectif : rendre le sandbox compatible avec plusieurs harness (claude, pi, opencode, hermes…).
> UX cible : au lancement, le script **demande quel harness** on veut ; s'il n'est pas encore
> défini/installé, on le **build automatiquement**.
> Branche : `feat/multi-harness-agnostic`.

## Principe directeur

Introduire une notion de **profil** (un par harness). Tout ce qui est spécifique à Claude sort
du code et migre dans un profil. Le launcher devient générique : il demande le harness, charge
le profil, build l'image si absente, puis lance.

## Cible : nouvelle arborescence

```
profiles/
  claude/
    profile.env         # toutes les variables du harness
    install.sh          # comment installer le binaire dans l'image
    allowlist.conf      # fragment squid (domaines du provider)
    mcp.json            # config MCP au format du harness
  pi/       { profile.env, install.sh, allowlist.conf, mcp.json }
  opencode/ { … }
containers/
  base/Containerfile    # node + socat + git + mise + user  (SANS harness)
  mcp-remote/           # ← inchangé
egress/
  squid.base.conf       # ports + règles deny + footer (sans domaines)
bin/
  agent-sandbox.sh      # launcher générique (ex claude-sandbox.sh)
  agent-doctor.sh       # doctor générique
lib/
  profiles.sh           # helpers: list / select / load / ensure-image
```

`profile.env` type :
```bash
HARNESS_NAME="claude"
HARNESS_BIN="claude"
HARNESS_LAUNCH_ARGS="--dangerously-skip-permissions"
HARNESS_CONFIG_DIR="/home/agent/.claude"
HARNESS_HOME_VOL="agent-home-claude"
HARNESS_AUTH_MODE="oauth"            # oauth | apikey
HARNESS_CREDENTIALS_FILE=".credentials.json"
# pi ->   HARNESS_AUTH_MODE="apikey", HARNESS_ENV_KEYS="ANTHROPIC_API_KEY OPENAI_API_KEY"
```

## Phase 0 — Généralisation des noms (préparatoire) ✅ FAIT

Sans changer le comportement, découpler du mot « claude » :
- `claude-net` → `agent-net`, `claude-home` → volume par profil.
- `claude-sandbox.sh` → `agent-sandbox.sh` (+ alias `claude` = `agent-sandbox.sh --profile claude`).
- `Makefile` : cible `build-base` + cible générique `build-harness PROFILE=…`.

Fichiers : launcher, doctor, Makefile, docs. Effort : faible.

## Phase 1 — Système de profils + `lib/profiles.sh` ✅ FAIT

Helpers réutilisés par launcher et doctor :
- `profiles_list` → liste `profiles/*/profile.env`.
- `profile_load <name>` → source les variables.
- `profile_select` → menu interactif (`select` bash) si aucun profil passé en arg/env.
- `ensure_image <profile>` → `podman image exists` ? sinon build auto (base + `install.sh`).

Résolution du harness au lancement (l'UX voulue) :
1. `--profile X` en argument → gagne toujours (override ponctuel one-shot), sinon
2. `--choose` / `--menu` → force le menu interactif même si `$AGENT_PROFILE` est défini (déviation ponctuelle), sinon
3. `$AGENT_PROFILE` défini (dans le shell rc) → lance directement ce harness, sans menu (« toujours celui-ci »), sinon
4. menu interactif listant les profils disponibles.
5. Image absente → message « harness pas encore construit, build en cours… » puis `podman build` auto.
6. Profil inexistant pour un harness demandé → propose un scaffold `profiles/<name>/` pré-rempli.

Effort : moyen (cœur du chantier).

## Phase 2 — Containerfile paramétré ✅ FAIT

- `containers/base/Containerfile` : node + socat + git + curl + mise + user `agent` (le commun). Aucun harness.
- Le build harness part de l'image base et exécute `profiles/<name>/install.sh` :
  ```dockerfile
  ARG BASE_IMAGE
  FROM ${BASE_IMAGE}
  COPY install.sh /tmp/install.sh
  RUN /tmp/install.sh
  ```
  - claude/install.sh → `npm install -g @anthropic-ai/claude-code`
  - pi/install.sh → sa commande d'install
  - opencode/install.sh → la sienne

Effort : faible-moyen.

## Phase 3 — Entrypoint générique ✅ FAIT

`entrypoint.sh` ne connaît plus « claude ». Reçoit par env :
- seed config depuis `/opt/dist` vers `$HARNESS_CONFIG_DIR`
- `mise install` (inchangé)
- neutralisation hooks git (inchangé)
- `exec "$HARNESS_BIN" $HARNESS_LAUNCH_ARGS "$@"`

Effort : faible.

## Phase 4 — Egress allowlist par profil (⚠️ point sécu clé) ✅ FAIT

Le proxy egress est un sidecar partagé, mais chaque harness a une allowlist différente.
Stratégie recommandée : allowlist stricte par profil, sidecar recréé au changement de harness.

- `egress/squid.base.conf` : ports, `CONNECT`, footer `http_access deny all`.
- Launcher génère un `squid.conf` runtime = `squid.base.conf` + `profiles/<name>/allowlist.conf`, monté dans le sidecar.
- Le conteneur egress porte un label `agent-airlock.profile=<name>`. Au lancement : si le label ≠ profil courant → recréer le sidecar avec la bonne allowlist. Sinon le garder.

→ On évite de fusionner toutes les allowlists (surface élargie, isolation affaiblie).

Effort : moyen.

## Phase 5 — Auth conditionnelle ✅ FAIT

Branché sur `HARNESS_AUTH_MODE` :
- oauth (claude) : resync horloge VM + volume home persistant + check `.credentials.json`.
- apikey (pi, opencode…) : pas de resync horloge ; injection des clés via allowlist d'env
  (`HARNESS_ENV_KEYS`, passthrough sélectif depuis l'hôte — surtout PAS tout `env`), volume config optionnel.

À cadrer : d'où viennent les clés API (env hôte vs fichier secrets chiffré). Décision sécu.

Effort : moyen.

## Phase 6 — Doctor générique ✅ FAIT

`agent-doctor.sh --profile X` : mêmes 8 checks, image/domaines/credentials/auth tirés du
profil. Skip du check horloge si `apikey`. Boucle allowlist sur
`profiles/<name>/allowlist.conf`. ✅ **LIVRÉ** : doctor entièrement profile-driven,
section 8 branche oauth (credentials) / apikey (résolution des clés). Validé sur `pi` →
13 OK / 0 KO (horloge sautée, allowlist pi, clé résolue).

## Phase 7 — Docs + profils de démarrage ✅ FAIT

- Livrer 3 profils : `claude` (iso-comportement), `pi`, `opencode`. ✅ **LIVRÉ**
  (`pi` v0.80.6 et `opencode` buildés/validés ; auth apikey).
- Doc « ajouter un harness » (créer un profil = 4-5 fichiers). ✅ `docs/profils.md`.
- MAJ `architecture.md` (section 4bis) + README (arbo + table) + `docs/README.md`.
- Durcissement : `containers/harness/Containerfile` lance `install.sh` via `bash`
  (indépendant du bit exécutable).

## Ordre de livraison conseillé

1. Phase 0 + 1 + 2 + 3 avec le seul profil `claude` → comportement identique à aujourd'hui,
   sur le nouveau socle générique. Jalon de non-régression. ✅ **LIVRÉ** (branche `feat/multi-harness-agnostic`) :
   agent-doctor → 17 OK / 0 KO ; volumes `claude-home`/`claude-mcp-auth` migrés vers
   `agent-home-claude`/`agent-mcp-auth` (pas de re-login). Anciens volumes conservés en backup.
2. Phase 4 + 5 → egress par profil + auth conditionnelle. ✅ **LIVRÉ** (jalon 2) :
   egress rendu par profil (`egress/squid.base.conf` + `profiles/<name>/allowlist.conf`,
   marqueur `@@ALLOWLIST@@`), sidecar labellisé `agent-airlock.profile=<name>` recréé au
   switch, fail-closed propre si allowlist vide (acl bidon dans le socle). Auth pilotée par
   `HARNESS_AUTH_MODE` : resync horloge sauté en apikey ; injection sélective des clés
   (`HARNESS_ENV_KEYS`, valeur `secrets.env` prioritaire puis env hôte). Doctor → 17 OK / 0 KO.
3. Ajout du profil `pi` en premier harness de validation (auth apikey → exerce le chemin non-Claude). ✅ **LIVRÉ** (jalon 3).
4. Phase 6 + 7 → doctor + docs + profil `opencode`. ✅ **LIVRÉ** (jalon 3) : doctor
   entièrement profile-driven ; profils `pi` + `opencode` buildés/validés ;
   `docs/profils.md` (guide multi-harness) ; MAJ archi/README/index.

## Décisions à trancher avant de coder

1. Egress : strict par profil (recréation du sidecar) [recommandé] ou fusion des allowlists (plus simple, moins sûr) ? → **TRANCHÉ : strict par profil** (label `agent-airlock.profile=<name>`, sidecar recréé au switch).
2. Clés API (harness non-OAuth) : passthrough sélectif depuis l'env hôte, ou fichier secrets dédié ? → **TRANCHÉ : les deux** — fichier `profiles/<name>/secrets.env` (gitignoré) prioritaire, fallback sur env hôte sélectif via `HARNESS_ENV_KEYS`.
3. Modèles locaux (pi + ollama) : hors scope v1, ou chemin egress vers l'hôte dès maintenant ? → **TRANCHÉ : hors scope v1** (providers SaaS uniquement pour l'instant).
4. Persistance du choix : mémoriser le dernier harness comme défaut, ou toujours redemander ? → **TRANCHÉ : défaut piloté par `$AGENT_PROFILE`** (mis dans le shell rc = « toujours celui-ci ») ; `--profile X` override one-shot ; `--choose`/`--menu` force le menu ; sinon menu interactif. Pas de mémorisation sur disque.
