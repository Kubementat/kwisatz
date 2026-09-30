# Postiz auto-configuration of first organization + admin user

**Date:** 2026-09-30
**Scope:** gitroomhq/postiz-app **v2.24.0** (Docker Compose self-host), no SMTP provider configured
**Method:** All endpoint paths, payloads, and behavior below verified against the actual source at tag `v2.24.0`
(cloned from GitHub and grepped), plus docs.postiz.com and postiz-docker-compose. File references are relative
to the postiz-app repo at that tag.

**Bottom line:** There is **no env var, seed mechanism, or CLI** to pre-create the admin. But the registration
endpoint `POST /api/auth/register` is a plain JSON REST endpoint, fully scriptable, and **without an email
provider the user is auto-activated** (`activated: provider !== 'LOCAL' || !hasEmail`), so the whole
org + SUPERADMIN + API-key bootstrap works with zero SMTP. Idempotency is achieved by login-first /
register-fallback with a fixed email (duplicate register → `400 "Email already exists"`).

---

## 1. Env vars that seed users/orgs — **none exist**

**Confidence: verified (negative finding)**

- Checked `.env.example` (main) and the full Configuration Reference (docs.postiz.com): no `ADMIN_*`,
  `SEED*`, `INIT*`, `FIRST_USER*`, or similar variables. There is no seeding of any kind.
- Checked `gitroomhq/postiz-docker-compose`: repo contains only `docker-compose.yaml`, `docker-compose.dev.yaml`,
  `dynamicconfig/`, README. **No init/entrypoint/seed scripts.**
- The only related variable is `DISABLE_REGISTRATION`:
  - From `apps/backend/src/services/auth/auth.service.ts`, `canRegister()`:

    ```ts
    async canRegister(provider: string) {
      if (process.env.DISABLE_REGISTRATION !== 'true' || provider === Provider.GENERIC) {
        return true;
      }
      return (await this._organizationService.getCount()) === 0;
    }
    ```

  - So with `DISABLE_REGISTRATION=true`, **the very first registration is still allowed** (org count == 0),
    and every registration after that is blocked with `400 "Registration is disabled"`. This is exactly the
    safety primitive a setup script wants: set it to `true` in `.env`, start containers, run the script once.
- No user-creation happens at startup; the image's entrypoint only runs `prisma-db-push` (schema sync) and the
  app. (Root `package.json`: `"pm2-run": "pm2 delete all || true && pnpm run prisma-db-push && pnpm run --parallel pm2 && pm2 logs"`.)

## 2. Registration API endpoint — **yes, scriptable, verified from source**

**Confidence: verified (source at v2.24.0)**

Architecture: NestJS backend on container port 3000, nginx on port 5000 proxies `location /api/ → http://localhost:3000/`
(strips the `/api` prefix — `var/docker/nginx.conf`). So every backend route `X` is reachable as `POST {MAIN_URL}/api/X`.

### Endpoint

```
POST {MAIN_URL}/api/auth/register
Content-Type: application/json

{
  "email": "admin@example.com",
  "password": "S3cret!",
  "company": "My Org",
  "provider": "LOCAL"
}
```

Payload = `CreateOrgUserDto` (`libraries/nestjs-libraries/src/dtos/auth/create.org.user.dto.ts`), enforced by a
global `ValidationPipe`:

| field  | constraints                                  |
|--------|----------------------------------------------|
| `email`  | `@IsEmail`, required (when no `providerToken`) |
| `password` | string, 3–64 chars, required (when no `providerToken`) |
| `company`| string, 3–128 chars, required               |
| `provider` | string, required — use `"LOCAL"`           |

Controller: `@Post('/register')` in `apps/backend/src/api/routes/auth.controller.ts`.
Related endpoints (same controller):

