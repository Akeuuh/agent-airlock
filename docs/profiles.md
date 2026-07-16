# Profiles — Multi-Harness Support

The sandbox is **harness-agnostic**. Everything specific to an agent (Claude Code, pi,
opencode…) lives in a **profile**; the foundation (internal network, sidecars, egress,
entrypoint) is generic and has no harness hardcoded.

> TL;DR: **adding a harness = creating a `profiles/<name>/` directory (4-5 files).**
> No scripts to modify.

---

## Profile Anatomy

```
profiles/<name>/
├── profile.env          # ALL harness variables (sourced by launcher/doctor)
├── install.sh           # how to install the binary in the image (run as root at build time)
├── allowlist.conf       # squid fragment: harness INFRA domains (providers come from catalog)
├── secrets.env.sample   # (apikey auth) key template — copy to secrets.env (gitignored)
└── config/              # "managed" bundle seeded into config-dir at run (mcp, skills, settings…)
```

### `profile.env`

| Variable | Role |
|---|---|
| `HARNESS_NAME` | profile name (= directory name) |
| `HARNESS_BIN` | binary launched in the container |
| `HARNESS_LAUNCH_ARGS` | arguments passed to the binary (word-split) |
| `HARNESS_CONFIG_DIR` | config directory in the container (mounted on persistent volume) |
| `HARNESS_CONFIG_ENV` | env var name that locates the config (empty if fixed path) |
| `HARNESS_HOME_VOL` | persistent volume for login/config — **one per harness** |
| `HARNESS_AUTH_MODE` | `oauth` (browser login + persisted credentials) or `apikey` |
| `HARNESS_CREDENTIALS_FILE` | (oauth) file proving login, e.g. `.credentials.json` |
| `HARNESS_HOST_CONFIG_DIR` | harness config dir on the **host** — source for `agent-import-auth.sh`/`agent-import-config.sh` |
| `HARNESS_HOST_CONFIG_ITEMS` | allowlist of config items imported from host (symlinks dereferenced, secrets excluded) |
| `HARNESS_PROVIDERS` | (apikey) active providers by default, e.g. `"anthropic openai"` (catalog `providers/`) |
| `HARNESS_ENV_KEYS` | (apikey) keys **outside the catalog** to also inject — optional |
| `HARNESS_RUN_ENV` | additional env vars at run (`KEY=VAL` space-separated) |

---

## Harness Resolution at Launch

Priority (implemented in `lib/profiles.sh` → `profile_resolve`):

1. **`--profile X`** argument → one-shot override ("just this time").
2. **`--choose` / `--menu`** → forces the picker even if a default is set.
3. **`$AGENT_PROFILE`** (in shell rc) → launches that harness directly, no menu
   ("always this one").
4. Otherwise → **single-choice picker** (↑/↓ to move, Enter to confirm) listing profiles.
   Without a TTY (pipe/CI), falls back to numbered menu.

If the harness image doesn't exist yet, the launcher **auto-builds** it (base +
`install.sh`). If the requested profile doesn't exist, it offers to **scaffold** a
pre-filled skeleton.

No on-disk memorization of the last choice: the default is `$AGENT_PROFILE`.

```sh
# Default "always this harness" + generic launcher
export AGENT_PROFILE=claude
alias agent='~/agent-airlock/bin/agent-sandbox.sh'

agent                    # → claude (default)
agent --profile pi       # → pi, this time only
agent --choose           # → interactive menu
```

---

## Auth: `oauth` vs `apikey`

The mode is driven by `HARNESS_AUTH_MODE` (see also
[`authentication.md`](authentication.md)).

- **`oauth`** (e.g. `claude`): browser login, credentials persisted in the
  `HARNESS_HOME_VOL` volume. The launcher **resyncs the VM clock** (drift causes token
  rejection → logout). The doctor checks for the presence of `HARNESS_CREDENTIALS_FILE`.

- **`apikey`** (e.g. `pi`, `opencode`): **no** clock resync (no timestamped tokens).
  Keys come from **active providers** (see next section). Injection via **selective
  passthrough**: only the **names** of keys from active providers (+ those in
  `HARNESS_ENV_KEYS`) cross the container boundary (never the whole host env). Value
  resolved in order:
  1. `profiles/<name>/secrets.env` (gitignored, **takes priority**);
  2. otherwise, the host env.

  ```sh
  cp profiles/pi/secrets.env.sample profiles/pi/secrets.env
  $EDITOR profiles/pi/secrets.env          # ANTHROPIC_API_KEY=sk-ant-...
  ```

