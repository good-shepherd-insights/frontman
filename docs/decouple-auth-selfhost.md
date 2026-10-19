# Frontman: Decoupling from Auth & Self-Hosting the Backend

Forked from `frontman-ai/frontman` ("The AI agent that lives in your framework/browser").
Backend lives at `apps/frontman_server/` — a Phoenix 1.8 / Elixir 1.20 app.

## Auth architecture — 3 layers (only 1 depends on WorkOS)

### Layer 1 — Identity provider (WorkOS OAuth) — the only external dependency
- **File**: `apps/frontman_server/lib/frontman_server/accounts/workos.ex`
- Handles GitHub + Google OAuth via `api.workos.com`
- Exposed through `accounts.ex` (lines 382-404):
  - `get_oauth_authorization_url/3` — builds WorkOS auth URL
  - `authenticate_with_oauth/2` — exchanges code for user profile
  - `authenticate_with_email_verification/3` — completes email-verify flow
  - `link_provider`, `unlink_provider`, `list_user_identities` — identity management
- Routes (router.ex lines 59-74):
  - `GET /auth/:provider` → `OAuthController.request` → redirects to WorkOS
  - `GET /auth/callback` → `OAuthController.callback` → exchanges code
  - `GET /auth/verify-email` → email verification flow
- Configured in `config/runtime.exs` (lines 32-34):
  ```elixir
  config :workos, WorkOS.Client,
    api_key: env!("WORKOS_API_KEY", :string!),
    client_id: env!("WORKOS_CLIENT_ID", :string!)
  ```
  Both are **required** (the `!` in `env!`) in `:dev` and `:prod` — server won't boot without them.

### Layer 2 — Session & login (fully local)
- **File**: `frontman_server_web/user_auth.ex`
  - `build_session_token/1` → 32-byte random token, stored in DB, 14-day expiry
  - `verify_session_token_query/1` → validates against DB
  - `require_authenticated_user` plug → protects browser routes
  - `require_embedded_client_bearer_token` plug → protects API routes (Bearer token)
  - `log_in_user` / `log_out_user` → session lifecycle
- **File**: `frontman_server_web/controllers/user_session_controller.ex`
  - `POST /users/log-in` supports **password** (`email` + `password` via `Accounts.get_user_by_email_and_password` → Bcrypt)
  - `POST /users/log-in` supports **magic link** (`email` only → sends login link; `token` → confirms link)
  - Both are fully local — no WorkOS dependency
- **File**: `frontman_server/accounts/user.ex`
  - `User` schema has `hashed_password` field (Bcrypt)
  - `registration_changeset/3` accepts `email`, `name`, `password` — password registration is ready to use
  - `valid_password?/2` → Bcrypt verification

### Layer 3 — API bearer tokens (fully local)
- **File**: `frontman_server/accounts/user_token.ex`
  - `build_embedded_client_token/2` → SHA-256 hashed token, scoped to an origin, 90-day expiry
  - `verify_embedded_client_token_query/2` → validates token + origin
- **File**: `frontman_server_web/embedded_client_origin.ex`
  - Normalizes origin (`scheme://host[:port]`)
  - `http://` only allowed for localhost; everything else must be `https://`
- **Flow** (router lines 48-49, user_session_controller.ex line 41-47):
  1. User logs in (password or magic link) → session established
  2. `GET /users/popup-complete` → renders approval page for embedded client auth
  3. `POST /users/popup-complete` → `Accounts.generate_embedded_client_token(user, origin)` creates a bearer token
  4. Frontend uses token as `Authorization: Bearer <token>` + matching `Origin` header for all `/api` requests

**Key finding**: WorkOS is only consulted during the OAuth sign-in flow. Once a user is in the `users` table, sessions, API tokens, and everything else are handled entirely by the local database (PostgreSQL + Bcrypt + signed tokens). Password-based and magic-link login are already fully implemented — they just aren't the default path because the UI routes to `/auth/:provider`.

## How to decouple from WorkOS auth

### Step 1 — Make WorkOS env vars optional
In `config/runtime.exs`, change lines 32-34 from:
```elixir
if config_env() in [:dev, :prod] do
  config :workos, WorkOS.Client,
    api_key: env!("WORKOS_API_KEY", :string!),
    client_id: env!("WORKOS_CLIENT_ID", :string!)
end
```
to:
```elixir
if config_env() in [:dev, :prod] do
  config :workos, WorkOS.Client,
    api_key: env!("WORKOS_API_KEY", :string, nil),
    client_id: env!("WORKOS_CLIENT_ID", :string, nil)
end
```
(Change `env!` to `env` with `nil` default — the `!` raises on missing env vars.)

### Step 2 — Replace the OAuth login routes
The WorkOS flow enters through `/auth/:provider` (router lines 59-66). Options:

**Option A — Use existing password/magic-link login (simplest)**
The `UserSessionController` already supports `POST /users/log-in` with `email` + `password`. Just ensure users exist with `hashed_password` set (either via `Accounts` context or direct DB insert). Point the frontend login buttons to `/users/log-in` instead of `/auth/github` or `/auth/google`.

**Option B — Add a registration endpoint**
The `User` schema's `registration_changeset` exists but there's no `POST /users/register` route. Add a controller action that calls `Accounts` to create a user with a Bcrypt password hash.

**Option C — Plug in a different OAuth provider**
Write a new module with the same function signatures as `workos.ex` (`get_authorization_url`, `authenticate_with_code`, etc.) but using Google/Firebase Auth/Auth0/Ory directly. Swap the `defdelegate` targets in `accounts.ex` (lines 382-404).

### Step 3 — Remove WorkOS routes (optional)
If you don't need any OAuth, remove or comment out router blocks at lines 59-74 (`/auth` scopes). The `/auth/verify-email` flow is also WorkOS-specific — remove it if unused.

### Step 4 — API bearer token flow (unchanged)
No changes needed. After decoupling, API clients authenticate by:
1. User logs in via password/magic-link → browser session
2. `POST /users/popup-complete` → receives a bearer token scoped to the self-hosted origin
3. `Authorization: Bearer <token>` + `Origin: https://<your-domain>` on all `/api` requests

### Step 5 — Remove WorkOS env vars entirely
After the code changes above, remove `WORKOS_API_KEY` and `WORKOS_CLIENT_ID` from your environment. The server boots and runs fine without them.

## Self-hosting the backend

### What you need
- PostgreSQL (15+)
- Elixir 1.20, Erlang/OTP 29
- Node.js 24 (for asset compilation at build time)
- Docker (optional, simplifies deployment)

### Option A — Docker (simplest)
The repo already has `apps/frontman_server/Dockerfile` — a multi-stage build that:
1. Compiles Rescript assets (yarn workspaces)
2. Compiles Elixir deps + release (`mix release`)
3. Copies the release binary to `debian:bookworm-slim` runtime image

Run:
```bash
docker build -f apps/frontman_server/Dockerfile -t frontman-server .
docker run -p 4000:4000 \
  -e DATABASE_URL=ecto://user:pass@db:5432/frontman \
  -e SECRET_KEY_BASE=<mix phx.gen.secret> \
  -e CLOAK_KEY=<base64-key> \
  -e PHX_HOST=api.yourdomain.com \
  -e PHX_SERVER=true \
  frontman-server
```

### Option B — systemd (production-ready)
The repo has production deployment templates at `infra/production/`:
- `systemd/frontman-blue.service` / `frontman-green.service` — blue/green releases
- `Caddyfile.template` — reverse proxy with TLS
- `env.template` — full env var list

### Required env vars (from `env.template`)
| Var | Source |
|-----|--------|
| `DATABASE_URL` | PostgreSQL connection string |
| `SECRET_KEY_BASE` | `mix phx.gen.secret` (or `openssl rand -hex 32`) |
| `CLOAK_KEY` | Generate: `mix cloak.key.generate` or use existing value |
| `PHX_HOST` | Your self-hosted domain |
| `PHX_SERVER=true` | Start the web server (not just `iex -S mix`) |

### Optional env vars (after decoupling)
| Var | Status after decoupling |
|-----|----------------------|
| `WORKOS_API_KEY` | **Can be removed** — only needed for OAuth |
| `WORKOS_CLIENT_ID` | **Can be removed** — only needed for OAuth |
| `STRIPE_SECRET_KEY` | Required only if offering paid plans |
| `RESEND_API_KEY` | Required for email (magic links, password reset) |
| `DISCORD_NEW_USERS_WEBHOOK_URL` | Optional — webhook on new signups |
| `FRONTMAN_INTERNAL_DEV=true` | Dev-mode flag (see `.dev.env`) |

### Origin header requirement
The embedded client bearer token auth (`require_embedded_client_bearer_token` in `user_auth.ex:365`) checks the `Origin` header against the token's approved origin. When self-hosting, the API client's origin must match `PHX_HOST`. Use HTTPS (self-signed certs work for testing) — `http://` is only allowed for `localhost`/`127.0.0.1`/`::1`.

### Migrations
Run database migrations on first deploy:
```bash
# Docker
docker run --rm -e DATABASE_URL=ecto://... frontman-server mix ecto.create && mix ecto.migrate
# Or from source
cd apps/frontman_server && mix ecto.create && mix ecto.migrate
```

### After decoupling — minimal env
```
DATABASE_URL=ecto://frontman:YOURPASS@localhost/frontman_server_prod
SECRET_KEY_BASE=...
CLOAK_KEY=...
PHX_HOST=api.yourdomain.com
PHX_SERVER=true
RESEND_API_KEY=re_...  # only if you use email features
```