- `GET  {MAIN_URL}/api/auth/can-register` → `{ "register": true|false }`
- `POST {MAIN_URL}/api/auth/login` with `LoginUserDto` = `{ "email", "password", "provider": "LOCAL" }`
- `POST {MAIN_URL}/api/auth/resend-activation` (irrelevant without SMTP)

Neither register nor login has a throttler decorator (only the farcaster routes are rate-limited), and the
compose file's `API_LIMIT: 30` applies to the public API, not these.

### What registration does (verified: `organization.repository.ts` → `createOrgAndUser`, line ~461)

```ts
return this._organization.model.organization.create({
  data: {
    name: body.company,
    apiKey: AuthService.fixedEncryption(makeSecureId(20)),  // ← API key auto-created!
    allowTrial: true,
    isTrailing: true,
    users: { create: {
      role: Role.SUPERADMIN,
      user: { create: {
        activated: body.provider !== 'LOCAL' || !hasEmail,   // ← key line
        email: body.email,
        password: body.password ? AuthService.hashPassword(body.password) : '',
        providerName: body.provider, ... } } } },
  }, ...
});
```

- **Every** registration creates a **new Organization** whose sole user is `Role.SUPERADMIN`. There is no
  "first user" special case: with default settings any new email gets its own fresh org. The first user's org is
  not more privileged than any later one (hence `DISABLE_REGISTRATION=true` for safety).
- **An org `apiKey` (public API key) is generated automatically** at org creation — nothing to do.
- `hasEmail` = `EmailService.hasProvider()` = "not EmptyProvider" (`email.service.ts`: `EMAIL_PROVIDER=resend`
  or `nodemailer`; `default: new EmptyProvider()`). Your log line `Email service provider: no provider` is the
  `EmptyProvider`.
- Success response (no email provider): `200 { "register": true }` plus cookies:
  - `auth` = JWT (whole user object signed with `JWT_SECRET`), `httpOnly`, `secure` unless `NOT_SECURED=true`
    (then the JWT is also returned in the **`auth` response header** — handy for scripts on plain HTTP).
  - `showorg` = new org id.
  - If an email provider *were* configured: `200 { "activate": true }` and no auth cookie (must click the
    activation link). Not your case.

### Idempotency behavior (verified in `auth.service.ts` → `routeAuth`)

- Repeat register with the **same email** → throws `'Email already exists'` → **`400`** with that message body
  (controller catches and `response.status(400).send(e.message)`).
- Register with a **different email** → **succeeds and creates a second org** (no 409, no limit).
- With `DISABLE_REGISTRATION=true` after the first org exists → **`400 "Registration is disabled"`**.
- So: no 409 anywhere; "already exists" is a `400` with a **distinguishable message** → treat it as success.

## 3. CLI inside the postiz-app image — **none**

**Confidence: verified (negative finding)**

- Production image is built from `Dockerfile.dev`: `node:22-bookworm-slim` + nginx + `pnpm` + `pm2`,
  `CMD ["sh","-c","nginx && pnpm run pm2"]`. No admin/CLI binaries.
- No package script, prisma seed file, or `docker exec`-able command creates users (grep of `package.json`
  scripts and repo for seed/migrate-user commands: nothing).
- The only practical "CLI" escape hatches: `pnpm run prisma` inside the container (schema commands, not user
  creation), or `docker exec` into the **postgres container** and raw SQL. Passwords are **bcrypt**
  (`hashSync/compareSync` from `bcrypt` in `libraries/helpers/src/auth/auth.service.ts`), so a SQL fallback
  would require generating a bcrypt hash and inserting into `"User"`, `"Organization"`, `"UserOrganization"` —
  fragile, don't. The API route in §2/§7 is far better.

## 4. `activated` flag / SMTP requirement

**Confidence: verified (source)**

- On **login** (`routeAuth`, LOCAL branch): `if (!user.activated) throw new Error('User is not activated')` →
  `400`. Unactivated users cannot log in.
- The auth middleware also re-checks DB `activated` for every authenticated request
  (`apps/backend/src/services/auth/auth.middleware.ts`).
