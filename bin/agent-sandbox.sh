#!/usr/bin/env bash
#
# agent-sandbox — lance un harness (Claude, pi, …) dans un sandbox Podman.
# Usage :
#   agent-sandbox.sh [--profile <name>] [--choose] [-- <args harness>]
#   alias claude='~/agent-airlock/bin/agent-sandbox.sh --profile claude'
#
# Résolution du harness (voir docs/architecture.md) :
#   --profile X  > --choose/--menu  > $AGENT_PROFILE  > menu interactif.
#
# Étapes : résout le profil → build image si absente → réseau interne →
# sidecars (mcp-remote, egress) → run -it.

set -euo pipefail

# Racine du repo (robuste aux symlinks) — le script retrouve ses fichiers voisins.
SCRIPT_PATH="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_PATH/.." && pwd)"

# ─── Config (surchargée par l'environnement) ──────────────────────────────────
REGISTRY="${AGENT_SANDBOX_REGISTRY:-localhost}"          # TODO: registry d'équipe réel
# BASE_IMAGE : consommé par lib/profiles.sh (sourcé) → ensure_image / build base.
# shellcheck disable=SC2034
BASE_IMAGE="${AGENT_BASE_IMAGE:-${REGISTRY}/agent-base:latest}"
MCP_IMAGE="${MCP_REMOTE_IMAGE:-${REGISTRY}/mcp-remote:latest}"
EGRESS_IMAGE="${EGRESS_IMAGE:-${REGISTRY}/egress-proxy:latest}"

NET="agent-net"                  # réseau INTERNE (pas de route internet, DNS désactivé)
NET_EXT="podman"                 # réseau par défaut (internet) pour les sidecars
SUBNET="10.89.0.0/24"
EGRESS_IP="10.89.0.10"           # IP statique du proxy sur agent-net (pas de DNS interne)
MCP_IP="10.89.0.11"              # IP statique du sidecar mcp-remote sur agent-net
MCP_CTR="mcp-remote"
EGRESS_CTR="egress-proxy"
# Sidecar proxy MCP pour pi (injecte un token Bearer pré-importé, pas d'OAuth).
# IP distincte de mcp-remote (10.89.0.11) pour ne pas créer de conflit.
MCP_PROXY_IMAGE="${MCP_PROXY_IMAGE:-${REGISTRY}/mcp-proxy:latest}"
MCP_PROXY_CTR="mcp-proxy"
MCP_PROXY_IP="10.89.0.12"

PROXY_PORT=3128
OAUTH_CALLBACK_PORT="${OAUTH_CALLBACK_PORT:-9910}"   # défaut/fallback ; sinon dérivé de servers.d
MCP_AUTH_VOL="agent-mcp-auth"    # volume des tokens OAuth MCP — monté SEULEMENT dans le sidecar

# shellcheck source=lib/profiles.sh
. "$REPO_DIR/lib/profiles.sh"

log() { printf '\033[1;34m[agent-sandbox]\033[0m %s\n' "$*" >&2; }

# ─── 0. Parsing des arguments ─────────────────────────────────────────────────
ARG_PROFILE=""
FORCE_MENU=0
ARG_PROVIDERS=""
CHOOSE_PROVIDERS=0
HARNESS_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) ARG_PROFILE="${2:-}"; shift 2 ;;
    --profile=*) ARG_PROFILE="${1#*=}"; shift ;;
    --choose|--menu) FORCE_MENU=1; shift ;;
    --provider) ARG_PROVIDERS="$ARG_PROVIDERS ${2:-}"; shift 2 ;;
    --provider=*) ARG_PROVIDERS="$ARG_PROVIDERS ${1#*=}"; shift ;;
    --choose-providers|--pick-providers) CHOOSE_PROVIDERS=1; shift ;;
    --) shift; HARNESS_ARGS+=("$@"); break ;;
    *) HARNESS_ARGS+=("$1"); shift ;;
  esac
done

