#!/usr/bin/env bash
# Entrypoint générique du conteneur harness. Ne connaît aucun harness en dur :
# tout arrive par variables d'env (HARNESS_*) injectées par le launcher.
set -euo pipefail

# ─── 0. Seed/refresh de la config distribuée (skills, plugins, mcp…) ──────────
# Le config-dir est un volume persistant (garde les credentials du login).
# On rafraîchit les fichiers "managés" depuis l'image SANS écraser les secrets.
HARNESS_CONFIG_DIR="${HARNESS_CONFIG_DIR:-$HOME/.config/harness}"
mkdir -p "$HARNESS_CONFIG_DIR"
if [ -d /opt/dist/config ]; then
  cp -a /opt/dist/config/. "$HARNESS_CONFIG_DIR/" 2>/dev/null || true
fi

# Certains harness localisent leur config via une variable d'env dédiée
# (ex: CLAUDE_CONFIG_DIR). Le profil la déclare dans HARNESS_CONFIG_ENV.
if [ -n "${HARNESS_CONFIG_ENV:-}" ]; then
  export "${HARNESS_CONFIG_ENV}=${HARNESS_CONFIG_DIR}"
fi

# ─── 1. Outils du repo via mise (node, pnpm… déclarés dans .mise.toml) ─────────
if [ -f /workspace/.mise.toml ] || [ -f /workspace/mise.toml ]; then
  echo "[entrypoint] mise install…"
  mise install || echo "[entrypoint] WARN: mise install partiel"
  eval "$(mise activate bash)" || true
fi

# ─── 2. Neutralisation des git hooks (anti-évasion du sandbox) ────────────────
git config --global core.hooksPath /home/agent/.git-hooks-template || true

# ─── 3. Lancement du harness ──────────────────────────────────────────────────
# shellcheck disable=SC2086  # HARNESS_LAUNCH_ARGS doit se word-splitter.
exec "${HARNESS_BIN:?HARNESS_BIN manquant}" ${HARNESS_LAUNCH_ARGS:-} "$@"
