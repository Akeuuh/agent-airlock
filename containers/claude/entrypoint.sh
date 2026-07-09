#!/usr/bin/env bash
# Entrypoint du conteneur A (Claude). Prépare les outils du repo puis lance Claude.
set -euo pipefail

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