- **Signup works fine with no email provider.** `EmailService.selectProvider()` falls back to `EmptyProvider`
  when `EMAIL_PROVIDER` is unset, and `createOrgAndUser` sets
  `activated: body.provider !== 'LOCAL' || !hasEmail` → **LOCAL + no provider ⇒ `activated: true` immediately**.
- `register` still *calls* `sendEmail` (a Temporal `sendEmailWorkflow` signal), but with no provider it is a
  no-op. (Minor caveat: if the **Temporal** service itself were down, `await sendEmail` could reject — but your
  compose runs Temporal, and the UI flow does the same call, so this is not a real risk in your setup.)
- Corroborated by official docs (docs.postiz.com, Email configuration / troubleshooting):
  "If no email provider is configured, user activation emails won't go out — but Postiz auto-activates users in
  that mode, so signup still works." (The Cloudron forum "not activated" lockout only happens when an SMTP/
  Resend provider *is* configured but mail doesn't arrive; fix is `UPDATE "User" SET activated = 't'`.)

## 5. API key creation

**Confidence: verified (source)**

- The **org-level public API key is created automatically** at registration (`apiKey: fixedEncryption(makeSecureId(20))`).
  There is no "create API key" endpoint; the UI (Account settings → API) just displays the existing one.
- To read it programmatically: `GET {MAIN_URL}/api/user/self`, authenticated, returns (users.controller.ts):

  ```ts
  publicApi: (role === 'SUPERADMIN' || role === 'ADMIN') ? organization?.apiKey : ''
  ```

  Auth is accepted via `auth` header **or** `auth` cookie (JWT) — `const auth = req.headers.auth || req.cookies.auth`
  in `auth.middleware.ts`.
- Use that exact `publicApi` value as the `Authorization` header of the public API — **as returned, no decoding**:
  the value is reversibly obfuscated at rest (`fixedEncryption`) and the frontend sends it back verbatim;
  `PublicAuthMiddleware` (`apps/backend/src/services/auth/public.auth.middleware.ts`) matches it raw via
  `getOrgByApiKey(auth)`. (Docs confirm header name `Authorization`.)
- Public API base: `{MAIN_URL}/api/public/v1` (backend controller `@Controller('/public/v1')`
  in `apps/backend/src/public-api/routes/v1/public.integrations.controller.ts` + nginx `/api/` strip).
