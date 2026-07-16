#!/usr/bin/env bash
# lib/profiles.sh — helpers profils multi-harness, source-ables par le launcher
# et le doctor. Compat bash 3.2 (macOS) : pas d'array associatif, pas de mapfile.
#
# L'appelant doit avoir défini : REPO_DIR. Optionnels : REGISTRY, BASE_IMAGE.
# Expose : profiles_list, profile_exists, profile_load, profile_select,
#          profile_resolve, profile_scaffold, ensure_image.

: "${PROFILES_DIR:=$REPO_DIR/profiles}"
: "${PROVIDERS_DIR:=$REPO_DIR/providers}"
: "${CONTAINERS_DIR:=$REPO_DIR/containers}"
: "${REGISTRY:=localhost}"
: "${BASE_IMAGE:=${REGISTRY}/agent-base:latest}"

_pf_log() { printf '\033[1;34m[profiles]\033[0m %s\n' "$*" >&2; }

# Liste les noms de profils (un par ligne) — sortie stdout propre.
profiles_list() {
  local d
  shopt -s nullglob
  for d in "$PROFILES_DIR"/*/profile.env; do
    basename "$(dirname "$d")"
  done
  shopt -u nullglob
}

profile_exists() { [ -f "$PROFILES_DIR/$1/profile.env" ]; }

# ─── Catalogue de providers (clé + domaine couplés, découplés du harness) ─────
provider_exists() { [ -f "$PROVIDERS_DIR/$1.env" ]; }

# Sortie stdout : les clés d'env uniques de la liste de providers passée en args.
providers_keys() {
  local p
  for p in "$@"; do
    provider_exists "$p" || { _pf_log "provider inconnu: $p (voir providers/)"; continue; }
    (
      PROVIDER_KEYS=""
      # shellcheck disable=SC1090
      . "$PROVIDERS_DIR/$p.env"
      for k in $PROVIDER_KEYS; do echo "$k"; done
    )
  done | awk 'NF && !seen[$0]++'
}

# Sortie stdout : les domaines egress uniques de la liste de providers passée en args.
providers_domains() {
  local p
  for p in "$@"; do
    provider_exists "$p" || continue
    (
      PROVIDER_DOMAINS=""
      # shellcheck disable=SC1090
      . "$PROVIDERS_DIR/$p.env"
      for d in $PROVIDER_DOMAINS; do echo "$d"; done
    )
  done | awk 'NF && !seen[$0]++'
}

# Signature stable (triée, CSV) du set de providers — sert de label pour détecter
# un changement de providers et recréer le sidecar egress. Args : noms de providers.
providers_sig() {
  printf '%s\n' "$@" | awk 'NF' | sort -u | paste -sd, -
}

# Vrai (0) si au moins un provider de la liste déclare PROVIDER_AUTH="oauth"
# (ex. github-copilot) — pilote le resync horloge + le check login côté doctor.
providers_any_oauth() {
  local p
  for p in "$@"; do
    provider_exists "$p" || continue
    if (
      PROVIDER_AUTH=""
      # shellcheck disable=SC1090
      . "$PROVIDERS_DIR/$p.env"
      [ "$PROVIDER_AUTH" = "oauth" ]
    ); then
      return 0
    fi
  done
  return 1
}

# Ports de callback OAuth déclarés par les providers actifs (un par ligne, uniques).
# Publiés VM→hôte par le launcher pour que le navigateur complète le redirect loopback.
providers_callback_ports() {
  local p
  for p in "$@"; do
    provider_exists "$p" || continue
    (
      PROVIDER_CALLBACK_PORT=""
      # shellcheck disable=SC1090
      . "$PROVIDERS_DIR/$p.env"
      [ -n "$PROVIDER_CALLBACK_PORT" ] && echo "$PROVIDER_CALLBACK_PORT"
    )
  done | awk 'NF && !seen[$0]++'
}

# Variables d'env (KEY=VAL) déclarées par les providers actifs (PROVIDER_RUN_ENV).
providers_run_env() {
  local p kv
  for p in "$@"; do
    provider_exists "$p" || continue
    (
      PROVIDER_RUN_ENV=""
      # shellcheck disable=SC1090
      . "$PROVIDERS_DIR/$p.env"
      for kv in $PROVIDER_RUN_ENV; do echo "$kv"; done
    )
  done | awk 'NF && !seen[$0]++'
}

# Liste les noms de providers du catalogue (un par ligne).
providers_list() {
  local d
  shopt -s nullglob
  for d in "$PROVIDERS_DIR"/*.env; do basename "$d" .env; done
  shopt -u nullglob
}

# Fichier de persistance du choix de providers (par profil, gitignoré).
providers_saved_file() { echo "$PROFILES_DIR/$1/.providers"; }
providers_saved()      { local f; f="$(providers_saved_file "$1")"; [ -f "$f" ] && tr '\n' ' ' < "$f" | xargs; }
providers_save()       { printf '%s\n' "$2" > "$(providers_saved_file "$1")"; }

# Menu multi-sélection. Arg 1 = défaut (noms pré-cochés / repris sur Entrée vide).
# Écrit les noms choisis (espace) sur stdout ; UI sur stderr.
# TTY → sélecteur à cases (flèches + espace) ; sinon → menu numéroté (fallback pipe/CI).
providers_select() {
  if [ -t 0 ] && [ -t 2 ]; then
    _providers_select_tty "${1:-}"
  else
    _providers_select_numbered "${1:-}"
  fi
}

# Sélecteur interactif à cases : ↑/↓ (ou j/k) déplace, espace coche, Entrée valide.
_providers_select_tty() {
  local default=" ${1:-} " names=() n i cur=0 key seq count out=""
  while IFS= read -r n; do names+=("$n"); done < <(providers_list)
  count=${#names[@]}
  [ "$count" -eq 0 ] && return 0
  local checked=()
  for ((i=0; i<count; i++)); do
    case "$default" in *" ${names[$i]} "*) checked[$i]=1 ;; *) checked[$i]=0 ;; esac
  done
  printf '\033[1mProviders\033[0m — ↑/↓ déplacer, espace cocher, Entrée valider\n' >&2
  _pf_render_menu() {
    local j box ptr
    for ((j=0; j<count; j++)); do
      [ "$j" -eq "$cur" ] && ptr=$'\033[36m❯\033[0m' || ptr=' '
      [ "${checked[$j]}" -eq 1 ] && box=$'\033[32m[x]\033[0m' || box='[ ]'
      printf '%s %s %s\033[K\n' "$ptr" "$box" "${names[$j]}" >&2
    done
  }
  _pf_render_menu
  while true; do
    IFS= read -rsn1 key || break
    case "$key" in
      $'\x1b')
        # Arrow keys = 3 octets envoyés ensemble ; on lit les 2 suivants (sans
        # timeout → compat bash 3.2 macOS où read -t fractionnaire n'existe pas).
        read -rsn2 seq || seq=""
        case "$seq" in
          '[A'|'OA') [ "$cur" -gt 0 ] && cur=$((cur-1)) ;;
          '[B'|'OB') [ "$cur" -lt $((count-1)) ] && cur=$((cur+1)) ;;
        esac ;;
      k|K) [ "$cur" -gt 0 ] && cur=$((cur-1)) ;;
      j|J) [ "$cur" -lt $((count-1)) ] && cur=$((cur+1)) ;;
      ' ') checked[$cur]=$(( 1 - ${checked[$cur]} )) ;;
      ''|$'\n'|$'\r') break ;;
    esac
    printf '\033[%dA' "$count" >&2   # remonte au 1er item et redessine
    _pf_render_menu
  done
  unset -f _pf_render_menu
  for ((i=0; i<count; i++)); do [ "${checked[$i]}" -eq 1 ] && out="$out ${names[$i]}"; done
  echo "$out" | xargs
}

# Fallback non-interactif : liste numérotée, saisie "1 3" (Entrée = défaut).
_providers_select_numbered() {
  local default="${1:-}" names=() n i choice picked=()
  while IFS= read -r n; do names+=("$n"); done < <(providers_list)
  [ ${#names[@]} -eq 0 ] && return 0
  {
    echo "Providers disponibles (plusieurs possibles, ex: 1 3) :"
    i=1
    for n in "${names[@]}"; do printf '  %d) %s\n' "$i" "$n"; i=$((i+1)); done
    printf 'Choix ? [Entrée = %s] ' "${default:-aucun}"
  } >&2
  read -r choice
  if [ -z "$choice" ]; then echo "$default"; return 0; fi
  for i in $choice; do
    case "$i" in *[!0-9]*) continue ;; esac
    [ "$i" -ge 1 ] && [ "$i" -le ${#names[@]} ] && picked+=("${names[$((i-1))]}")
  done
  echo "${picked[*]}"
}

# Source les variables du profil et pose PROFILE_NAME / PROFILE_DIR.
profile_load() {
  local name="$1" env_file="$PROFILES_DIR/$1/profile.env"
  [ -f "$env_file" ] || { _pf_log "profil introuvable: $name"; return 1; }
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  PROFILE_NAME="$name"
  PROFILE_DIR="$PROFILES_DIR/$name"
  # PROFILE_NAME/PROFILE_DIR sont consommés par les scripts qui sourcent ce lib.
  # shellcheck disable=SC2034
  : "$PROFILE_NAME" "$PROFILE_DIR"
}

# Menu interactif ; écrit le nom choisi sur stdout (prompts sur stderr).
# TTY → sélecteur flèches (choix unique) ; sinon → select numéroté (fallback pipe/CI).
profile_select() {
  local names=() n choice
  while IFS= read -r n; do names+=("$n"); done < <(profiles_list)
  if [ ${#names[@]} -eq 0 ]; then
    _pf_log "aucun profil dans $PROFILES_DIR"; return 1
  fi
  if [ ${#names[@]} -eq 1 ]; then
    echo "${names[0]}"; return 0
  fi
  if [ -t 0 ] && [ -t 2 ]; then
    _profile_select_tty "${names[@]}"
    return 0
  fi
  {
    echo "Harness disponibles :"
    local PS3="Choix du harness ? "
    select choice in "${names[@]}"; do
      [ -n "$choice" ] && break
    done
  } >&2
  echo "$choice"
}

# Sélecteur à choix UNIQUE (harness) : ↑/↓ (ou j/k) déplace, Entrée valide.
_profile_select_tty() {
  local names=("$@") count cur=0 key seq
  count=${#names[@]}
  printf '\033[1mHarness\033[0m — ↑/↓ déplacer, Entrée valider\n' >&2
  _pf_prof_render() {
    local j
    for ((j=0; j<count; j++)); do
      if [ "$j" -eq "$cur" ]; then
        printf '\033[36m❯ %s\033[0m\033[K\n' "${names[$j]}" >&2
      else
        printf '  %s\033[K\n' "${names[$j]}" >&2
      fi
    done
  }
  _pf_prof_render
  while true; do
    IFS= read -rsn1 key || break
    case "$key" in
      $'\x1b')
        read -rsn2 seq || seq=""
        case "$seq" in
          '[A'|'OA') [ "$cur" -gt 0 ] && cur=$((cur-1)) ;;
          '[B'|'OB') [ "$cur" -lt $((count-1)) ] && cur=$((cur+1)) ;;
        esac ;;
      k|K) [ "$cur" -gt 0 ] && cur=$((cur-1)) ;;
      j|J) [ "$cur" -lt $((count-1)) ] && cur=$((cur+1)) ;;
      ''|$'\n'|$'\r') break ;;
    esac
    printf '\033[%dA' "$count" >&2
    _pf_prof_render
  done
  unset -f _pf_prof_render
  echo "${names[$cur]}"
}

# Résout le profil selon la priorité (voir plan phase 1) :
#   1. $1 (--profile X)        → override one-shot
#   2. $2=1 (--choose/--menu)  → force le menu
#   3. $AGENT_PROFILE          → "toujours celui-ci" (shell rc)
#   4. menu interactif
# Écrit le nom résolu sur stdout.
profile_resolve() {
  local arg_profile="${1:-}" force_menu="${2:-0}"
  if [ -n "$arg_profile" ]; then echo "$arg_profile"; return 0; fi
  if [ "$force_menu" = "1" ]; then profile_select; return; fi
  if [ -n "${AGENT_PROFILE:-}" ]; then echo "$AGENT_PROFILE"; return 0; fi
  profile_select
}

# Crée un squelette de profil pré-rempli pour un harness inconnu.
profile_scaffold() {
  local name="$1" dir="$PROFILES_DIR/$1"
  mkdir -p "$dir/config"
  cat > "$dir/profile.env" <<EOF
HARNESS_NAME="$name"
HARNESS_BIN="$name"
HARNESS_LAUNCH_ARGS=""
HARNESS_CONFIG_DIR="/home/agent/.config/$name"
HARNESS_CONFIG_ENV=""
HARNESS_HOME_VOL="agent-home-$name"
HARNESS_AUTH_MODE="apikey"
# Providers actifs par défaut (catalogue providers/). Chacun apporte SA clé ET son
# domaine egress. Override au run : --provider <name> ou \$AGENT_PROVIDERS.
HARNESS_PROVIDERS="anthropic"
# (optionnel) clés d'env supplémentaires hors catalogue — injecte juste la valeur,
# pense alors à ouvrir le domaine dans allowlist.conf toi-même.
HARNESS_ENV_KEYS=""
HARNESS_RUN_ENV=""
EOF
  cat > "$dir/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# TODO: commande d'installation du binaire du harness dans l'image.
# ex: npm install -g <package>
EOF
  chmod +x "$dir/install.sh"
  cat > "$dir/allowlist.conf" <<EOF
# Allowlist egress du profil $name — fragment squid injecté dans egress/squid.base.conf.
# Une entrée = acl \`allowed_domains dstdomain …\` (voir docs/allowlist-egress.md).
# TODO: lister le(s) domaine(s) du provider, ex :
# acl allowed_domains dstdomain .exemple.com
EOF
  cat > "$dir/secrets.env.sample" <<EOF
# Clés d'auth du profil $name (mode apikey). Copie ce fichier en secrets.env
# (gitignoré) et renseigne les valeurs ; seules les clés listées dans
# HARNESS_ENV_KEYS franchissent la frontière du conteneur.
# ANTHROPIC_API_KEY=sk-...
EOF
  printf '{\n  "mcpServers": {}\n}\n' > "$dir/config/mcp.json"
  _pf_log "profil '$name' scaffoldé dans $dir — édite install.sh + allowlist.conf + secrets.env puis relance."
}

# Garantit que l'image du harness existe (build auto base + harness sinon).
# Écrit le nom de l'image du harness sur stdout.
ensure_image() {
  local name="$1"
  local harness_image="${REGISTRY}/agent-${name}:latest"
  if ! podman image exists "$BASE_IMAGE"; then
    _pf_log "image base absente → build…"
    podman build -t "$BASE_IMAGE" "$CONTAINERS_DIR/base" >&2
  fi
  if ! podman image exists "$harness_image"; then
    _pf_log "harness '$name' pas encore construit → build en cours…"
    podman build --build-arg BASE_IMAGE="$BASE_IMAGE" \
      -t "$harness_image" \
      -f "$CONTAINERS_DIR/harness/Containerfile" \
      "$PROFILES_DIR/$name" >&2
  fi
  echo "$harness_image"
}