# ─── 0b. Résolution + chargement du profil ────────────────────────────────────
PROFILE_NAME="$(profile_resolve "$ARG_PROFILE" "$FORCE_MENU")"
[ -n "$PROFILE_NAME" ] || { log "aucun harness sélectionné"; exit 1; }

if ! profile_exists "$PROFILE_NAME"; then
  log "profil '$PROFILE_NAME' inexistant."
  printf 'Créer un squelette profiles/%s/ ? [y/N] ' "$PROFILE_NAME" >&2
  read -r ans
  case "$ans" in
    y|Y) profile_scaffold "$PROFILE_NAME"; exit 0 ;;
    *) exit 1 ;;
  esac
fi

profile_load "$PROFILE_NAME"
log "harness : $PROFILE_NAME"

# ─── 0b'. Providers actifs (harness apikey) ────────────────────────────
# Chaque provider apporte SA clé ET son domaine egress (catalogue providers/).
# Résolution (priorité) :
#   1. --provider X          → override one-shot (non persisté)
#   2. --choose-providers    → menu multi-sélection, puis persisté
#   3. $AGENT_PROVIDERS       → override env (non persisté)
#   4. choix persisté profiles/<name>/.providers
#   5. apikey sans choix      → menu (défaut = HARNESS_PROVIDERS), puis persisté
#   6. sinon                  → HARNESS_PROVIDERS
ACTIVE_PROVIDERS=""
if [ "${HARNESS_AUTH_MODE:-oauth}" = "apikey" ]; then
  if [ -n "$(echo "$ARG_PROVIDERS" | xargs)" ]; then
    ACTIVE_PROVIDERS="$(echo "$ARG_PROVIDERS" | xargs)"
  elif [ "$CHOOSE_PROVIDERS" = 1 ]; then
    # Rouvre le wizard en pré-cochant le choix ACTUEL (persisté), sinon le défaut
    # du profil → tu ajoutes/retires à partir de l'existant.
    _cur="$(providers_saved "$PROFILE_NAME")"; [ -z "$_cur" ] && _cur="${HARNESS_PROVIDERS:-}"
    ACTIVE_PROVIDERS="$(providers_select "$_cur")"
    providers_save "$PROFILE_NAME" "$ACTIVE_PROVIDERS"
  elif [ -n "${AGENT_PROVIDERS:-}" ]; then
    ACTIVE_PROVIDERS="$(echo "$AGENT_PROVIDERS" | xargs)"
  elif [ -n "$(providers_saved "$PROFILE_NAME")" ]; then
    ACTIVE_PROVIDERS="$(providers_saved "$PROFILE_NAME")"
  else
    ACTIVE_PROVIDERS="$(providers_select "${HARNESS_PROVIDERS:-}")"
    providers_save "$PROFILE_NAME" "$ACTIVE_PROVIDERS"
  fi
fi
ACTIVE_PROVIDERS="$(echo "$ACTIVE_PROVIDERS" | xargs)"
# shellcheck disable=SC2086
PROV_SIG="$(providers_sig $ACTIVE_PROVIDERS)"
[ -n "$ACTIVE_PROVIDERS" ] && log "providers : $ACTIVE_PROVIDERS"

# ─── 0c. Préflight : la VM Podman doit être joignable ───────────────────
# Sans ce garde-fou, chaque étape (build, réseau, sidecars) échoue en cascade avec
# la même erreur socket illisible (les appels podman sont dans des `if !`/`||` que
# `set -e` n'intercepte pas). Si la VM existe mais est arrêtée, on la démarre ;
# si elle n'existe pas, on guide vers `machine init` (jamais d'init auto : trop
# invasif — téléchargement d'image, choix provider/disque).
if ! podman info >/dev/null 2>&1; then
  vm_state="$(podman machine inspect --format '{{.State}}' 2>/dev/null || true)"
  if [ -n "$vm_state" ] && [ "$vm_state" != "running" ]; then
    log "VM Podman arrêtée → démarrage (podman machine start)…"
    podman machine start >&2 || true
    for _ in $(seq 1 30); do podman info >/dev/null 2>&1 && break; sleep 1; done
  fi
  if ! podman info >/dev/null 2>&1; then
    if [ -z "$vm_state" ]; then
      log "Aucune VM Podman. Crée-la :  podman machine init --provider applehv && podman machine start"
    else
      log "Podman toujours injoignable après tentative de démarrage (voir: podman machine start)."
    fi
    exit 1
  fi
  log "VM Podman prête."
