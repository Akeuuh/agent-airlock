#!/usr/bin/env bash
#
# agent-doctor — vérifie l'état complet du sandbox (infra + isolation + auth).
# Usage : ~/agent-airlock/bin/agent-doctor.sh [--profile <name>]
#
# Entièrement profile-driven : image, allowlist egress, skip horloge (apikey),
# credentials (oauth) ou résolution des clés (apikey) sont tirés du profil.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVERS_DIR="$REPO_DIR/containers/mcp-remote/servers.d"

# shellcheck source=lib/profiles.sh
. "$REPO_DIR/lib/profiles.sh"

# ─── Résolution du profil ─────────────────────────────────────────────────────
ARG_PROFILE=""
ARG_PROVIDERS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) ARG_PROFILE="${2:-}"; shift 2 ;;
    --profile=*) ARG_PROFILE="${1#*=}"; shift ;;
    --provider) ARG_PROVIDERS="$ARG_PROVIDERS ${2:-}"; shift 2 ;;
    --provider=*) ARG_PROVIDERS="$ARG_PROVIDERS ${1#*=}"; shift ;;
    *) shift ;;
  esac
done
PROFILE_NAME="$(profile_resolve "$ARG_PROFILE" 0)"
profile_exists "$PROFILE_NAME" || { echo "profil inconnu: $PROFILE_NAME" >&2; exit 1; }
profile_load "$PROFILE_NAME"
# Providers actifs (non interactif) : arg > env > choix persisté > défaut profil.
if [ -n "$(echo "$ARG_PROVIDERS" | xargs)" ]; then
  ACTIVE_PROVIDERS="$(echo "$ARG_PROVIDERS" | xargs)"
elif [ -n "${AGENT_PROVIDERS:-}" ]; then
  ACTIVE_PROVIDERS="$(echo "$AGENT_PROVIDERS" | xargs)"
elif [ -n "$(providers_saved "$PROFILE_NAME")" ]; then
  ACTIVE_PROVIDERS="$(providers_saved "$PROFILE_NAME")"
else
  ACTIVE_PROVIDERS="$(echo "${HARNESS_PROVIDERS:-}" | xargs)"
fi

