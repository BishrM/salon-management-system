# SalonOps — Hosted staging setup

Status: **staging is running** (set up 2026-11-18). Test data only — never real salon takings, never
real staff phone numbers. Production has **not** been created.

| Item | Value |
|---|---|
| App URL | https://salonops-staging.vercel.app (HTTPS, Vercel region `bom1`, Hobby/free plan) |
| Vercel project | `salonops-staging` (team `bishrpapt-5536s-projects`), Node 24.x, framework Next.js |
| Supabase project | `salonops-staging`, ref `nzwmfoixqffwqzntvscn`, region `ap-south-1`, Postgres 17, free plan |
| Branch deployed | `salonops-v1` (never `main`) |
| Test logins | owner, manager, outsider (second outlet); head and counter are legacy and grant nothing once `…001700` is applied — a HUDCO **Shop/Staff** login must then be created (D-28) — `*@salonops-staging.test`, random passwords kept **only** in the git-ignored `.env.staging.local` on the developer Mac (move them to the team password manager) |
| Outlets | "Staging Test Salon" and "Isolation Test Outlet (staging)" (simulated data) |

**Deployments:** the Vercel project is linked to GitHub `BishrM/salon-management-system` with production
branch `salonops-v1`; every push to `salonops-v1` deploys to the staging URL. The project's Ignored
Build Step (`if [ "$VERCEL_GIT_COMMIT_REF" = "salonops-v1" ]; then exit 1; else exit 0; fi`) skips all
other branches, including `main`, so no preview or production build is made from them. The CLI deploy
in §2.5 remains as a fallback.

---

## 1. Supabase (staging project)

### 1.1 Project
| Setting | Value | Why |
|---|---|---|
| Plan | Free is enough for staging | No real data; production needs a paid plan for backups (§1.7) |
| Region | `ap-south-1` (Mumbai) | Same region as Vercel `bom1`; Indian users |
| Postgres version | 17 (the local stack runs `supabase/postgres:17.12.0.000`) | Migrations were verified on 17.12 |
| Project name | `salonops-staging` | Keep staging and production separate projects |
| Database password | generated, stored in a password manager | Needed only for `supabase link` / `db push` |

### 1.2 Database migrations
Apply the 11 files in `supabase/migrations/` in filename order, once, with the CLI:
```bash
supabase link --project-ref nzwmfoixqffwqzntvscn
export SUPABASE_DB_PASSWORD=...      # from the password manager
supabase db push --remote --dry-run  # CLI 3.x targets the LOCAL stack unless --remote is given
supabase db push --remote --yes      # applies migrations only; it does NOT run seed.sql
```
- Migrations are one-shot (they `create` objects; re-running one fails on purpose). The CLI's
  migration history table prevents double application. Never edit an applied migration — add one.
- Verified 2026-11-18 on a fresh Supabase Postgres 17.12 with the Auth schema applied: all 11 apply,
  the resulting schema is identical to the local stack (same tables, policies, triggers and function
  hash), and the pgTAP suite passes (330/330).
- Optional verification against staging (needs the database URL; runs inside transactions that roll back):
  `supabase test db --remote --yes` — done 2026-11-18: **330/330 pass on staging**, nothing persisted.
- 2026-11-19: migration 12 (`…001200_audit_global_rows`) pushed with `db push --remote --yes`; fresh
  PostgreSQL 17 + 12 migrations: pgTAP 334/334. Without `SUPABASE_DB_PASSWORD` exported, CLI 3.2's
  temporary login role cannot create the `tests` schema, so `test db --remote` needs the password
  (`--db-url`, see `RELEASE_READINESS.md` §13). Read-only checks work without it:
  `supabase db query --remote --read-only "<sql>"`.

### 1.3 Extensions
| Extension | Created by | Notes |
|---|---|---|
| `btree_gist` | migration `…000100` (`create extension if not exists … with schema extensions`) | staff assignment overlap constraint |
| `pgcrypto` | preinstalled on Supabase | used only by `seed.sql` (local) |
| `pgtap` | `supabase test db` (tests only) | not needed at runtime |
No other database configuration is required: Realtime publication membership (`entries`,
`closing_events`), RLS, grants and the RPC allow-list are all inside the migrations.

