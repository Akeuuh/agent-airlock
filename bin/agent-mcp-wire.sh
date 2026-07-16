#!/usr/bin/env bash
#
# agent-mcp-wire — câble les serveurs MCP d'un mcp.json HÔTE sur le sidecar
# proxy du sandbox, au lieu de les laisser le harness joindre en direct.
#
# Le sidecar proxy (mcp-proxy pour pi, mcp-remote pour claude/opencode) fait
# l'OAuth automatiquement si le serveur le supporte, sinon affiche les
# instructions dans `podman logs`. Le token vit dans le sidecar, jamais
# dans le harness.
#
# Ce que fait le script, à partir de $HARNESS_HOST_CONFIG_DIR/mcp.json :
#   1. pour chaque serveur DISTANT (URL http/sse ; localhost/127.0.0.1 ignorés) :
#        écrit containers/mcp-remote/servers.d-proxy/<nom>.env (NAME/URL/PORT/CALLBACK_PORT),
#        ports assignés de façon stable (réutilise ceux déjà présents) ;
#   2. écrit un mcp.json SANDBOX dans le volume du profil, où chaque serveur est
#        en transport streamable-http vers le proxy (pas d'auth — le proxy gère).
#
# Usage :
#   agent-mcp-wire.sh [--profile <name>] [--dry-run] [serveur...]
#   ex : agent-mcp-wire.sh --profile pi              # tous les serveurs distants
#        agent-mcp-wire.sh --profile pi jira datadog # un sous-ensemble
#
# Ensuite : lance le harness. Le proxy fait l'OAuth automatiquement (ou affiche
# les instructions dans `podman logs mcp-proxy`). Token persistant dans le sidecar.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/profiles.sh
. "$REPO_DIR/lib/profiles.sh"

log() { printf '\033[1;34m[mcp-wire]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[mcp-wire]\033[0m %s\n' "$*" >&2; exit 1; }

# Bases d'assignation des ports (doivent rester cohérentes avec le sidecar).
PORT_BASE=9000

ARG_PROFILE=""
DRY_RUN=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) ARG_PROFILE="${2:-}"; shift 2 ;;
    --profile=*) ARG_PROFILE="${1#*=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    -*) die "option inconnue: $1" ;;
    *) ONLY="$ONLY $1"; shift ;;
  esac
done
ONLY="$(echo "$ONLY" | xargs || true)"

PROFILE_NAME="$(profile_resolve "$ARG_PROFILE" 0)"
profile_exists "$PROFILE_NAME" || die "profil inconnu: $PROFILE_NAME"
profile_load "$PROFILE_NAME"

HOST_DIR="${HARNESS_HOST_CONFIG_DIR:-}"
[ -n "$HOST_DIR" ] || die "HARNESS_HOST_CONFIG_DIR non défini pour le profil $PROFILE_NAME"
HOST_MCP="$HOST_DIR/mcp.json"
[ -f "$HOST_MCP" ] || die "pas de mcp.json côté hôte ($HOST_MCP)"
command -v node >/dev/null 2>&1 || die "node requis sur l'hôte pour parser mcp.json"

REGISTRY="${AGENT_SANDBOX_REGISTRY:-localhost}"
AGENT_IMAGE="${REGISTRY}/agent-${PROFILE_NAME}:latest"
podman image exists "$AGENT_IMAGE" || die "image $AGENT_IMAGE absente (lance le harness une fois)"

SERVERS_DIR="$REPO_DIR/containers/mcp-remote/servers.d-proxy"
mkdir -p "$SERVERS_DIR"
# IP statique du sidecar proxy mcp-proxy sur agent-net (doit matcher bin/agent-sandbox.sh).
MCP_PROXY_IP="10.89.0.12"

# node fait tout le travail host-side : lit mcp.json + servers.d existants,
# assigne des ports stables, écrit les servers.d-proxy/<nom>.env, et émet le mcp.json
# sandbox (streamable-http) sur stdout. Renvoie exit!=0 si rien à câbler.
SANDBOX_MCP="$(mktemp)"
trap 'rm -f "$SANDBOX_MCP"' EXIT

node - "$HOST_MCP" "$SERVERS_DIR" "$MCP_PROXY_IP" "$PORT_BASE" "$ONLY" "$DRY_RUN" >"$SANDBOX_MCP" <<'NODE'
const fs = require("fs");
const path = require("path");
const [hostMcp, serversDir, mcpIp, portBase, onlyRaw, dryRaw] = process.argv.slice(2);
const only = (onlyRaw || "").split(/\s+/).filter(Boolean);
const dryRun = dryRaw === "1";

