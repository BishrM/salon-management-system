# SalonOps — Setup, testing, backup and deployment

## 1. Local development
Requirements: Node 24, npm, Docker (running, with ~10 GB free disk), Supabase CLI ≥ 2.

```bash
npm ci
supabase start            # local Postgres, Auth, Realtime; applies migrations + seed.sql
cp .env.example .env.local   # paste the API URL, publishable/anon key and service_role key printed by supabase start
npm run dev               # http://localhost:3000
```

Seed logins (**local only** — never seed a hosted project, its passwords are predictable; see `docs/STAGING_SETUP.md`): `owner@salonops.test` / `owner-Pass-1`, likewise `manager`, `shop` (the HUDCO
Shop/Staff login, D-28), `outsider` (owner of a second outlet, for isolation checks). The seed sets the cutoff to 04:00
and creates demo staff and products; the **initial float is not seeded** — sign in as owner and use
Admin → Cash float, as in production.

## 2. Environment variables
| Variable | Where | Purpose |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | browser + server | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | browser + server | publishable (anon) key — all data access is protected by RLS |
| `SUPABASE_SERVICE_ROLE_KEY` | **server only** | used only by the owner's "Create login" action; never prefix with `NEXT_PUBLIC_` |

## 3. Database migrations
All schema lives in `supabase/migrations/` (apply in filename order; never edit an applied migration —
add a new one):

| File | Content |
|---|---|
| `…000100_foundation` | helper schema, global `server_seq`, roles enum, insert-only trigger, audit log |
| `…000200_identity` | outlets, profiles, memberships (incl. acting head), staff, assignments, devices |
| `…000300_authorization` | membership validity, permission matrix, RLS, privileges |
| `…000400_m1_rpcs` | setup, staff, membership and delegation RPCs, bootstrap |
| `…000500_m1_completion` | product catalogue, temporary assignments, thresholds, outlet details |
| `…000600_operations_tables` | entries, food payments, sync op log, evidence guards |
| `…000700_closing_tables` | float, closings, immutable revisions, events, handovers, late reviews, Paytm |
| `…000800_register_engine` | business dates, timestamp classification, register ops, `sync_ops` |
| `…000900_closing_engine` | accounting, lifecycle, approval ordering, float, handovers, Paytm import |
| `…001000_security_and_grants` | RLS for new tables, RPC allow-list, Realtime |
| `…001100_paytm_import_changes` | Paytm re-import reports rows whose amount/status changed (never overwrites) |
| `…001300_food_void_and_withdraw` | paid-food "remove and cancel payment" in one op; `blocked_by`; sender can withdraw a failed op (D-22, D-23) |
| `…001200_audit_global_rows` | audit rows of `staff`/`profiles` visible only to `audit.read` holders of an outlet they belong to (D3) |
| `…001400_withdraw_blocked_op` | the session holding a blocked op can withdraw it (D-25) |
| `…001500_service_payment_method` | Cash / UPI-Paytm-Card on every service sale (D-26) |
| `…001600_shop_role` | adds the `shop` role value (own migration: an enum value cannot be used in the transaction that adds it) |
| `…001700_two_account_model` | Owner + one Shop/Staff login per outlet; head/counter grant nothing; dated employee deactivation; handover to any employee working that day (D-28, D-29, D-32) |
| `…001800_closing_attribution_and_food` | "Who performed the closing?", revised food rule (breakfast salon-funded, excess owed by employees), food repayments (D-30, D-31) |

```bash
supabase db reset          # local: rebuild from migrations + seed
supabase link --project-ref <ref> && supabase db push   # staging / production (no seed)
```

**Production bootstrap** (once, SQL editor, as `postgres`): create the owner's login in Auth, then
```sql
select app.bootstrap_outlet('HUDCO Big Boss', '2, HUDCO Main Road, …, Mysuru 570015', '<owner auth user id>');
```
Then the owner completes **Admin → Setup checklist**: cutoff, denominations, employees, catalogue,
logins, initial float. Never run `seed.sql` against production.

## 4. Tests
| Command | What it runs |
|---|---|
| `npm run lint` · `npm run typecheck` | ESLint, strict TypeScript |
| `npm test` | Vitest: money, accounting mirror (cases A–M), commission property test, export/XLSX, CSV, offline outbox + sync runner |
| `supabase test db` | pgTAP suite on the real Supabase stack (needs Docker) |
| `npm run test:db` | same pgTAP files on plain PostgreSQL 17 (no Docker): `PGHOST/PGPORT` select the server (default 127.0.0.1:54399) |
| `scripts/test-concurrency.sh` | two-session races (device lock, duplicate ops, initial float, handovers) + committed end-to-end day |
| `npm run build` | production build |

A throwaway local Postgres for `test:db` without Docker (macOS/Homebrew):
```bash
brew install postgresql@17
initdb -D /tmp/pgdata -U postgres --auth=trust && LC_ALL=en_US.UTF-8 pg_ctl -D /tmp/pgdata -o "-p 54399 -k ''" start
npm run test:db && scripts/test-concurrency.sh
```

## 5. Deployment (Vercel + Supabase)
1. Two Supabase projects in **ap-south-1 (Mumbai)**: staging and production. Production on a **paid
   plan** so daily backups exist (enable PITR if affordable). Auth: disable sign-ups (already in
   `config.toml` for local), set Site URL to the production domain.
2. `supabase db push` to each project (CI or manually). Do not apply `seed.sql` to production.
3. Vercel project linked to the repo, region `bom1` (`vercel.json`). Environment variables per §2 —
   staging values for Preview, production values for Production. Mark the service-role key as
   sensitive and Production/Preview only.
4. `main` → production, pull requests → previews against staging.
5. Before go-live: setup checklist complete, at least two weeks of parallel paper running with zero
   unexplained differences (SRS §15), install the app on the counter tablet ("Add to home screen") and
   open the Register once while online so it works offline.

## 6. Backup and recovery
- **Database**: Supabase daily backups (paid plan) / PITR. Financial tables are insert-only or
  versioned with a full audit log, so every historical value is reconstructible from the database.
- **Exports**: Reports → Download Excel gives an offline copy of any period (recommended monthly).
- **Devices**: IndexedDB is not a backup. If a tablet cannot sync, use Register → "Save pending
  entries" and import the file in Admin → Undated entries & sync issues → Recover (idempotent).
  Keep the paper register during outages.

## 7. Day-to-day
Counter: Register → tap employee → amount → Save. Head: Closing → open the day → enter Paytm, count
the drawer, record the commission handover → Submit. Owner/son: Approvals → review → Approve (or
Reject/Reopen with a reason). Corrections after approval: Reopen → fix entries → resubmit (a new
revision; the old one is kept).
