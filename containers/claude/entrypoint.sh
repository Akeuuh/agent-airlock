#!/usr/bin/env bash
# Entrypoint du conteneur A (Claude). Prépare les outils du repo puis lance Claude.
set -euo pipefail

# ─── 0. Seed/refresh de la config distribuée (skills, plugins, mcp) ──────────────
# ~/.claude est un volume persistant (garde les credentials du login abonnement).
# On rafraîchit les fichiers "managés" depuis l'image SANS toucher à .credentials.json.
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_CONFIG_DIR"
if [ -d /opt/claude-dist/config ]; then
  cp -a /opt/claude-dist/config/. "$CLAUDE_CONFIG_DIR/" 2>/dev/null || true
fi

# ─── 1. Outils du repo via mise (node, pnpm… déclarés dans .mise.toml) ─────────
if [ -f /workspace/.mise.toml ] || [ -f /workspace/mise.toml ]; then
  echo "[entrypoint] mise install…"
  mise install || echo "[entrypoint] WARN: mise install partiel"
  eval "$(mise activate bash)" || true
fi

# ─── 2. Neutralisation des git hooks (anti-évasion du sandbox) ────────────────
# Les hooks modifiés par l'agent pointent vers un template éphémère, non persisté.
git config --global core.hooksPath /home/claude/.git-hooks-template || true

# ─── 3. Lancement de Claude en mode autonome ──────────────────────────────────
exec claude --dangerously-skip-permissions "$@"