- Note: API key is **per-organization, not per-user** (GitHub issue #1511 "Per-user API tokens" is open —
  confirms it's a known limitation, i.e. one shared key per org).

## 6. Idempotency summary

| call | repeat result | HTTP |
|---|---|---|
| `POST /api/auth/register` (same email) | `Email already exists` | 400 |
| `POST /api/auth/register` (new email, `DISABLE_REGISTRATION` unset) | **creates a new org** | 200 |
| `POST /api/auth/register` (new email, `DISABLE_REGISTRATION=true`) | `Registration is disabled` | 400 |
| `POST /api/auth/login` (good creds) | always succeeds, returns auth JWT | 200 |
| `GET /api/user/self` (same JWT) | returns `publicApi` key | 200 |

There is **no 409 and no upsert** — idempotency must be done in the script (fixed email + login-first).

## 7. Recommended setup script (idempotent, no SMTP)

Verified against v2.24.0 source. Requires `curl` + `jq` (or `python3 -c 'import json'`).

**Compose `.env`:** set `DISABLE_REGISTRATION: "true"` (allows exactly the first signup, then locks the door —
recommended by official guides anyway) and leave `RESEND_API_KEY`/`EMAIL_*` unset (auto-activation).

```bash
#!/usr/bin/env bash
set -euo pipefail

BASE="${MAIN_URL:-http://localhost:5000}/api"
EMAIL="admin@$(id -u >/dev/null && echo example.com)"   # fix to your admin email
PASSWORD="replace-with-secure-password"
COMPANY="kwisatz"

jar="$(mktemp)"; trap 'rm -f "$jar"' EXIT
login() {
  curl -sf -o /dev/null -c "$jar" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"provider\":\"LOCAL\"}" \
    "$BASE/auth/login"
}
register() {
  local body
  body=$(curl -s -o /dev/null -w '%{http_code}' -c "$jar" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"company\":\"$COMPANY\",\"provider\":\"LOCAL\"}" \
    "$BASE/auth/register")
  [ "$body" = "200" ]
}

# 1) Idempotent bootstrap: try login; if the account doesn't exist yet (400/404), register.
#    Re-running after the org exists: register would 400 "Email already exists" — we don't even
#    get there because login succeeds.
if login; then
  echo "org+admin already exist"
else
  register || { echo "register failed (existing user with different password? fix manually)"; exit 1; }
  echo "created org + SUPERADMIN user"
fi

# 2) Pull the JWT out of the cookie jar (cookie name: auth) and fetch the auto-generated API key.
JWT=$(awk '$6 == "auth" {print $7}' "$jar")
[ -n "$JWT" ] || { echo "no auth cookie returned"; exit 1; }

API_KEY=$(curl -sf -H "auth: $JWT" "$BASE/user/self" | jq -r .publicApi)
echo "$API_KEY" > postiz-api-key   # reuse verbatim as:  Authorization: <key>
echo "API key: $API_KEY"

# 3) Smoke-test the public API with the key:
curl -sf -H "Authorization: $API_KEY" "$BASE/public/v1/integrations" >/dev/null && echo "public API OK"
```

Notes:

- Works over plain HTTP: the `secure` cookie flag doesn't affect curl; even easier if you set `NOT_SECURED=true`
  (JWT then also arrives in the `auth` response header).
- `DISABLE_REGISTRATION=true` + fixed email makes the script double-safe: even if the password check is wrong,
  a second org can never be created by accident, and any other human hitting the signup page gets `400
  "Registration is disabled"`.
- If the instance already has an org with a *different* admin email, the script's login fails and register is
  blocked — handle that one-time case manually (UI or `UPDATE "User"` in Postgres).
- Alternative if you must not depend on the app at all: `docker compose exec postgres psql ...`
  `UPDATE "User" SET activated = true WHERE email = ...` is the documented unstick for the SMTP-configured case
  (Cloudron forum + docs), but with no email provider you never need it.

---

## Sources

- Source verified at tag `v2.24.0`: `apps/backend/src/api/routes/auth.controller.ts`,
  `apps/backend/src/services/auth/auth.service.ts`, `apps/backend/src/services/auth/auth.middleware.ts`,
  `apps/backend/src/services/auth/public.auth.middleware.ts`,
  `apps/backend/src/api/routes/users.controller.ts` (`/user/self`, `publicApi`),
  `libraries/nestjs-libraries/src/database/prisma/organizations/organization.repository.ts` (`createOrgAndUser`),
  `libraries/nestjs-libraries/src/services/email.service.ts`, `libraries/nestjs-libraries/src/dtos/auth/*.ts`,
  `apps/backend/src/public-api/routes/v1/public.integrations.controller.ts`, `var/docker/nginx.conf`,
  `Dockerfile.dev`, root `package.json`.
- docs.postiz.com: Configuration Reference (`DISABLE_REGISTRATION`, email/activation gating), Email
  configuration, public-api/introduction (`Authorization` header), quickstart (first account = org owner,
  disable registration afterwards).
- gitroomhq/postiz-docker-compose (no seed mechanism), gitroomhq/postiz-docs troubleshooting/self-host ("no
  provider ⇒ auto-activate"), forum.cloudron.io "Postiz won't log in - not activated", GitHub issue #1511
  (per-user API tokens open → key is org-wide), newreleases v1.29.1 release notes (introduction of
  `DISABLE_REGISTRATION`).