fi

# ─── 1. Image du harness (build auto si absente) ──────────────────────────────
AGENT_IMAGE="$(ensure_image "$PROFILE_NAME")"

# ─── 1b. Resync horloge VM (macOS) — seulement en auth OAuth ─────────────────
# podman machine dérive après une veille du Mac (System clock synchronized: no).
# Une horloge décalée fait rejeter le token OAuth fraîchement émis (iat dans le
# futur) → logout immédiat. On recale la VM sur l'heure de l'hôte.
# En auth apikey, aucun token horodaté n'est en jeu → on saute ce resync… SAUF si
# un provider OAuth est actif (ex. github-copilot : token horodaté, même piège).
# shellcheck disable=SC2086
if [ "${HARNESS_AUTH_MODE:-oauth}" = "oauth" ] || providers_any_oauth $ACTIVE_PROVIDERS; then
  podman machine ssh "sudo date -u -s '@$(date -u +%s)'" >/dev/null 2>&1 \
    && log "horloge VM resynchronisée" || true
fi

# ─── 2. Réseau interne ────────────────────────────────────────────────────────
# --internal    = aucune route vers internet (le harness ne peut pas exfiltrer en direct).
# --disable-dns = pas d'aardvark interne (sinon il pollue le resolv.conf des sidecars
#                 multi-homed et casse leur résolution DNS externe). On adresse donc
#                 les sidecars par IP statique ; le harness n'a jamais besoin de DNS externe
#                 (c'est le proxy qui résout les domaines via le CONNECT).
podman network exists "$NET" || {
  log "création du réseau interne $NET (sans DNS, subnet $SUBNET)"
  podman network create --internal --disable-dns --subnet "$SUBNET" "$NET" >/dev/null
}