---

## Providers — Decoupled Catalog (apikey Harnesses)

A **provider** = an auth key **and** its egress domain(s), **coupled** in a single file
`providers/<name>.env`. Decoupled from the harness: the same provider works with `pi`,
`opencode`, etc. — key and domain can never diverge.

```bash
# providers/deepseek.env
PROVIDER_KEYS="DEEPSEEK_API_KEY"
PROVIDER_DOMAINS="api.deepseek.com"
```

**Selection — checkbox picker at launch (recommended).** On an apikey harness, if no
choice is yet memorized, the launcher shows a **multi-choice picker**: ↑/↓ to move,
**space** to check/uncheck, **Enter** to confirm. Your choice is **persisted** in
`profiles/<name>/.providers` (gitignored): subsequent runs don't ask again. No magic
command to remember.

```
Providers — ↑/↓ move, space toggle, Enter confirm
❯ [x] anthropic
  [ ] deepseek
  [x] github-copilot
  [ ] google
  ...
```

(pre-checked = `HARNESS_PROVIDERS` default. Without TTY — pipe/CI — falls back to
numbered menu.)

**Full resolution** (priority):
`--provider X` (one-shot) > `--choose-providers` (reopen menu + persist) >
`$AGENT_PROVIDERS` (env, one-shot) > persisted choice `.providers` > menu (1st run) >
`HARNESS_PROVIDERS` (profile default).

For each active provider, the launcher injects its keys **and** adds its domains to the
egress allowlist. The egress sidecar carries a label `agent-airlock.providers=<sig>` →
recreated only when the set changes (persisted choice = no churn = stable login).

```sh
agent --profile pi                    # picker on 1st run, then memorized choice
agent --profile pi --choose-providers # reopen picker (add / remove)
agent --profile pi --provider deepseek # force deepseek this time (without touching saved choice)
```

**Add or remove a provider**: `agent --profile pi --choose-providers`. The picker reopens
with **your current selection already checked** — space to check a new one, space to
uncheck an existing one, Enter to confirm. The new choice replaces the old one in
`.providers`. (For a subscription provider, unchecking = closing its domains on the sandbox
side; logging out on the account side = `/logout` in the harness.)

### Enable DeepSeek (Full Example)

```sh
# 1. The provider already exists in the catalog (providers/deepseek.env). If not, create it.
# 2. Provide the key
echo 'DEEPSEEK_API_KEY=sk-...' >> profiles/pi/secrets.env
# 3. Activate it: menu (--choose-providers) or one-shot
agent --profile pi --choose-providers   # check deepseek → persisted
# 4. In pi, select the DeepSeek model (--provider / default model)
```

### GitHub Copilot (OAuth Subscription, NO Key)

Copilot is a **subscription** provider: no API key, but an OAuth login (GitHub device
flow). The `github-copilot` provider only opens the domains; login happens **inside pi**.

```sh
# 1. Launch pi; at the providers menu, check github-copilot (number) → persisted
agent --profile pi --choose-providers
# 2. IN pi: /login → GitHub Copilot → Enter (github.com)
#    pi displays a CODE + a URL (https://github.com/login/device).
# 3. On the host BROWSER: open the URL, paste the code, authorize.
# 4. Back in pi: /model → pick a Copilot model.
```

The token is stored in `~/.pi/agent/auth.json` = the persistent volume `agent-home-pi`
→ **login persists** across runs (no re-login). The `github-copilot` choice being
memorized (`.providers`), subsequent runs don't re-ask for the provider or the login.
The device flow is poll-based: **no callback port to publish**. The launcher resyncs the
VM clock (timestamped token, otherwise immediate logout).

> "model not supported": enable the model on GitHub's side (Copilot Chat → model picker →
> Enable).

### Claude Pro/Max (OAuth Subscription, NO Key)

Distinct from the `anthropic` provider (`ANTHROPIC_API_KEY`, token-billed): the
**`claude-pro`** provider uses your Claude Pro/Max subscription via OAuth. Unlike
Copilot's device flow, Anthropic's OAuth uses a **loopback callback** (fixed port
`53692`): the launcher **publishes this port** VM→host and makes pi bind on
`0.0.0.0` (`PI_OAUTH_CALLBACK_HOST`) so the browser completes the redirect.

