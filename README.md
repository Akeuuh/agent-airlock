# agent-airlock

Faire tourner **Claude Code** en mode autonome (`--dangerously-skip-permissions`) dans un
sandbox **Podman**, sans exposer la machine à l'exfiltration de secrets ni à la destruction
de données.

> 📐 Modèle de menace + décisions d'archi : [`docs/architecture.md`](docs/architecture.md)
> 📚 Guides & doc technique : [`docs/`](docs/README.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md)

## Sommaire
- [Pourquoi](#pourquoi)
- [Architecture](#architecture)
- [Structure du repo](#structure-du-repo)
- [Prérequis](#prérequis)
- [Installation](#installation)
- [Vérifier la config](#vérifier-la-config)
- [Pour aller plus loin](#pour-aller-plus-loin)
- [TODO / limites connues](#todo--limites-connues)

---

## Pourquoi

Deux hypothèses de travail (détaillées dans le [doc d'archi](docs/architecture.md)) :

1. **Lethal trifecta** (Simon Willison) : un agent qui combine *données privées* +
   *contenu non fiable* (issues, pages web, code non relu) + *canal de sortie* peut être
   détourné par prompt injection pour exfiltrer des données.
2. **Loi de Murphy de l'agent** : on suppose que l'agent finira par causer tous les dégâts
   qu'il est *capable* de causer (injection **ou** simple erreur).

Conséquence : on ne fait pas confiance à l'agent, on l'enferme dans une boîte d'où il ne
peut ni exfiltrer de secrets, ni détruire de données. **Le code, lui, n'est pas une donnée
sensible** (versionné par git) → il est simplement monté en volume.

---

## Architecture

Trois conteneurs, un **réseau interne sans route internet** (`claude-net`). Seuls les
sidecars B et C ont une seconde patte vers internet ; le conteneur Claude n'en a **aucune**.

```mermaid
flowchart TB
    subgraph host["🖥️ Hôte (Mac)"]
        launcher["alias claude<br/>bin/claude-sandbox.sh"]
        code[("~/code/mon-projet")]
        vh[("volume claude-home<br/>🔐 login")]
        vm[("volume claude-mcp-auth<br/>🔐 tokens OAuth")]
    end

    subgraph net["🔒 claude-net · réseau interne (--internal --disable-dns · 10.89.0.0/24)"]
        A["<b>A · claude</b><br/>Claude Code + mise<br/>❌ aucun internet direct"]
        C["<b>C · egress-proxy</b><br/>10.89.0.10<br/>squid + allowlist"]
        B["<b>B · mcp-remote</b><br/>10.89.0.11<br/>OAuth + tokens ICI"]
    end

    anthropic["api.anthropic.com<br/>platform.claude.com<br/>claude.ai"]
    mcpsrv["serveurs MCP<br/>distants"]

    launcher -. "run -it" .-> A
    code -->|bind mount /workspace| A
    vh -. monté dans A .-> A
    vm -. monté dans B seulement .-> B

    A ==>|"HTTP(S)_PROXY"| C
    A ==>|"socat STDIO→TCP :9000"| B
    C -->|allowlist HTTPS| anthropic
    B -->|MCP over HTTP| mcpsrv

    classDef isolated fill:#ffe8e8,stroke:#c00,stroke-width:2px;
    classDef gateway fill:#e8f0ff,stroke:#06c;
    classDef ext fill:#eee,stroke:#999,stroke-dasharray:4 3;
    class A isolated;
    class B,C gateway;
    class anthropic,mcpsrv ext;
```

| # | Conteneur | Rôle | Internet | Secrets |
|---|-----------|------|----------|---------|
| **A** | `claude` | Claude Code + mise. Le code est monté ici. | ❌ direct — **uniquement** via proxy C | aucun |
| **B** | `mcp-remote` | OAuth des MCP + conversion HTTP↔STDIO | ✅ (serveurs MCP) | **tokens OAuth MCP** |
| **C** | `egress-proxy` | Proxy squid, allowlist de sortie | ✅ (allowlist) | — |

Idée centrale : **les credentials ne sont jamais dans le conteneur qui exécute l'agent.**
Claude voit un MCP « local », mais l'OAuth et les tokens vivent dans B, hors de sa portée.

> Détails du câblage → [`docs/reseau.md`](docs/reseau.md) · secrets & login →
> [`docs/authentification.md`](docs/authentification.md) · accès web →
> [`docs/acces-web.md`](docs/acces-web.md).

---

## Structure du repo

```
agent-airlock/
├── bin/
│   ├── claude-sandbox.sh          # launcher (alias `claude`) : pull + réseau + sidecars + run -it
│   └── claude-doctor.sh           # diagnostic complet (infra + isolation + auth)
├── containers/
│   ├── claude/
│   │   ├── Containerfile           # image A : node + Claude Code + mise + socat
│   │   ├── entrypoint.sh           # seed config · mise install · hooks · lance claude
│   │   ├── config/mcp.json         # MCP déclarés (socat → 10.89.0.11:9000)
│   │   └── git-hooks-template/     # hooks neutres (anti-évasion)
│   └── mcp-remote/
│       ├── Containerfile           # image B : node + mcp-remote + socat
│       ├── entrypoint.sh           # 1 socat TCP-LISTEN → mcp-remote par serveur
│       └── servers.d/
│           └── example.env.sample  # modèle de serveur MCP OAuth (copier en <nom>.env)
├── egress/
│   └── squid.conf                  # allowlist de sortie du conteneur A
├── Makefile                        # build/push des images
└── docs/                           # architecture + guides (voir docs/README.md)
```

Réglages centraux (registry, IP, ports, volumes) : en-tête de `bin/claude-sandbox.sh`.

---

## Prérequis

- **macOS** (Apple Silicon testé) — le principe marche aussi sous Linux, sans VM.
- **Homebrew**
- **Podman** (la VM est gérée par `podman machine`)

---

## Installation

```mermaid
flowchart LR
    P["brew install podman<br/>machine init/start"] --> G["git clone"] --> M["make build"] --> AL["alias claude"] --> R["claude<br/>(1er run = login)"]
```

```sh
# 1. Podman + VM (provider Apple natif, aucune dépendance externe)
brew install podman
podman machine init --provider applehv
podman machine start

# 2. Récupérer le repo
git clone <ce-repo> ~/agent-airlock
cd ~/agent-airlock

# 3. Construire les images (tant qu'il n'y a pas de registry d'équipe)
make build

# 4. Alias dans ton shell rc (~/.zshrc)
alias claude='~/agent-airlock/bin/claude-sandbox.sh'
alias claude-doctor='~/agent-airlock/bin/claude-doctor.sh'

# 5. Premier lancement (dans un repo SOUS $HOME, pas /tmp)
cd ~/code/mon-projet
claude          # → login abonnement au 1er run (flow « coller le code »)
```

> 🧑‍🤝‍🧑 Installer sur la machine d'un collègue : guide dédié
> [`docs/onboarding.md`](docs/onboarding.md).

---

## Vérifier la config

```sh
claude-doctor          # ou: ~/agent-airlock/bin/claude-doctor.sh
```

Contrôle en un coup (16 checks) : machine podman, **horloge VM** (dérive → logout OAuth), images, réseau `internal=true dns=false`,
sidecars, **blocage internet direct**, **allowlist egress** (anthropic/claude.ai/platform
autorisés, reste refusé), tunnel MCP, et **persistance du login**.

Depuis une session Claude en cours : `/status` (compte, modèle), `/mcp` (serveurs MCP),
`/doctor` (santé interne).

---

## Pour aller plus loin

| Doc | Contenu |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Modèle de menace, décisions de design |
| [`docs/reseau.md`](docs/reseau.md) | Réseau interne, DNS, IP statiques, tunnel MCP socat |
| [`docs/acces-web.md`](docs/acces-web.md) | WebSearch / WebFetch / MCP : ce que Claude peut fetcher |
| [`docs/authentification.md`](docs/authentification.md) | Login abonnement, resync horloge, volumes |
| [`docs/ajouter-un-mcp.md`](docs/ajouter-un-mcp.md) | Brancher un serveur MCP |
| [`docs/ajouter-un-skill.md`](docs/ajouter-un-skill.md) | Ajouter un skill commun |
| [`docs/ajouter-une-commande.md`](docs/ajouter-une-commande.md) | Slash-commands & plugins |
| [`docs/allowlist-egress.md`](docs/allowlist-egress.md) | Autoriser un domaine de sortie |
| [`docs/build-et-images.md`](docs/build-et-images.md) | Build, images, registry d'équipe |
| [`docs/onboarding.md`](docs/onboarding.md) | Installer sur une nouvelle machine |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Dépannage |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Workflow, conventions, checklist PR |

---

## TODO / limites connues

- **Registry d'équipe** : pousser l'image commune (`make push`) pour éviter le `make build`
  local chez chaque collègue et distribuer skills/plugins à jour automatiquement.
- **Enregistrement MCP côté Claude** : `mcp.json` est embarqué mais pas encore enregistré au
  bon endroit (`claude mcp add --scope user` à l'entrypoint) + un vrai serveur dans
  `servers.d/`.
- **`mise install` × egress** : ajouter les registries (npm, mise, github) à l'allowlist si
  installation d'outils au runtime.
- **Audit trail MCP** : viser une MCP gateway centralisée (réponse à incident).
- **Skills/plugins communs** : dossiers à peupler dans l'image (`/opt/claude-dist`).
- **Utilisateurs non-ingénieurs** : le flux (podman, clone, build) reste trop technique.

---

## Licence

[MIT](LICENSE) — © 2026 Axel Leclercq. Fais-en ce que tu veux, garde la mention de copyright,
aucune garantie.
