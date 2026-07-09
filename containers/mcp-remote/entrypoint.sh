#!/usr/bin/env bash
# Entrypoint du conteneur B (mcp-remote). Pour chaque serveur MCP déclaré dans
# /servers.d/*.env, ouvre un socat TCP-LISTEN qui exec mcp-remote à la connexion.
set -euo pipefail
shopt -s nullglob

pids=()
for f in /servers.d/*.env; do
  # shellcheck disable=SC1090
  ( set -a; source "$f" )   # validation isolée
  # shellcheck disable=SC1090
  source "$f"
  : "${NAME:?NAME manquant dans $f}"
  : "${URL:?URL manquant dans $f}"
  : "${PORT:?PORT manquant dans $f}"

  args="mcp-remote $URL"
  [ -n "${CALLBACK_PORT:-}" ] && args="$args --callback-port $CALLBACK_PORT"
  # TODO: vérifier le flag exact de filtrage d'outils selon la version de mcp-remote
  [ -n "${ALLOWED_TOOLS:-}" ] && args="$args --allow-tools $ALLOWED_TOOLS"

  echo "[mcp-remote] $NAME : TCP:$PORT → $URL"
  # fork = une instance mcp-remote par connexion ; le token OAuth est mis en cache disque.
  socat TCP-LISTEN:"$PORT",reuseaddr,fork EXEC:"$args" &
  pids+=($!)

  unset NAME URL PORT CALLBACK_PORT ALLOWED_TOOLS
done

if [ ${#pids[@]} -eq 0 ]; then
  echo "[mcp-remote] aucun serveur dans /servers.d — conteneur idle"
  exec sleep infinity
fi

wait -n