```sh
# 1. Activate the claude-pro provider (picker)
agent --profile pi --choose-providers      # check claude-pro
# 2. IN pi: /login → Claude Pro/Max
# 3. Cmd+click (macOS) / Ctrl+click the displayed URL → the HOST browser opens
#    → authorize → the redirect http://localhost:53692 completes AUTOMATICALLY (published port).
```

> ⚠️ **Do NOT copy-paste the URL**: pi displays it as a **clickable link** (OSC 8,
> "Cmd+click to open"). Manually copied, the URL is long and gets wrapped at the terminal
> line break → `response_type` is missing → "missing response_type" error on claude.ai.
> **Click** the link: the full URL opens regardless of terminal width. (This is exactly
> Claude Code's behavior.)

**Fallbacks** if your terminal doesn't support clickable links (OSC 8):
- **Paste the code**: after authorization, Anthropic shows a code — paste it in pi
  (it accepts the code OR the full redirect URL).
- **Last resort — host login + import** (no URL copying): `pi` on the host → `/login`,
  then `~/agent-airlock/bin/agent-import-auth.sh --profile pi anthropic`.

The token goes to `~/.pi/agent/auth.json` (persistent volume); the token exchange happens
against `platform.claude.com` (opened by the provider). Persistent login, clock resync
as with any OAuth provider.

### Import Your Host Config into the Sandbox

You have a rich pi/claude/opencode config on your machine (settings, agents, extensions,
skills, memory…) and it shows up **blank** in the sandbox? That's intentional: the volume
starts clean. To seed it, opt-in and one-shot:

```sh
~/agent-airlock/bin/agent-import-config.sh --profile pi            # profile allowlist
~/agent-airlock/bin/agent-import-config.sh --profile pi --dry-run   # preview
~/agent-airlock/bin/agent-import-config.sh --profile pi skills settings.json  # subset
```

What gets imported = the `HARNESS_HOST_CONFIG_ITEMS` allowlist from the profile (in
`profile.env`), from `HARNESS_HOST_CONFIG_DIR` (your host config). Defaults:

| Profile | Host config | Default items |
|---|---|---|
| pi | `~/.pi/agent` | `settings.json models.json agents AGENTS.md extensions skills trust.json pi-memory npm` |
| claude | `~/.claude` | `settings.json CLAUDE.md agents commands` |
| opencode | `~/.config/opencode` | `opencode.json AGENTS.md commands skills` |

Guarantees (sandbox philosophy preserved):

- **Explicit & persistent**: you run it when you want, it persists in the volume; you can
  then **diverge** inside the sandbox (no automatic re-seed).
- **Symlinks dereferenced**: your config can point outside its directory (e.g. `../shared`)
  — the copy resolves links, so **no broken links** in the container.
- **Secrets refused**: `auth.json`, `.credentials.json`, `mcp-auth`… are blocked even if
  passed as arguments → use `agent-import-auth.sh` (which couples key ↔ egress).
- **Heavy state excluded**: `sessions/`, caches, `.skill-state` are never in the
  allowlist. (pi: `npm/` IS included — it's the `node_modules` where pi installs
  packages/deps; the script also creates a `node_modules → npm/node_modules` symlink
  so **local extensions** can resolve their dependencies (e.g. `zod`,
  `@modelcontextprotocol/sdk`) — without it, an extension that does
  `require('zod')` fails.)
- **Non-destructive merge**: only listed items are overwritten (host wins); the rest of
  the volume (including your login) is preserved.

> ⚠️ `settings.json`/`opencode.json` may set a `defaultProvider`/`enabledModels` whose
> egress is not open in the sandbox → the model fails (fail-closed). Check that active
> providers cover your default models. `mcp.json` is **not** copied as-is (see MCP
> section below — it gets wired to the sidecar).

### MCP (pi, claude, opencode) — Via the Sidecar Proxy with Automatic OAuth

All harnesses go through the same **proxy sidecar** (Node.js).

```sh
# 1. Wire your MCP servers to the sidecar:
~/agent-airlock/bin/agent-mcp-wire.sh --profile pi              # all remote servers
#    → generates servers.d-proxy/<name>.env (NAME/URL/PORT/CALLBACK_PORT)
#    → writes a sandbox mcp.json in the volume

# 2. Launch the harness:
agent --profile pi

# 3. The proxy attempts automatic OAuth. If the server doesn't support standard
#    discovery (Jira, Datadog…), it displays instructions in
#    `podman logs mcp-proxy` and waits for the token.
#
#    On the host (not in the sandbox):
#      pi → /mcp:auth jira → browser → authorize
#      agent-import-auth.sh --profile pi --mcp jira
#
#    The proxy auto-detects the token (5s poll).
#    Subsequent runs: token reused, zero interaction.
```

What the proxy does (proxy.js, ~300 lines):
- **Token present** → Bearer injection + immediate forward.
- **No token** → OAuth discovery (probes the server) + PKCE flow.
  - If discovery OK → callback published VM→host → URL → token saved.
  - If discovery fails (99% of cases) → instructions in logs + polls the token
    file every 5s. User imports the token with `agent-import-auth.sh --mcp <server>`,
    the proxy detects it and starts.

> 💡 **First reflex on MCP errors**: `podman logs mcp-proxy` (pi) or
> `podman logs mcp-remote` (claude/opencode). Instructions are there.

> 🔧 **Claude/opencode**: manually create `servers.d/<name>.env` (NAME, URL, PORT,
> CALLBACK_PORT) instead of using `agent-mcp-wire.sh`.

### Adding a Provider to the Catalog

Create `providers/<name>.env` with its two lines (`PROVIDER_KEYS`, `PROVIDER_DOMAINS`).
Custom endpoints (Azure, local gateway, custom base URL): a dedicated `.env` with the
right domain. Provided providers: anthropic, openai, google, deepseek, openrouter, groq,
mistral, xai (API key); github-copilot (OAuth subscription).

> ⚠️ Harness-side responsibility: the sandbox opens the network + injects the key, but you
> must **select the corresponding provider IN the harness** (pi `--provider`, opencode
> `/models`). Open network ≠ active provider in the agent.

---

## Egress: Strict Per-Profile Allowlist

The egress proxy is a shared sidecar, but **each harness has its own allowlist**.
The launcher renders a runtime `squid.conf` = `egress/squid.base.conf` (ports + `deny all`)
with, injected at the `@@ALLOWLIST@@` marker: the profile **infra**
(`profiles/<name>/allowlist.conf` — e.g. `models.dev`, npm/github) **+ the domains of
active providers** (catalog). Provider domains are therefore NOT in `allowlist.conf`:
they follow the `HARNESS_PROVIDERS`/`--provider` selection.

The sidecar carries the labels `agent-airlock.profile=<name>` and
`agent-airlock.providers=<sig>`. At launch, if it's running with a **different** profile
or a **different** provider set, it is **recreated** — allowlists are never merged
(isolation, minimal surface). Details in [`egress-allowlist.md`](egress-allowlist.md).

---

## Adding a Harness — Step by Step

```sh
# 1. Scaffold (or copy a similar existing profile)
~/agent-airlock/bin/agent-sandbox.sh --profile myharness   # answer "y" → creates skeleton
#   ↳ then edit profiles/myharness/{profile.env,install.sh,allowlist.conf}

# 2. Build the harness image (or let the launcher build on the fly)
make build-harness PROFILE=myharness

# 3. (apikey) provide the key
cp profiles/myharness/secrets.env.sample profiles/myharness/secrets.env
$EDITOR profiles/myharness/secrets.env

# 4. Verify
~/agent-airlock/bin/agent-doctor.sh --profile myharness

# 5. Launch
~/agent-airlock/bin/agent-sandbox.sh --profile myharness
```

---

## Provided Profiles

| Profile | Auth | Config-dir | Install | Notes |
|---|---|---|---|---|
| `claude` | oauth | `~/.claude` | `npm i -g @anthropic-ai/claude-code` | subscription login; native MCP (socat) |
| `pi` | apikey | `~/.pi/agent` | `npm i -g @earendil-works/pi-coding-agent` | provider-agnostic (`HARNESS_PROVIDERS`); **no native MCP** (extensions) |
| `opencode` | apikey | `~/.config/opencode` | `npm i -g opencode-ai` | native MCP (`config.json`); sessions not persisted |

### Specifics

- **pi**: does **not** have built-in MCP (workflows go through extensions), so the
  mcp-remote sidecar's socat tunnel remains unused unless a dedicated extension is used.
  Provider(s) via `HARNESS_PROVIDERS` / `--provider` (catalog `providers/`);
  `allowlist.conf` only contains infra (npm/github if installing at runtime).
- **opencode**: fetches the provider/model list from `models.dev` at startup (domain
  already in the allowlist). Auth goes through env (apikey); its sessions/state live in
  `~/.local/share/opencode` — **not persisted** by the config volume (ephemeral per run).
  The MCP tunnel is wired via `config/config.json`.
