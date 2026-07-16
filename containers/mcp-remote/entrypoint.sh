#!/usr/bin/env bash
# Entrypoint du sidecar proxy MCP. Pour chaque serveur déclaré dans
# /servers.d/*.env, démarre un proxy HTTP qui forwarde les requêtes vers
# le serveur MCP distant.
#
# Deux modes (proxy.js gère la transition automatiquement) :
#   - Token présent → injection Bearer + forward immédiat.
#   - Pas de token  → OAuth discovery + PKCE flow → sauvegarde → forward.
#
# Format servers.d/<nom>.env :
#   NAME=<nom>              identifiant du serveur
#   URL=<url>               endpoint MCP streamable-http distant
#   PORT=<port>             port d'écoute du proxy sur le réseau interne
#   CALLBACK_PORT=<port>    (optionnel) port de callback OAuth, publié VM→hôte
set -euo pipefail
shopt -s nullglob

MCP_AUTH_DIR="${MCP_AUTH_DIR:-/home/node/.mcp-auth}"
pids=()

for f in /servers.d/*.env; do
  # shellcheck disable=SC1090
  source "$f"
  : "${NAME:?NAME manquant dans $f}"
  : "${URL:?URL manquant dans $f}"
  : "${PORT:?PORT manquant dans $f}"

  TOKEN_FILE="$MCP_AUTH_DIR/${NAME}.token"
  CB_PORT="${CALLBACK_PORT:-}"

  if [ -n "$CB_PORT" ]; then
    node /usr/local/bin/proxy.js "$URL" "$TOKEN_FILE" "$PORT" "$CB_PORT" &
  else
    node /usr/local/bin/proxy.js "$URL" "$TOKEN_FILE" "$PORT" &
  fi
  pids+=($!)
  echo "[airlock-proxy] $NAME : 0.0.0.0:$PORT → $URL"

  unset NAME URL PORT CALLBACK_PORT TOKEN_FILE CB_PORT
done

if [ ${#pids[@]} -eq 0 ]; then
  echo "[airlock-proxy] aucun serveur dans /servers.d — conteneur idle"
  exec sleep infinity
fi

wait -n || true  # un proxy peut s'arrêter (OAuth timeout) — ne pas tuer le conteneur
