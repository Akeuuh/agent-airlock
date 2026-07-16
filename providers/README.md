# Provider Catalog

A **provider** = an auth key **and** its egress domain(s), **coupled** in a single file.
Decoupled from the harness: the same provider works with `pi`, `opencode`, etc.

## Format `providers/<name>.env`

```bash
PROVIDER_KEYS="DEEPSEEK_API_KEY"        # env var name(s) (space-separated)
PROVIDER_DOMAINS="api.deepseek.com"     # egress domain(s); .example.com = includes subdomains
# PROVIDER_AUTH="oauth"                 # optional: subscription-based provider (login via /login)
# PROVIDER_CALLBACK_PORT="53692"        # optional: OAuth loopback port to publish VM→host
# PROVIDER_RUN_ENV="PI_OAUTH_CALLBACK_HOST=0.0.0.0"  # optional: env injected at run
```

Two families:
- **API key** (default): `PROVIDER_KEYS` set → the key is injected at runtime.
- **Subscription / OAuth** (`PROVIDER_AUTH="oauth"`, `PROVIDER_KEYS=""`): no key;
  login via `/login` in the harness (device flow), token persisted in the profile volume.
  The launcher resyncs the VM clock (timestamped token) and the doctor checks the login.
  E.g. `github-copilot`.

## Selection (for apikey harnesses)

Priority: `--provider X` (run override) > `$AGENT_PROVIDERS` (env) >
`HARNESS_PROVIDERS` (profile default, in `profile.env`).

For each active provider, the launcher:
- injects its keys (resolved from `profiles/<name>/secrets.env` then host env);
- adds its domains to the rendered egress allowlist (proxy recreated if the set changes).

→ **Key and domain can no longer diverge**: adding a provider = 1 selection.

## Adding a Provider

Create `providers/<name>.env` with its 2 lines, then activate it
(`--provider <name>` or `HARNESS_PROVIDERS="… <name>"`). See
[`../docs/profiles.md`](../docs/profiles.md).

## Provided Providers

anthropic · openai · google · deepseek · openrouter · groq · mistral · xai
(API key) · **github-copilot**, **claude-pro** (subscription OAuth).
(Custom endpoints — Azure, local gateways, custom base URLs: add a dedicated `.env`.)
