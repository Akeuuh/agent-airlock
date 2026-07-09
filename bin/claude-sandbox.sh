#!/usr/bin/env bash
#
# claude-sandbox — lance Claude Code dans un sandbox Podman.
# Usage : alias claude='~/Dev/IA/claude-isolation/bin/claude-sandbox.sh'
#
# Étapes : pull image à jour → réseau interne → sidecars (mcp-remote, egress) → run -it.
# Voir docs/architecture.md pour le pourquoi de chaque brique.

set -euo pipefail

# Racine du repo (robuste aux symlinks) — le script retrouve ses fichiers voisins.
SCRIPT_PATH="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_PATH/.." && pwd)"

# ─── Config (surchargée par l'environnement) ──────────────────────────────────
REGISTRY="${CLAUDE_SANDBOX_REGISTRY:-localhost}"          # TODO: registry d'équipe réel
CLAUDE_IMAGE="${CLAUDE_SANDBOX_IMAGE:-${REGISTRY}/claude-sandbox:latest}"
MCP_IMAGE="${MCP_REMOTE_IMAGE:-${REGISTRY}/mcp-remote:latest}"
EGRESS_IMAGE="${EGRESS_IMAGE:-${REGISTRY}/egress-proxy:latest}"

NET="claude-net"                 # réseau INTERNE (pas de route internet, DNS désactivé)
NET_EXT="podman"                 # réseau par défaut (internet) pour les sidecars
SUBNET="10.89.0.0/24"
EGRESS_IP="10.89.0.10"           # IP statique du proxy sur claude-net (pas de DNS interne)
MCP_IP="10.89.0.11"              # IP statique du sidecar mcp-remote sur claude-net
MCP_CTR="mcp-remote"
EGRESS_CTR="egress-proxy"
PROXY_PORT=3128
OAUTH_CALLBACK_PORT="${OAUTH_CALLBACK_PORT:-9910}"   # publié VM→hôte pour le flow OAuth
MCP_AUTH_VOL="claude-mcp-auth"   # volume des tokens OAuth — monté SEULEMENT dans B
CLAUDE_HOME_VOL="claude-home"    # volume ~/.claude — persiste le login abonnement

log() { printf '\033[1;34m[claude-sandbox]\033[0m %s\n' "$*" >&2; }

# ─── 1. Images à jour ─────────────────────────────────────────────────────────
log "pull des images…"
podman pull -q "$CLAUDE_IMAGE" >/dev/null 2>&1 || log "WARN: pull claude KO (offline ?), on garde le cache local"

# ─── 1b. Resync horloge VM (macOS) ───────────────────────────────────────────
# podman machine dérive après une veille du Mac (System clock synchronized: no).
# Une horloge décalée fait rejeter le token OAuth fraîchement émis (iat dans le
# futur) → logout immédiat de Claude. On recale la VM sur l'heure de l'hôte.
podman machine ssh "sudo date -u -s '@$(date -u +%s)'" >/dev/null 2>&1 \
  && log "horloge VM resynchronisée" || true

# ─── 2. Réseau interne ────────────────────────────────────────────────────────
# --internal    = aucune route vers internet (Claude ne peut pas exfiltrer en direct).
# --disable-dns = pas d'aardvark interne (sinon il pollue le resolv.conf des sidecars
#                 multi-homed et casse leur résolution DNS externe). On adresse donc
#                 les sidecars par IP statique ; Claude n'a jamais besoin de DNS externe
#                 (c'est le proxy qui résout les domaines via le CONNECT).
podman network exists "$NET" || {
  log "création du réseau interne $NET (sans DNS, subnet $SUBNET)"
  podman network create --internal --disable-dns --subnet "$SUBNET" "$NET" >/dev/null
}

# ─── 3. Sidecars long-lived ───────────────────────────────────────────────────
running() { [ "$(podman container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

ensure_egress() {
  running "$EGRESS_CTR" && return 0
  podman rm -f "$EGRESS_CTR" >/dev/null 2>&1 || true
  log "démarrage du proxy egress ($EGRESS_CTR)"
  # Réseau externe PRIMAIRE (internet + DNS OK), puis claude-net en IP statique.
  podman run -d --name "$EGRESS_CTR" \
    --network "$NET_EXT" \
    -v "$REPO_DIR/egress/squid.conf:/etc/squid/squid.conf:ro,Z" \
    "$EGRESS_IMAGE" >/dev/null
  podman network connect --ip "$EGRESS_IP" "$NET" "$EGRESS_CTR" >/dev/null
}

ensure_mcp() {
  running "$MCP_CTR" && return 0
  podman rm -f "$MCP_CTR" >/dev/null 2>&1 || true
  log "démarrage du sidecar mcp-remote ($MCP_CTR)"
  # Callback OAuth publié sur l'hôte ; volume des tokens ISOLÉ ici (jamais dans A).
  podman run -d --name "$MCP_CTR" \
    --network "$NET_EXT" \
    -p "127.0.0.1:${OAUTH_CALLBACK_PORT}:${OAUTH_CALLBACK_PORT}" \
    -v "${MCP_AUTH_VOL}:/home/node/.mcp-auth:Z" \
    -v "$REPO_DIR/containers/mcp-remote/servers.d:/servers.d:ro,Z" \
    "$MCP_IMAGE" >/dev/null
  podman network connect --ip "$MCP_IP" "$NET" "$MCP_CTR" >/dev/null
}

ensure_egress
ensure_mcp

# ─── 4. Détection git worktree ────────────────────────────────────────────────
# Un worktree a un `.git` FICHIER pointant vers le git-common-dir du repo parent.
declare -a GIT_MOUNTS=()
if [ -f .git ]; then
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common_dir" ]; then
    common_abs="$(cd "$common_dir" && pwd)"
    log "worktree détecté → montage du git-common-dir : $common_abs"
    GIT_MOUNTS+=(-v "${common_abs}:${common_abs}:Z")   # rw : les commits écrivent les objets ici
  fi
fi

# ─── 5. Run Claude (interactif, reste dans le terminal) ───────────────────────
exec podman run -it --rm \
  --network "$NET" \
  --hostname claude-sandbox \
  -v "$PWD:/workspace:Z" \
  -v "${CLAUDE_HOME_VOL}:/home/claude/.claude:Z" \
  "${GIT_MOUNTS[@]}" \
  -w /workspace \
  -e HTTP_PROXY="http://${EGRESS_IP}:${PROXY_PORT}" \
  -e HTTPS_PROXY="http://${EGRESS_IP}:${PROXY_PORT}" \
  -e NO_PROXY="${MCP_IP},localhost,127.0.0.1" \
  -e DISABLE_TELEMETRY=1 \
  -e DISABLE_ERROR_REPORTING=1 \
  "$CLAUDE_IMAGE" "$@"
