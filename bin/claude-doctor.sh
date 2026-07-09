#!/usr/bin/env bash
#
# claude-doctor — vérifie l'état complet du sandbox Claude (infra + isolation + auth).
# Usage : ~/Dev/IA/claude-isolation/bin/claude-doctor.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVERS_DIR="$REPO_DIR/containers/mcp-remote/servers.d"
NET="claude-net"; EGRESS_CTR="egress-proxy"; MCP_CTR="mcp-remote"
EGRESS_IP="10.89.0.10"; MCP_IP="10.89.0.11"; PROXY="http://10.89.0.10:3128"
CLAUDE_IMAGE="localhost/claude-sandbox:latest"

pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
ko()   { printf '  \033[31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
head() { printf '\n\033[1m%s\033[0m\n' "$*"; }

probe() { podman run --rm --network "$NET" --entrypoint "" "$CLAUDE_IMAGE" bash -c "$1" 2>/dev/null; }

head "1. Podman"
podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running \
  && ok "machine podman démarrée" || ko "machine podman non démarrée (podman machine start)"
# Dérive d'horloge = tokens OAuth rejetés (logout immédiat)
vm=$(podman machine ssh 'date -u +%s' 2>/dev/null); host=$(date -u +%s)
if [ -n "$vm" ]; then
  skew=$(( vm > host ? vm - host : host - vm ))
  [ "$skew" -le 120 ] && ok "horloge VM synchro (écart ${skew}s)" \
    || ko "horloge VM décalée de ${skew}s (relance le launcher pour resync, sinon logout OAuth)"
fi

head "2. Images"
for img in claude-sandbox mcp-remote egress-proxy; do
  podman image exists "localhost/$img:latest" && ok "image $img présente" || ko "image $img manquante (make build)"
done

head "3. Réseau interne"
if podman network exists "$NET"; then
  internal=$(podman network inspect "$NET" --format '{{.Internal}}')
  dns=$(podman network inspect "$NET" --format '{{.DNSEnabled}}')
  [ "$internal" = "true" ] && ok "claude-net internal=true" || ko "claude-net PAS internal (fuite internet possible)"
  [ "$dns" = "false" ] && ok "claude-net dns=false (IP statiques)" || ko "claude-net dns activé (risque de casse DNS sidecars)"
else
  ko "réseau claude-net absent"
fi

head "4. Sidecars"
for c in "$EGRESS_CTR" "$MCP_CTR"; do
  [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] \
    && ok "$c up" || ko "$c arrêté"
done

head "5. Isolation réseau (conteneur Claude)"
code=$(probe "curl -s -m6 --noproxy '*' -o /dev/null -w '%{http_code}' https://example.com")
[ "$code" = "000" ] && ok "pas d'internet direct (example.com bloqué)" || ko "internet direct joignable (http=$code) — FUITE"

head "6. Allowlist egress (proxy)"
for d in api.anthropic.com platform.claude.com claude.ai raw.githubusercontent.com; do
  c=$(probe "curl -s -m12 -x $PROXY -o /dev/null -w '%{http_code}' https://$d")
  [ -n "$c" ] && [ "$c" != "000" ] && ok "$d autorisé (http=$c)" || ko "$d bloqué/injoignable (http=$c)"
done
c=$(probe "curl -s -m10 -x $PROXY -o /dev/null -w '%{http_code}' https://example.com")
[ "$c" = "000" ] || [ "$c" = "403" ] && ok "example.com refusé par l'allowlist ✓" || ko "example.com PAS refusé (http=$c)"

head "7. Tunnel MCP (socat → mcp-remote)"
if ls "$SERVERS_DIR"/*.env >/dev/null 2>&1; then
  probe "timeout 4 socat -u TCP:$MCP_IP:9000 - >/dev/null 2>&1; [ \$? -eq 0 ] || [ \$? -eq 124 ]" \
    && ok "port $MCP_IP:9000 joignable" || ko "tunnel MCP injoignable"
else
  printf '  \033[33m–\033[0m aucun serveur MCP déclaré dans servers.d (tunnel non testé)\n'
fi

head "8. Authentification (volume persistant)"
creds=$(podman run --rm -v claude-home:/d:Z --entrypoint "" "$CLAUDE_IMAGE" \
  bash -c 'test -f /d/.credentials.json && echo yes' 2>/dev/null)
[ "$creds" = "yes" ] && ok "login abonnement persisté (.credentials.json)" \
  || ko "pas de credentials (lance 'claude' et connecte-toi une fois)"

printf '\n\033[1mRésultat : %d OK, %d KO\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