NET="agent-net"; EGRESS_CTR="egress-proxy"; MCP_CTR="mcp-remote"; MCP_PROXY_CTR="mcp-proxy"
EGRESS_IP="10.89.0.10"; MCP_IP="10.89.0.11"; PROXY="http://${EGRESS_IP}:3128"
REGISTRY="${AGENT_SANDBOX_REGISTRY:-localhost}"
AGENT_IMAGE="${REGISTRY}/agent-${PROFILE_NAME}:latest"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
ko()   { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
head() { printf '\n\033[1m%s\033[0m\n' "$*"; }

probe() { podman run --rm --network "$NET" --entrypoint "" "$AGENT_IMAGE" bash -c "$1" 2>/dev/null; }

printf '\033[1mHarness : %s (image %s)\033[0m\n' "$PROFILE_NAME" "$AGENT_IMAGE"

head "1. Podman"
podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running \
  && ok "machine podman démarrée" || ko "machine podman non démarrée (podman machine start)"
# Dérive d'horloge = tokens OAuth rejetés (logout immédiat) — pertinent en auth oauth
# OU si un provider OAuth est actif (ex. github-copilot en mode apikey pi).
# shellcheck disable=SC2086
if [ "${HARNESS_AUTH_MODE:-oauth}" = "oauth" ] || providers_any_oauth $ACTIVE_PROVIDERS; then
  vm=$(podman machine ssh 'date -u +%s' 2>/dev/null); host=$(date -u +%s)
  if [ -n "$vm" ]; then
    skew=$(( vm > host ? vm - host : host - vm ))
    [ "$skew" -le 5 ] && ok "horloge VM synchro (écart ${skew}s)" \
      || ko "horloge VM décalée de ${skew}s (relance le launcher pour resync, sinon logout OAuth)"
  fi
fi

head "2. Images"
podman image exists "${REGISTRY}/agent-base:latest" && ok "image agent-base présente" || ko "image agent-base manquante (make build-base)"
podman image exists "$AGENT_IMAGE" && ok "image agent-${PROFILE_NAME} présente" || ko "image agent-${PROFILE_NAME} manquante (make build-harness PROFILE=${PROFILE_NAME})"
for img in mcp-remote egress-proxy; do
  podman image exists "${REGISTRY}/$img:latest" && ok "image $img présente" || ko "image $img manquante (make build)"
done

head "3. Réseau interne"
if podman network exists "$NET"; then
  internal=$(podman network inspect "$NET" --format '{{.Internal}}')
  dns=$(podman network inspect "$NET" --format '{{.DNSEnabled}}')
  [ "$internal" = "true" ] && ok "$NET internal=true" || ko "$NET PAS internal (fuite internet possible)"
  [ "$dns" = "false" ] && ok "$NET dns=false (IP statiques)" || ko "$NET dns activé (risque de casse DNS sidecars)"
else
  ko "réseau $NET absent"
fi

head "4. Sidecars"
for c in "$EGRESS_CTR" "$MCP_CTR" "$MCP_PROXY_CTR"; do
  [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] \
    && ok "$c up" || ko "$c arrêté"
done

head "5. Isolation réseau (conteneur harness)"
code=$(probe "curl -s -m6 --noproxy '*' -o /dev/null -w '%{http_code}' https://example.com")
[ "$code" = "000" ] && ok "pas d'internet direct (example.com bloqué)" || ko "internet direct joignable (http=$code) — FUITE"

head "6. Allowlist egress (proxy)"
allow="$PROFILE_DIR/allowlist.conf"
# Domaines testés = infra du profil (allowlist.conf) + domaines des providers actifs.
infra_domains=""
if [ -f "$allow" ]; then
  infra_domains=$(awk '/dstdomain/ { sub(/#.*/,""); for(i=1;i<=NF;i++) if($i!="acl" && $i!="allowed_domains" && $i!="dstdomain") print $i }' "$allow")
else
  ko "profiles/$PROFILE_NAME/allowlist.conf absent"
fi
# shellcheck disable=SC2086
prov_domains="$(providers_domains $ACTIVE_PROVIDERS)"
# On garde le point de tête (wildcard) pour distinguer un domaine exact d'un wildcard.
domains=$(printf '%s\n%s\n' "$infra_domains" "$prov_domains" | awk 'NF && !seen[$0]++')
if [ -n "$domains" ]; then
  [ -n "$ACTIVE_PROVIDERS" ] && printf '  \033[2mproviders actifs : %s\033[0m\n' "$ACTIVE_PROVIDERS"
  for d in $domains; do
    host="${d#.}"   # wildcard .exemple.com → on sonde l'apex exemple.com
    # On capture http_code ET http_connect : pour du HTTPS via proxy, un refus
    # d'allowlist se voit au CONNECT (http_connect=403), pas au http_code (=000
    # aussi bien pour un refus que pour un domaine autorisé mais injoignable).
    res=$(probe "curl -s -m12 -x $PROXY -o /dev/null -w '%{http_code} %{http_connect}' https://$host")
    code="${res%% *}"; conn="${res##* }"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      ok "$host autorisé (http=$code)"
    elif [ "$conn" = "403" ]; then
      # Le proxy a REFUSÉ le CONNECT → domaine hors allowlist (vraie anomalie).
      ko "$host bloqué par l'allowlist (CONNECT 403)"
    else
      # CONNECT accepté (autorisé) mais pas de réponse : domaine injoignable depuis
      # cet hôte — interne/VPN, serveur MCP lazy, ou apex d'un wildcard non-sondable.
      # L'allowlist est correcte → neutre, pas un échec.
      printf '  \033[33m–\033[0m %s autorisé (injoignable depuis cet hôte)\n' "$host"
    fi
  done
else
  printf '  \033[33m–\033[0m aucun domaine autorisé (allowlist infra vide + aucun provider actif)\n'
fi
res=$(probe "curl -s -m10 -x $PROXY -o /dev/null -w '%{http_code} %{http_connect}' https://example.com")
code="${res%% *}"; conn="${res##* }"
{ [ "$conn" = "403" ] || [ "$code" = "000" ]; } && ok "example.com refusé par l'allowlist ✓" || ko "example.com PAS refusé (http=$code)"

head "7. Tunnel MCP (socat → mcp-remote)"
if ls "$SERVERS_DIR"/*.env >/dev/null 2>&1; then
  probe "timeout 4 socat -u TCP:$MCP_IP:9000 - >/dev/null 2>&1; [ \$? -eq 0 ] || [ \$? -eq 124 ]" \
    && ok "port $MCP_IP:9000 joignable" || ko "tunnel MCP injoignable"
else
  printf '  \033[33m–\033[0m aucun serveur MCP déclaré dans servers.d (tunnel non testé)\n'
fi

head "8. Authentification"
if [ "${HARNESS_AUTH_MODE:-oauth}" = "oauth" ]; then
  creds_file="${HARNESS_CREDENTIALS_FILE:-.credentials.json}"
  creds=$(podman run --rm -v "${HARNESS_HOME_VOL}:/d:Z" --entrypoint "" "$AGENT_IMAGE" \
    bash -c "test -f /d/${creds_file} && echo yes" 2>/dev/null)
  [ "$creds" = "yes" ] && ok "login persisté ($creds_file)" \
    || ko "pas de credentials (lance le harness et connecte-toi une fois)"
else
  # apikey. Si un provider OAuth est actif (ex. github-copilot), le login vit dans
  # auth.json du volume persistant — on vérifie sa présence (pas une clé d'env).
  # shellcheck disable=SC2086
  if providers_any_oauth $ACTIVE_PROVIDERS; then
    creds_file="${HARNESS_CREDENTIALS_FILE:-auth.json}"
    creds=$(podman run --rm -v "${HARNESS_HOME_VOL}:/d:Z" --entrypoint "" "$AGENT_IMAGE" \
      bash -c "test -f /d/${creds_file} && echo yes" 2>/dev/null)
    [ "$creds" = "yes" ] && ok "login OAuth persisté ($creds_file) — provider(s) abonnement" \
      || ko "provider OAuth actif mais pas de login (lance pi et fais /login une fois)"
  fi
  # apikey : vérifie que chaque clé des providers actifs (+ HARNESS_ENV_KEYS) est
  # résoluble (sans afficher la valeur).
  secrets_file="$PROFILE_DIR/secrets.env"
  # shellcheck disable=SC2086,SC2046
  keys="$(printf '%s\n' $(providers_keys $ACTIVE_PROVIDERS) ${HARNESS_ENV_KEYS:-} | awk 'NF && !seen[$0]++')"
  [ -n "$ACTIVE_PROVIDERS" ] && printf '  \033[2mproviders actifs : %s\033[0m\n' "$ACTIVE_PROVIDERS"
  # shellcheck disable=SC2086
  if [ -z "$keys" ] && ! providers_any_oauth $ACTIVE_PROVIDERS; then
    printf '  \033[33m–\033[0m auth apikey sans provider ni HARNESS_ENV_KEYS (rien à injecter)\n'
  fi
  for key in $keys; do
    if [ -f "$secrets_file" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$secrets_file"; then
      ok "clé $key disponible (secrets.env)"
    elif [ -n "${!key:-}" ]; then
      ok "clé $key disponible (env hôte)"
    else
      ko "clé $key absente (ni secrets.env ni env hôte)"
    fi
  done
fi

printf '\n\033[1mRésultat : %d OK, %d KO\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
