# claude-isolation

Faire tourner **Claude Code** en mode autonome (`--dangerously-skip-permissions`) dans un
sandbox Podman, sans exposer la machine à l'exfiltration de secrets ou à la destruction de
données.

> 📐 Architecture détaillée + modèle de menace : [`docs/architecture.md`](docs/architecture.md)

## Principe

Trois conteneurs sur un **réseau interne** (`claude-net`, sans route internet) :

| # | Conteneur | Rôle | Internet |
|---|-----------|------|----------|
| A | `claude` | Claude Code + skills + mise. Le code est monté ici. | via proxy egress uniquement |
| B | `mcp-remote` | OAuth des MCP + conversion HTTP↔STDIO. **Les tokens vivent ici.** | oui (serveurs MCP) |
| C | `egress-proxy` | Allowlist de sortie (api.anthropic.com…) | oui (allowlist) |

Claude parle aux MCP via un tunnel `socat` (STDIO→TCP→STDIO) vers le conteneur B : il ne
voit jamais les credentials OAuth. Sa seule sortie internet passe par le proxy C.

## Structure

```
claude-isolation/
├── bin/
│   └── claude-sandbox.sh          # launcher (alias `claude`) : pull + sidecars + run -it
├── containers/
│   ├── claude/
│   │   ├── Containerfile           # image A : Claude Code + mise + socat
│   │   ├── entrypoint.sh           # mise install (outils du repo) puis lance claude
│   │   ├── config/mcp.json         # MCP déclarés → socat vers mcp-remote:PORT
│   │   ├── skills/ , plugins/      # marketplace commune embarquée dans l'image
│   │   └── git-hooks-template/     # hooks neutres montés read-only (anti-évasion)
│   └── mcp-remote/
│       ├── Containerfile           # image B : node + mcp-remote + socat
│       ├── entrypoint.sh           # 1 socat TCP-LISTEN→mcp-remote par MCP
│       └── servers.d/*.example.env # 1 fichier par serveur MCP OAuth (url, port, tools)
├── egress/
│   └── squid.conf                  # allowlist de sortie du conteneur A
└── docs/architecture.md
```

## Installation (cible)

```sh
git clone <ce-repo> ~/Dev/IA/claude-isolation
# alias dans ton shell rc :
alias claude='~/Dev/IA/claude-isolation/bin/claude-sandbox.sh'
```

Puis, dans n'importe quel projet :

```sh
cd ~/code/mon-projet
claude          # pull l'image à jour, monte le code, lance Claude sandboxé
```

## Statut

🚧 Scaffold initial. Les fichiers sont des **squelettes** ; les points marqués `TODO`
restent à trancher (voir §7 de l'architecture) :

- liste blanche exacte du proxy egress ;
- publication du port de callback OAuth (spécifique macOS) ;
- audit trail MCP (MCP gateway) ;
- cas des utilisateurs non-ingénieurs.
