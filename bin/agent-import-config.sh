#!/usr/bin/env bash
#
# agent-import-config — seed la CONFIG du harness depuis l'HÔTE vers le volume
# persistant du sandbox (settings, agents, extensions, skills, memory…).
#
# Complément d'agent-import-auth.sh : celui-ci importe la config « pure » (pas
# les credentials). L'idée : tu as une config pi/claude/opencode riche sur ta
# machine, tu veux la retrouver dans le sandbox sans repartir de zéro.
#
# Philosophie sandbox préservée :
#   - opt-in, explicite, one-shot (persiste ensuite dans le volume) ;
#   - allowlist d'items par profil (HARNESS_HOST_CONFIG_ITEMS) — rien d'autre
#     ne franchit ;
#   - symlinks DÉRÉFÉRENCÉS à la copie (ta config peut pointer ../shared) ;
#   - SECRETS refusés (auth.json, .credentials.json, mcp-auth…) → passe par
#     agent-import-auth.sh, qui couple clé ↔ egress ;
#   - état lourd / spécifique workspace exclu (sessions, caches, node_modules).
#
# Usage :
#   agent-import-config.sh [--profile <name>] [--dry-run] [item...]
#   ex : agent-import-config.sh --profile pi
#        agent-import-config.sh --profile pi settings.json skills   # sous-ensemble
#        agent-import-config.sh --profile pi mcp.json               # opt-in explicite
#
# Sans item : utilise l'allowlist HARNESS_HOST_CONFIG_ITEMS du profil.
# Les items listés ÉCRASENT leur homologue dans le volume (l'hôte gagne) ; le
# reste du volume est préservé.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/profiles.sh
. "$REPO_DIR/lib/profiles.sh"

log() { printf '\033[1;34m[import-config]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[import-config]\033[0m %s\n' "$*" >&2; exit 1; }

# Noms interdits même si l'utilisateur les passe explicitement : ce sont des
# secrets/credentials. On renvoie vers agent-import-auth.sh.
is_secret_item() {
  case "$1" in
    auth.json|.credentials.json|credentials.json|mcp-auth|.mcp-auth|secrets.env|.providers)
      return 0 ;;
    *) return 1 ;;
  esac
}

ARG_PROFILE=""
DRY_RUN=0
ITEMS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) ARG_PROFILE="${2:-}"; shift 2 ;;
    --profile=*) ARG_PROFILE="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) die "option inconnue: $1" ;;
    *) ITEMS="$ITEMS $1"; shift ;;
  esac
done
ITEMS="$(echo "$ITEMS" | xargs || true)"

PROFILE_NAME="$(profile_resolve "$ARG_PROFILE" 0)"
profile_exists "$PROFILE_NAME" || die "profil inconnu: $PROFILE_NAME"
profile_load "$PROFILE_NAME"

HOST_DIR="${HARNESS_HOST_CONFIG_DIR:-}"
[ -n "$HOST_DIR" ] || die "HARNESS_HOST_CONFIG_DIR non défini pour le profil $PROFILE_NAME — import de config non supporté (ajoute-le dans profiles/$PROFILE_NAME/profile.env)"
[ -d "$HOST_DIR" ] || die "config hôte introuvable: $HOST_DIR"

# Items = args explicites, sinon allowlist du profil.
[ -n "$ITEMS" ] || ITEMS="${HARNESS_HOST_CONFIG_ITEMS:-}"
[ -n "$ITEMS" ] || die "aucun item à importer (ni argument, ni HARNESS_HOST_CONFIG_ITEMS pour $PROFILE_NAME)"

REGISTRY="${AGENT_SANDBOX_REGISTRY:-localhost}"
AGENT_IMAGE="${REGISTRY}/agent-${PROFILE_NAME}:latest"
podman image exists "$AGENT_IMAGE" || die "image $AGENT_IMAGE absente (lance le harness une fois d'abord)"

log "profil $PROFILE_NAME : config hôte = $HOST_DIR → volume $HARNESS_HOME_VOL"
log "config dir conteneur = $HARNESS_CONFIG_DIR"

# ─── Staging côté hôte : on résout les symlinks ici (l'hôte voit ../shared) ───
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/agent-import-config.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

STAGED=""
REDIRECTED=0
for item in $ITEMS; do
  if is_secret_item "$item"; then
    die "refus d'importer '$item' (secret/credential) — utilise agent-import-auth.sh"
  fi
  if [ "$item" = "mcp.json" ]; then
    log "  – mcp.json : non copié tel quel — les serveurs MCP passent par le sidecar."
    log "      câble-les avec : agent-mcp-wire.sh --profile $PROFILE_NAME"
    REDIRECTED=1
    continue
  fi
  src="$HOST_DIR/$item"
  if [ ! -e "$src" ]; then
    log "  – $item : absent côté hôte, ignoré"
    continue
  fi
  # cp -RL : copie récursive en DÉRÉFÉRENÇANT tous les symlinks (dossiers ET
  # fichiers). Résout proprement les liens qui sortent du config-dir (../shared).
  if cp -RL "$src" "$STAGING/$item" 2>/dev/null; then
    log "  ✓ $item"
    STAGED="$STAGED $item"
  else
    log "  ! $item : échec de copie (symlink cassé côté hôte ?), ignoré"
  fi
done
STAGED="$(echo "$STAGED" | xargs || true)"
if [ -z "$STAGED" ]; then
  [ "$REDIRECTED" -eq 1 ] && exit 0   # que du mcp.json → rien à seeder, message déjà affiché
  die "rien à importer (aucun item résolu)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] items qui seraient importés :$STAGED"
  exit 0
fi

# ─── Push dans le volume via podman : copie + chown vers l'uid agent ──────────
# Le staging (symlinks déjà résolus) est monté RO ; on écrase item par item.
podman run --rm \
  -e ITEMS="$STAGED" \
  -v "${HARNESS_HOME_VOL}:/vol:Z" \
  -v "${STAGING}:/host:ro,Z" \
  --entrypoint "" "$AGENT_IMAGE" bash -c '
    set -e
    uid="$(id -u agent)"; gid="$(id -g agent)"
    for it in $ITEMS; do
      # écrase l'\''homologue existant (l'\''hôte gagne pour les items listés)
      rm -rf "/vol/$it"
      cp -a "/host/$it" "/vol/$it"
      chown -R "$uid:$gid" "/vol/$it"
    done
    # Bridge deps des extensions (pi) : pi résout les deps d'\''une extension
    # locale par remontée d'\''arbre depuis SON dossier. Les packages managés
    # vivent dans npm/node_modules, HORS de ce chemin → un symlink
    # node_modules -> npm/node_modules les rend résolvables (zod, @modelcontextprotocol/sdk…).
    if [ -d /vol/npm/node_modules ] && [ ! -e /vol/node_modules ]; then
      ln -sfn npm/node_modules /vol/node_modules
      chown -h "$uid:$gid" /vol/node_modules
      echo "bridge: node_modules -> npm/node_modules"
    fi
    echo "importé dans le volume: $ITEMS"
  '

log "fait. Ta config $PROFILE_NAME est seedée dans le sandbox."

case " $STAGED " in
  *" settings.json "*|*" opencode.json "*)
    log "NB: vérifie defaultProvider/enabledModels vs providers actifs — un modèle dont l'egress n'est pas ouvert échouera (fail-closed)." ;;
esac