# ─── 3. Sidecars long-lived ───────────────────────────────────────────────────
running() { [ "$(podman container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# Prépare les images des sidecars si absentes (VM neuve, pas de `make build`).
# Miroir du Makefile : egress = squid officiel tagué localhost ; mcp = build local.
# Sans ça, `podman run localhost/<img>` tente un pull vers un registry inexistant.
ensure_egress_image() {
  podman image exists "$EGRESS_IMAGE" && return 0
  log "image egress absente → préparation (docker.io/ubuntu/squid)…"
  podman pull docker.io/ubuntu/squid:latest >&2
  podman tag docker.io/ubuntu/squid:latest "$EGRESS_IMAGE" >&2
}
ensure_mcp_image() {
  podman image exists "$MCP_IMAGE" && return 0
  log "image mcp-remote absente → build…"
  podman build -t "$MCP_IMAGE" "$REPO_DIR/containers/mcp-remote" >&2
}

# Génère le squid.conf runtime du profil = squid.base.conf avec l'allowlist du
# profil injectée à la place du marqueur @@ALLOWLIST@@. Écrit le chemin sur stdout.
egress_render_conf() {
  local base="$REPO_DIR/egress/squid.base.conf"
  local allow="$PROFILE_DIR/allowlist.conf"
  local out_dir="$REPO_DIR/egress/.runtime"
  local out="$out_dir/squid.${PROFILE_NAME}.conf"
  mkdir -p "$out_dir"
  # Fragment injecté = allowlist d'infra du profil + domaines des providers actifs.
  local frag; frag="$(mktemp)"
  if [ -f "$allow" ]; then
    cat "$allow" >> "$frag"
  else
    log "WARN: $PROFILE_DIR/allowlist.conf absent (allowlist d'infra vide)"
  fi
  local d
  # shellcheck disable=SC2086
  for d in $(providers_domains $ACTIVE_PROVIDERS); do
    echo "acl allowed_domains dstdomain $d   # provider" >> "$frag"
  done
  if [ ! -s "$frag" ]; then
    log "WARN: aucune allowlist ni provider → egress vide (tout refusé pour ce harness)"
  fi
  awk -v allowfile="$frag" '
    /@@ALLOWLIST@@/ { while ((getline line < allowfile) > 0) print line; next }
    { print }
  ' "$base" > "$out"
  rm -f "$frag"
  echo "$out"
}

# Label porté par le sidecar egress = profil dont l'allowlist est chargée.
egress_label() {
  podman container inspect -f '{{ index .Config.Labels "agent-airlock.profile" }}' \
    "$EGRESS_CTR" 2>/dev/null
}
# Signature du set de providers chargé dans l'allowlist courante du sidecar.
egress_prov_label() {
  podman container inspect -f '{{ index .Config.Labels "agent-airlock.providers" }}' \
    "$EGRESS_CTR" 2>/dev/null
}

ensure_egress() {
  # Allowlist stricte PAR profil ET par set de providers : si le sidecar tourne
  # déjà avec un autre profil OU d'autres providers, on le recrée (pas de fusion).
  if running "$EGRESS_CTR"; then
    if [ "$(egress_label)" = "$PROFILE_NAME" ] && [ "$(egress_prov_label)" = "$PROV_SIG" ]; then
      return 0
    fi
    log "changement profil/providers → recréation du proxy egress ($PROFILE_NAME / ${PROV_SIG:-∅})"
  fi
  podman rm -f "$EGRESS_CTR" >/dev/null 2>&1 || true
  ensure_egress_image
  local conf; conf="$(egress_render_conf)"
  log "démarrage du proxy egress ($EGRESS_CTR, allowlist $PROFILE_NAME)"
  # Réseau externe PRIMAIRE (internet + DNS OK), puis agent-net en IP statique.
  # Label = profil chargé, pour détecter le switch d'allowlist au prochain run.
  podman run -d --name "$EGRESS_CTR" \
    --label "agent-airlock.profile=$PROFILE_NAME" \
    --label "agent-airlock.providers=$PROV_SIG" \
    --network "$NET_EXT" \
    -v "${conf}:/etc/squid/squid.conf:ro,Z" \
    "$EGRESS_IMAGE" >/dev/null
  podman network connect --ip "$EGRESS_IP" "$NET" "$EGRESS_CTR" >/dev/null
}


# Helper: derive OAuth callback ports from a servers.d directory.
# Usage: _mcp_cb_ports "<glob>" -> stdout: one "-p" arg and one "host:port:port" per line
_mcp_cb_ports() {
  local dir_glob="$1" seen=" " f cp
  shopt -s nullglob
  for f in $dir_glob; do
    cp=$(grep -E '^[[:space:]]*CALLBACK_PORT=' "$f" | tail -1 | cut -d= -f2)
    cp="${cp//\"/}"  # strip double quotes
    cp="${cp//\'/}" # strip single quotes
    cp="${cp// /}"   # strip spaces
    [ -n "$cp" ] || continue
    case "$seen" in
      *" $cp "*) log "WARN: CALLBACK_PORT $cp in duplicate servers.d entry - OAuth will fail for one"; continue ;;
    esac
    seen="$seen$cp "
    printf '%s\n' -p "127.0.0.1:${cp}:${cp}"
  done
  shopt -u nullglob
}
ensure_mcp() {
  running "$MCP_CTR" && return 0
  podman rm -f "$MCP_CTR" >/dev/null 2>&1 || true
  ensure_mcp_image
  log "démarrage du sidecar mcp-remote ($MCP_CTR)"
  # Ports de callback OAuth publiés sur l'hôte (dérivés de servers.d) ; volume des tokens
  # ISOLÉ ici (jamais dans le conteneur harness).
  MCP_CB_ARGS=(); while IFS= read -r ln; do MCP_CB_ARGS+=("$ln"); done < <(_mcp_cb_ports "$REPO_DIR/containers/mcp-remote/servers.d/*.env")
  if [ ${#MCP_CB_ARGS[@]} -eq 0 ]; then
    MCP_CB_ARGS=(-p "127.0.0.1:${OAUTH_CALLBACK_PORT}:${OAUTH_CALLBACK_PORT}")
  fi
  podman run -d --name "$MCP_CTR" \
    --network "$NET_EXT" \
    "${MCP_CB_ARGS[@]+"${MCP_CB_ARGS[@]}"}" \
    -v "${MCP_AUTH_VOL}:/home/node/.mcp-auth:z" \
    -v "$REPO_DIR/containers/mcp-remote/servers.d:/servers.d:ro,z" \
    "$MCP_IMAGE"
  podman network connect --ip "$MCP_IP" "$NET" "$MCP_CTR" >/dev/null
}

# Sidecar proxy pour pi (même image, servers.d-proxy/ avec CALLBACK_PORT).
# Le proxy.js fait l'OAuth automatiquement si pas de token (pas d'import manuel).
ensure_mcp_proxy() {
  running "$MCP_PROXY_CTR" && return 0
  podman rm -f "$MCP_PROXY_CTR" >/dev/null 2>&1 || true
  ensure_mcp_proxy_image
  mkdir -p "$REPO_DIR/containers/mcp-remote/servers.d-proxy"
  log "démarrage du proxy MCP ($MCP_PROXY_CTR)"
  # Ports de callback OAuth dérivés de servers.d-proxy uniquement.
  MCP_PROXY_CB_ARGS=(); while IFS= read -r ln; do MCP_PROXY_CB_ARGS+=("$ln"); done < <(_mcp_cb_ports "$REPO_DIR/containers/mcp-remote/servers.d-proxy/*.env")
  if [ ${#MCP_PROXY_CB_ARGS[@]} -eq 0 ]; then
    MCP_PROXY_CB_ARGS=(-p "127.0.0.1:${OAUTH_CALLBACK_PORT}:${OAUTH_CALLBACK_PORT}")
  fi
  podman run -d --name "$MCP_PROXY_CTR" \
    --network "$NET_EXT" \
    "${MCP_PROXY_CB_ARGS[@]+"${MCP_PROXY_CB_ARGS[@]}"}" \
    -v "${MCP_AUTH_VOL}:/home/node/.mcp-auth:z" \
    -v "$REPO_DIR/containers/mcp-remote/servers.d-proxy:/servers.d:ro,z" \
    "$MCP_PROXY_IMAGE"
  podman network connect --ip "$MCP_PROXY_IP" "$NET" "$MCP_PROXY_CTR" >/dev/null
}

ensure_mcp_proxy_image() {
  podman image exists "$MCP_PROXY_IMAGE" && return 0
  log "image mcp-proxy absente → build…"
  podman build -t "$MCP_PROXY_IMAGE" "$REPO_DIR/containers/mcp-remote" >&2
}

ensure_egress
ensure_mcp
ensure_mcp_proxy

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

# ─── 4b. Variables d'env additionnelles du profil (HARNESS_RUN_ENV) ───────────
declare -a RUN_ENV_ARGS=()
for kv in ${HARNESS_RUN_ENV:-}; do
  RUN_ENV_ARGS+=(-e "$kv")
done
# Run-env déclaré par les providers actifs (ex. PI_OAUTH_CALLBACK_HOST=0.0.0.0).
# shellcheck disable=SC2086
for kv in $(providers_run_env $ACTIVE_PROVIDERS); do
  RUN_ENV_ARGS+=(-e "$kv")
done

# ─── 4b'. Ports de callback OAuth des providers abonnement (loopback fixe) ─────
# Un provider OAuth loopback (ex. claude-pro:53692) doit voir son port publié
# VM→hôte, sinon le navigateur ne peut pas joindre http://localhost:<port>.
declare -a PROVIDER_PUBLISH_ARGS=()
# shellcheck disable=SC2086
for port in $(providers_callback_ports $ACTIVE_PROVIDERS); do
  PROVIDER_PUBLISH_ARGS+=(-p "127.0.0.1:${port}:${port}")
  log "callback OAuth publié : 127.0.0.1:${port} (provider abonnement)"
done

# ─── 4c. Injection des clés d'auth (mode apikey) ──────────────────────────
# Passthrough SELECTIF : seuls les noms listés dans HARNESS_ENV_KEYS franchissent
# la frontière (jamais tout l'env de l'hôte). Valeur résolue : secrets.env du
# profil (prioritaire, gitignoré) puis fallback sur l'env de l'hôte.
declare -a AUTH_ENV_ARGS=()
if [ "${HARNESS_AUTH_MODE:-oauth}" = "apikey" ]; then
  secrets_file="$PROFILE_DIR/secrets.env"
  # Clés à injecter = clés des providers actifs (catalogue) ∪ HARNESS_ENV_KEYS (extra).
  # shellcheck disable=SC2086,SC2046
  auth_keys="$(printf '%s\n' $(providers_keys $ACTIVE_PROVIDERS) ${HARNESS_ENV_KEYS:-} | awk 'NF && !seen[$0]++')"
  if [ -z "$auth_keys" ]; then
    log "WARN: aucun provider actif ni HARNESS_ENV_KEYS — aucune clé injectée (auth KO ?)"
  fi
  for key in $auth_keys; do
    val=""
    if [ -f "$secrets_file" ]; then
      # Lecture dans un sous-shell : le fichier peut définir d'autres clés, on
      # n'extrait QUE celles listées (allowlist de noms).
      val="$(
        set +u
        # shellcheck disable=SC1090
        . "$secrets_file" >/dev/null 2>&1 || true
        printf '%s' "${!key:-}"
      )"
    fi
    [ -z "$val" ] && val="${!key:-}"   # fallback env hôte
    if [ -n "$val" ]; then
      AUTH_ENV_ARGS+=(-e "${key}=${val}")
    else
      log "WARN: clé $key introuvable (ni secrets.env ni env hôte) — auth $PROFILE_NAME probablement KO"
    fi
  done
fi

# ─── 5. Run du harness (interactif, reste dans le terminal) ───────────────────
exec podman run -it --rm \
  --network "$NET" \
  --hostname "${PROFILE_NAME}-sandbox" \
  "${PROVIDER_PUBLISH_ARGS[@]+"${PROVIDER_PUBLISH_ARGS[@]}"}" \
  -v "$PWD:/workspace:Z" \
  -v "${HARNESS_HOME_VOL}:${HARNESS_CONFIG_DIR}:Z" \
  "${GIT_MOUNTS[@]+"${GIT_MOUNTS[@]}"}" \
  -w /workspace \
  -e HTTP_PROXY="http://${EGRESS_IP}:${PROXY_PORT}" \
  -e HTTPS_PROXY="http://${EGRESS_IP}:${PROXY_PORT}" \
  -e NO_PROXY="${MCP_IP},${MCP_PROXY_IP},localhost,127.0.0.1" \
  -e HARNESS_BIN="${HARNESS_BIN}" \
  -e HARNESS_LAUNCH_ARGS="${HARNESS_LAUNCH_ARGS:-}" \
  -e HARNESS_CONFIG_DIR="${HARNESS_CONFIG_DIR}" \
  -e HARNESS_CONFIG_ENV="${HARNESS_CONFIG_ENV:-}" \
  "${RUN_ENV_ARGS[@]+"${RUN_ENV_ARGS[@]}"}" \
  "${AUTH_ENV_ARGS[@]+"${AUTH_ENV_ARGS[@]}"}" \
  "$AGENT_IMAGE" "${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}"