### 1.4 Auth (applied with `supabase config push`)
`supabase/config.toml` has a `[remotes.staging]` block (project ref, site URL, redirect URLs, and
overrides that keep hosted defaults for email rate limit, MFA, pooler size and vector storage).
`supabase config diff` must show 0 differences; `supabase config push --yes` applies changes.

| Setting | Value |
|---|---|
| Providers | **Email** only (password sign-in). Disable all OAuth providers. |
| Allow new users to sign up | **Off** (owner creates logins in Admin → Users; `config.toml` has `enable_signup = false` locally) |
| Confirm email | Off is acceptable (logins are created with `email_confirm: true` by the server action; no SMTP is configured) |
| Minimum password length | 8 (app also requires a letter and a digit) |
| Site URL | the staging Vercel URL, e.g. `https://salonops-staging.vercel.app` |
| Redirect URLs | `https://salonops-staging.vercel.app/**` and, if previews are used, `https://*-<team-slug>.vercel.app/**` |
| JWT expiry | 3600 s (default; matches local) |
| Refresh token rotation | On (default) |
The app uses only `signInWithPassword` and `signOut`; it has no magic-link, OAuth or password-reset
callback route, so redirect URLs matter only if those are enabled later.

### 1.5 RLS requirements (already enforced by migrations — verify, do not change)
- Every table in `public` has RLS enabled (21 tables); `anon` has no table or function privileges.
- `authenticated` has `SELECT` only; all writes go through 37 `SECURITY DEFINER` RPCs with
  `search_path = ''`, each checking a permission in the target outlet.
- After `db push`, run in the SQL editor and expect zero rows:
  ```sql
  select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  select table_name, privilege_type from information_schema.role_table_grants
   where table_schema = 'public' and grantee in ('anon','authenticated') and privilege_type <> 'SELECT';
  ```
- Do not expose the `app` schema in API settings (Exposed schemas = `public`, `graphql_public`).

### 1.6 Bootstrap and test accounts
**Never run `supabase/seed.sql` on a hosted project**: its passwords follow a published pattern and the
staging URL is reachable from the internet.
1. Create the owner with the Auth admin API (or Dashboard → Authentication → Add user, "Auto confirm"),
   strong random password. Copy the user id. (Done: owner + a second-outlet owner.)
2. SQL editor (runs as `postgres`):
   ```sql
   select app.bootstrap_outlet('HUDCO Big Boss (STAGING)', 'Test address', '<owner user id>');
   ```
3. Sign in to staging as that owner → Admin → Setup checklist: cutoff (04:00 suggested, B1),
   denominations, test employees (invented names), catalogue, then Admin → Logins → Create login for
   test `manager` and the outlet's one **Shop/Staff** login (role "Shop/Staff", each with its own strong
   password), then the initial float. Employees never get logins (D-28).
4. For isolation checks, bootstrap a second outlet with a second owner.
5. Record test credentials in the team password manager, not in the repository.

### 1.7 Backup and recovery
| Environment | Requirement |
|---|---|
| Staging | None required (test data; re-creatable from migrations + §1.6). Free plan has no downloadable backups. |
| Production | **Paid plan required** for daily backups (Pro); PITR optional add-on. Needs owner approval (cost). |
| Both | Reports → Download Excel monthly as an offline copy. Financial tables are insert-only/versioned with an audit log, so history is reconstructible from the database itself. |
| Devices | IndexedDB is not a backup; use Register → "Save pending entries" + Admin → Recover for a stuck tablet. |
Recovery drill to run once on staging before production: export a month to Excel, create a fresh
project, `db push`, bootstrap, and confirm the app works (a full data restore needs a paid-plan backup).

---

## 2. Vercel (staging)

