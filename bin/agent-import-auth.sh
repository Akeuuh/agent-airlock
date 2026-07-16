#!/usr/bin/env bash
#
# agent-import-auth — importe un login (auth.json) fait côté HÔTE vers le volume
# persistant du sandbox, pour un ou plusieurs providers/clés donnés.
#
# Cas d'usage : certains providers par abonnement (ex. Claude Pro/Max) utilisent
# un OAuth loopback pénible à compléter depuis le TUI du conteneur (copie d'URL
# tronquée). On se logue alors sur le harness côté hôte (navigateur + localhost
# natifs), puis on importe UNIQUEMENT l'entrée voulue — pas tout l'auth hôte.
#
# Usage :
#   agent-import-auth.sh [--profile <name>] <clé> [<clé>...]
#   ex : agent-import-auth.sh --profile pi anthropic
#
#   agent-import-auth.sh [--profile <name>] --mcp [<serveur>...]
#   ex : agent-import-auth.sh --profile pi --mcp jira
#   (Fallback si l'OAuth automatique du proxy échoue. Normalement le proxy.js
#    fait l'OAuth tout seul — tu n'as pas besoin de cette commande.)
#
# NB : merge non destructif (préserve les autres entrées du volume).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/profiles.sh
. "$REPO_DIR/lib/profiles.sh"

log() { printf '\033[1;34m[import-auth]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[import-auth]\033[0m %s\n' "$*" >&2; exit 1; }

ARG_PROFILE=""
KEYS=""
MCP_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) ARG_PROFILE="${2:-}"; shift 2 ;;
    --profile=*) ARG_PROFILE="${1#*=}"; shift ;;
    --mcp) MCP_MODE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) KEYS="$KEYS $1"; shift ;;
  esac
done
KEYS="$(echo "$KEYS" | xargs)"

PROFILE_NAME="$(profile_resolve "$ARG_PROFILE" 0)"
profile_exists "$PROFILE_NAME" || die "profil inconnu: $PROFILE_NAME"
profile_load "$PROFILE_NAME"

REGISTRY="${AGENT_SANDBOX_REGISTRY:-localhost}"
AGENT_IMAGE="${REGISTRY}/agent-${PROFILE_NAME}:latest"
CREDS="${HARNESS_CREDENTIALS_FILE:-auth.json}"
HOST_DIR="${HARNESS_HOST_CONFIG_DIR:-}"

[ -n "$HOST_DIR" ] || die "HARNESS_HOST_CONFIG_DIR non défini pour le profil $PROFILE_NAME (import non supporté)"
podman image exists "$AGENT_IMAGE" || die "image $AGENT_IMAGE absente (lance le harness une fois)"

# ─── Mode MCP : import du token OAuth hôte → volume sidecar proxy ─────────
if [ "$MCP_MODE" -eq 1 ]; then
  HOST_MCP="$HOST_DIR/mcp-auth"
  [ -d "$HOST_MCP" ] || die "pas de mcp-auth côté hôte ($HOST_MCP) — logue-toi via /mcp:auth <serveur> sur l'HÔTE d'abord"
  [ -n "$KEYS" ] || die "précise au moins un nom de serveur (ex: --mcp jira)"
  log "profil $PROFILE_NAME : import tokens MCP [$KEYS] depuis $HOST_MCP → volume agent-mcp-auth"
  # Extrait access_token du JSON (sha256 du nom = hash de 16 hex) et l'écrit
  # dans agent-mcp-auth:/home/node/.mcp-auth/<name>.token (lu par le proxy).
  MCP_VOL="${MCP_AUTH_VOL:-agent-mcp-auth}"
  for name in $KEYS; do
    hash="$(printf '%s' "$name" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-16)"
    tok_file="$HOST_MCP/${hash}.json"
    [ -f "$tok_file" ] || { log "  ✗ $name : pas de token côté hôte (cherché $tok_file)"; continue; }
    access_token="$(node -e "try{console.log(require(process.argv[1]).tokens.access_token)}catch(e){}" "$tok_file" 2>/dev/null)"
    [ -n "$access_token" ] || { log "  ✗ $name : token absent ou expiré"; continue; }
    # Écrit dans le volume sidecar via un conteneur temporaire
    printf '%s' "$access_token" | podman run --rm -i -v "${MCP_VOL}:/d:z" --entrypoint "" "$AGENT_IMAGE" sh -c "cat > /d/${name}.token && chmod 644 /d/${name}.token" 2>/dev/null
    log "  ✓ $name → volume $MCP_VOL ($(wc -c < "$tok_file" | tr -d ' ') → ${name}.token)"
  done
  log "fait. Lance le harness — le proxy sidecar injectera le token automatiquement."
  exit 0
fi

[ -n "$KEYS" ] || die "précise au moins une clé à importer (ex: anthropic) ou --mcp <serveur>"
[ -f "$HOST_DIR/$CREDS" ] || die "pas de $CREDS côté hôte ($HOST_DIR) — logue-toi d'abord sur le harness côté hôte"

log "profil $PROFILE_NAME : import de [$KEYS] depuis $HOST_DIR/$CREDS → volume $HARNESS_HOME_VOL"

# Merge dans un conteneur : node lit /host/$CREDS et /vol/$CREDS, copie les clés
# demandées, réécrit /vol/$CREDS, puis chown vers l'uid agent (écriture par pi ok).
podman run --rm \
  -e CREDS="$CREDS" -e KEYS="$KEYS" \
  -v "${HARNESS_HOME_VOL}:/vol:Z" \
  -v "${HOST_DIR}:/host:ro,Z" \
  --entrypoint "" "$AGENT_IMAGE" bash -c '
    node -e "
      const fs=require(\"fs\");
      const creds=process.env.CREDS;
      const keys=(process.env.KEYS||\"\").split(/\s+/).filter(Boolean);
      const host=JSON.parse(fs.readFileSync(\"/host/\"+creds,\"utf8\"));
      let vol={}; try{vol=JSON.parse(fs.readFileSync(\"/vol/\"+creds,\"utf8\"))}catch(e){}
      const done=[],miss=[];
      for(const k of keys){ if(host[k]!==undefined){vol[k]=host[k];done.push(k);} else miss.push(k); }
      fs.writeFileSync(\"/vol/\"+creds, JSON.stringify(vol,null,2));
      if(miss.length) console.error(\"absent cote hote: \"+miss.join(\", \"));
      console.log(\"importe: \"+(done.join(\", \")||\"(rien)\"));
    " && chown "$(id -u agent):$(id -g agent)" "/vol/$CREDS"
  '

log "fait. Sélectionne le provider correspondant au lancement (ex: --provider claude-pro pour l'egress)."