const cfg = JSON.parse(fs.readFileSync(hostMcp, "utf8"));
const servers = cfg.mcpServers || {};

// Ports déjà assignés dans servers.d (réutilisation → assignation stable).
const used = new Set();
const existing = {}; // name -> PORT
for (const f of fs.existsSync(serversDir) ? fs.readdirSync(serversDir) : []) {
  if (!f.endsWith(".env")) continue;
  const body = fs.readFileSync(path.join(serversDir, f), "utf8");
  const get = (k) => (body.match(new RegExp("^\\s*" + k + "=(.*)$", "m")) || [])[1]?.trim().replace(/["']/g, "");
  const name = get("NAME") || f.replace(/\.env$/, "");
  const port = get("PORT");
  if (port) used.add(+port);
  existing[name] = port;
}
const nextFree = (base) => { let p = base; while (used.has(p)) p++; used.add(p); return p; };

const isLocal = (h) => h === "localhost" || h === "0.0.0.0" || h === "::1" || h.startsWith("127.") || h.endsWith(".local");
const sandbox = { mcpServers: {} };
const wired = [], skipped = [];

for (const [name, s] of Object.entries(servers)) {
  if (only.length && !only.includes(name)) continue;
  const url = s.url || s.transport?.url || s.endpoint;
  if (!url) { skipped.push(`${name} (pas d'URL http/sse)`); continue; }
  let host;
  try { host = new URL(url).hostname; } catch { skipped.push(`${name} (URL invalide)`); continue; }
  if (isLocal(host)) { skipped.push(`${name} (${host} loopback/local — injoignable via sidecar)`); continue; }

  const port = existing[name] ? +existing[name] : nextFree(+portBase);
  const cbPort = port + 1000;   // callback = port + 1000 (ex. 9000 → 19000)

  // Écrit/rafraîchit le fragment servers.d du sidecar proxy.
  const env = [
    `# Généré par agent-mcp-wire depuis mcp.json — serveur MCP distant "${name}".`,
    `NAME=${name}`,
    `URL=${url}`,
    `PORT=${port}`,
    `CALLBACK_PORT=${cbPort}`,
    "",
  ].join("\n");
  if (!dryRun) fs.writeFileSync(path.join(serversDir, `${name}.env`), env);

  // Côté harness : streamable-http vers le proxy sidecar (pas d'auth — le proxy
  // injecte le token Bearer).
  sandbox.mcpServers[name] = {
    transport: "streamable-http",
    url: `http://${mcpIp}:${port}`,
    lifecycle: s.lifecycle || "lazy",
  };
  wired.push(`${name} → :${port} ${url}`);
}

for (const w of wired) console.error("  wired  " + w);
for (const s of skipped) console.error("  skip   " + s);
if (!wired.length) { console.error("[node] aucun serveur distant à câbler"); process.exit(3); }
if (dryRun) console.error("[node] dry-run : servers.d/*.env NON écrits");
process.stdout.write(JSON.stringify(sandbox, null, 2) + "\n");
NODE
rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$rc" -eq 3 ] && die "aucun serveur MCP distant à câbler dans $HOST_MCP"
  die "échec de la génération (node rc=$rc)"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] mcp.json sandbox généré (non écrit dans le volume, servers.d non touchés) :"
  cat "$SANDBOX_MCP" >&2
  exit 0
fi

# Écrit le mcp.json sandbox dans le volume du profil (chown agent).
CFG_BASENAME="mcp.json"
podman run --rm \
  -v "${HARNESS_HOME_VOL}:/vol:Z" \
  -v "${SANDBOX_MCP}:/tmp/mcp.json:ro,Z" \
  --entrypoint "" "$AGENT_IMAGE" bash -c '
    set -e
    cp /tmp/mcp.json "/vol/'"$CFG_BASENAME"'"
    chown "$(id -u agent):$(id -g agent)" "/vol/'"$CFG_BASENAME"'"
    echo "mcp.json sandbox écrit dans le volume"
  '

log "fait. Serveurs câblés sur le sidecar (servers.d-proxy/) ; mcp.json sandbox = streamable-http."
log "Lance le harness. Si OAuth auto échoue, les instructions sont dans : podman logs mcp-proxy"
log "Le token vit dans le sidecar (volume ${MCP_AUTH_VOL:-agent-mcp-auth}) — jamais dans le harness."