| Setting | Value |
|---|---|
| Framework preset | Next.js (auto-detected; Next 16.4.6, React 19.1) |
| Root directory | repository root (`./`) — `package.json`, `next.config.ts` and `vercel.json` live there |
| Install command | `npm ci` (default with `package-lock.json`) |
| Build command | `npm run build` (= `next build --turbopack`) |
| Output | default (`.next`) |
| Node.js version | 22.x or 24.x (Next requires ≥ 20.9; CI and local use 24) |
| Region | `bom1` (from `vercel.json`) |
| Production branch | for staging, a dedicated `staging` branch or the `salonops-v1` branch — `main` should stay production |

### 2.1 Environment variables
| Variable | Class | Staging value | Production value | Scope in Vercel |
|---|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | **Public / client-side** | staging project URL | production project URL | Preview + Production |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | **Public / client-side** (publishable or legacy anon key; safe because RLS protects data) | staging key | production key | Preview + Production |
| `SUPABASE_SERVICE_ROLE_KEY` | **Server-only secret** — mark *Sensitive*; never `NEXT_PUBLIC_` | staging **secret key** (`sb_secret_…`) | production secret key | Preview + Production (server) |
| `NODE_ENV` | set by the platform | — | — | — |
| `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD` | **Development/test-only** (local pgTAP and concurrency scripts) | not set | not set | never in Vercel |
| `.env.local` values from `supabase status` | **Development/test-only** (local stack keys) | never copy to Vercel | — | — |
- The service-role key is read only in `lib/supabase/server.ts` (`import "server-only"`) by the owner's
  Create login action, after a `users.manage` check. CI fails the build if `service_role` or
  `SUPABASE_SERVICE_ROLE_KEY` appears in `.next/static`.
- Use **different** Supabase projects (and keys) for Preview and Production; Preview deployments must
  never point at production data.

### 2.1a Setting the variables (what actually worked)
```bash
supabase projects api-keys --project-ref nzwmfoixqffwqzntvscn --reveal -o json   # without --reveal the secret is MASKED
printf '%s' "$SECRET" | vercel env add SUPABASE_SERVICE_ROLE_KEY production --sensitive --force --yes
```
Pitfall found on staging: a masked/incorrect secret makes **Admin → Users → Create login** fail with
"Invalid API key" while everything else works. Redeploy after changing any variable.

### 2.2 Preview deployments
- Every pull request gets a preview URL; set Preview env vars to the **staging** project.
- Enable **Deployment Protection → Vercel Authentication** for Preview deployments so only team
  members can open them (available on all plans for previews — check the current plan terms before
  relying on it; do not buy anything without approval).
- Add the preview URL pattern to Supabase redirect URLs (§1.4) only if auth redirects are added later.

### 2.3 Authentication redirects
- Sign-in is a password form posting to Supabase; the session is an HTTP-only cookie set by
  `@supabase/ssr`. `proxy.ts` refreshes it and sends signed-out users to `/login`.
- No OAuth/magic link → no callback route. If email reset is added later, add
  `https://<staging-domain>/auth/callback` to Supabase redirect URLs.

### 2.4 After the first deploy (smoke test — done 2026-11-18, see RELEASE_READINESS §12)
1. Open `/login` over HTTPS; sign in as each test role; confirm Shop/Staff is denied Approvals/Reports/Admin.
2. Response headers on `/`: `X-Frame-Options: DENY`, `Strict-Transport-Security`, CSP `frame-ancestors 'none'`.
3. `curl https://<staging>/_next/static/...` bundle grep for `service_role` → nothing.
4. Register an entry on one browser and see it appear live on a second (Realtime).
5. Run `docs/TABLET_TEST_PLAN.md` and `docs/ACCOUNTING_ACCEPTANCE_TESTS.md` on staging.

### 2.5 Deploying without the GitHub link (fallback)
```bash
D=$(mktemp -d); git archive HEAD | tar -x -C "$D"; mkdir "$D/.vercel"; cp .vercel/project.json "$D/.vercel/"
(cd "$D" && vercel deploy --prod --yes)
```
Only committed files are uploaded (no `.env*`). "Production" here is the Vercel project's production
target of the **staging** project; it is not the salon's production system.
