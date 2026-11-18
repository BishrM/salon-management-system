# SalonOps v1 — Release audit and staging readiness

Audit date: 2026-11-18 · Branch `salonops-v1` · Base commit `398e07d` (+ uncommitted audit changes listed in §9)
Scope: may SalonOps move to a **hosted staging** environment with test data? This is **not** a
production-readiness assessment.

## 1. Verdict
**READY FOR STAGING — with conditions.** No critical or high security finding; the authorization model
held under 36 direct API probes; the accounting engine matches SRS §3 and the confirmed decisions with
worked numbers; migrations build a fresh database identical to the tested one; production dependencies
have no known vulnerabilities.

Conditions (all are owner decisions, not code work):
1. Approve pushing `salonops-v1` to GitHub (Vercel deploys from Git). (M1 resolved: commits now use the
   GitHub noreply address.)
2. Staging uses test data and test accounts only; `seed.sql` is never run on a hosted project.
3. Approve creating the free Supabase staging project and Vercel project (`docs/STAGING_SETUP.md`).

**Not production-ready:** real-tablet offline behaviour is unverified, B1–B15 are unconfirmed, no
production backup plan is paid for, and SRS §15's two-week parallel paper run has not happened.

## 2. Security findings
Method: code review of every route handler, server action and migration; catalog queries on the live
database; 36 direct REST/RPC probes with real JWTs for anon, counter, head, manager and another outlet's
owner; a Realtime subscription test; superuser UPDATE/DELETE attempts inside rolled-back transactions.

| Sev. | ID | Finding | Practical impact | Status |
|---|---|---|---|---|
| Critical | — | none found | | |
| High | — | none found | | |
| Medium | M1 | The two local commits (formerly `7eec594`, `398e07d`) recorded the author's personal Gmail address; the GitHub-made initial commit uses a noreply address. | Pushing publishes that address in public history permanently. | **Fixed** (owner approved): both unpushed commits rewritten to the noreply address (now `21c370f`, `0a4f2a6`; identical trees); repo `user.email` set to noreply. |
| Medium | M2 | Paytm CSV re-import silently counted a transaction whose status/amount changed in a later statement (e.g. pending → success) as "already imported". | Import-vs-manual comparison could mislead management; no effect on cash (the manual total drives closing). | **Fixed** (migration `…001100`): such rows are reported by reference and never overwritten. Whether a later statement should *supersede* is an owner question (§11). |
| Medium | M3 | Sign-out ignored `blocked` outbox ops (ops waiting for an earlier op; not stored on the server). | A counter could sign out leaving sales that only that user on that device can deliver; another user's closing would miss them. | **Fixed** (`components/sign-out-button.tsx`). |
| Low | L1 | `sync_ops` replay returns the stored result when device id, sequence, op id and payload hash all match, without checking the submitter. | Requires guessing three random UUIDs; reveals only an op result for the same outlet the caller must already be a member of (permission checked first). | Accepted. |
| Low | L2 | If "Create login" succeeds in Auth but `add_membership` fails, an orphan login remains; retrying says the email exists. | Owner must add the role via "Add role" instead. No privilege gained. | Accepted; documented. |
| Low | L3 | CSP has no `script-src` (only `frame-ancestors`, `base-uri`, `form-action`, `object-src`). | Defence-in-depth only; no XSS sink found (no `dangerouslySetInnerHTML`; XLSX uses inline strings, so no formula injection). | Documented in SECURITY.md. |
| Low | L4 | Offline page cache can hold the previous user's pages until sign-out (sign-out clears it). | Shared tablet privacy; mitigated by sign-out clearing caches and per-user outbox. | Documented in tablet plan. |
| Low | L5 | Seed logins use a predictable password pattern; OPERATIONS.md previously said "local/staging". | Anyone could sign in to a hosted staging seeded with them. | **Fixed in docs**: seed is local-only. |
| Info | I1 | Head/counter see "by —" for owner/manager actions in closing history (profiles visible only with `members.read`). | Cosmetic; deliberate privacy rule. | Owner question (§11). |
| Info | I2 | No app-level rate limiting; Supabase Auth limits apply; sync batches ≤ 200 ops, Paytm ≤ 5,000 rows. | | Accepted. |

Verified controls:
- **Auth/session**: `@supabase/ssr` HTTP-only cookies; `proxy.ts`, `lib/session.ts` and `/api/sync` use
  `getClaims()` (verified JWT), never `getSession()` on the server; sign-up disabled.
- **RLS**: enabled on all 21 `public` tables; 6 views are `security_invoker`; `anon` has no table or
  function privilege; `authenticated` has SELECT only; zero write policies; `app` schema not exposed.
- **Server-side authorization**: all 37 RPCs executable by `authenticated` are `SECURITY DEFINER` with
  `search_path=''`; 36 check an explicit permission in the target outlet (`app.require_permission`,
  `app.lock_closing`, or `app.has_permission` in `my_permissions`/`update_staff`);
  `server_time` returns only the clock. Matrix matches Rev 6 §4 (`users.manage`, `audit.read`,
  `float.initial`, `outlet.cutoff/thresholds/details` owner-only).
- **Probe results (all denied)**: anon (tables, RPCs); counter (direct insert/update/delete, audit log,
  approve, reopen, draft, Paytm import, self-promotion to owner, other outlet's sync, top-up); head
  (approve, reopen, self acting-head grant, audit log, food excess); manager (promote self to owner,
  revoke owner, cutoff, initial float, read/update audit log); outsider (HUDCO entries, revisions, staff,
  Paytm, day summary, sync, approve, add self to HUDCO, Paytm import).
- **Realtime**: owner subscribed to HUDCO `entries` received the event; the other outlet's owner, with
  the same filter, received nothing.
- **Service-role key**: only in `lib/supabase/server.ts` (`server-only`), used after a `users.manage`
  check; absent from `.next/static` (grep = 0 files); CI enforces it.
- **Validation/SQL injection**: Zod on every server action and route; database re-validates; all SQL is
  in parameterised PL/pgSQL; no string-built SQL in the app.
- **Audit/immutability**: `closing_revisions`, `revision_denominations`, `revision_commission_allocations`,
  `closing_events`, `paytm_transactions`, `audit_logs` reject UPDATE/DELETE even for the superuser;
  `entries` rows cannot be deleted.
- **Duplicates**: unique `entries.op_id`, `food_payments.op_id`, `sync_ops` (op_id / device+seq),
  Paytm `(outlet, txn_ref)`, one initial float per outlet, `(closing, revision_no)`, `(outlet, date)`;
  concurrency script proves one entry per concurrent duplicate op and no handover overshoot.
- **Exports**: `/api/export` requires `reports.read` (owner/manager) and reads through RLS.

## 3. Accounting audit
Implementation (`app.cash_model`, `app.compute_day`, `lib/accounting.ts`) checked against SRS §2–§6,
Rev 6 and `docs/DECISIONS.md`, with numbers recomputed by the production function on a fresh database
(`docs/ACCOUNTING_ACCEPTANCE_TESTS.md`).

Matches: commission `FLOOR(S×10%/₹10)×₹10` on the combined total (SRS example ₹15,550 → ₹1,550);
products excluded from commission; product total = qty × price; largest-remainder allocation sums
exactly to the pool (SRS §3.2 example 3,000/4,000/2,500 → 300/400/250 reproduced); food deducted at
pool level and not again from expenses; Paytm subtracted once (UPI/card split optional, must add up);
SRS §3.5 N shown verbatim and reconciled to the drawer model; shortfall shown explicitly; denominations
configurable; zakat separate; corrections versioned with old/new values; revisions immutable.

Discrepancies / interpretations needing owner confirmation:
| # | Document says | Implementation | Assessment |
|---|---|---|---|
| A1 | SRS §5.5: counter "assisting with daily closing" | Counter can view the closing page but cannot enter Paytm, count cash or submit (Rev 6 §4 matrix) | SRS outranks Rev 6; "assisting" is vague. Confirm. |
| A2 | SRS §3.5 deducts "ordinary expenses" | Only `cash_drawer` expenses are deducted; outside-drawer expenses shown but not deducted (Rev 6 O2) | Consistent with the physical-cash intent. Confirm. |
| A3 | SRS silent on food > commission | Excess = F − C paid by the shop, needs a management allocation (D2, B6); the allocation is tied to the exact food cost and pool, so **any** later change (even a smaller excess, ₹40 → ₹30 in the walkthrough) needs re-approval | Rule-consistent; confirm the re-approval behaviour. |
| A4 | SRS §3.5 "commission pool handled separately" | Commission not handed from the drawer stays in the drawer and leaves in "taken home", settled later outside the drawer (B13) | Confirm (B13). |
| A5 | SRS §3.2 per-employee commission | Largest remainder can round one employee up while others round down by up to ₹9 (45/45/28 → 40/40/30) | Exactly D1 (confirmed). Note for staff communication. |
| A6 | SRS §6.2 corrections | Products cannot be edited, only removed (with reason) and re-entered; history preserved | Acceptable; confirm. |
| A7 | SRS §11 Paytm reconciliation | Imported transactions are immutable; later status changes are now reported, not applied | Confirm whether a later statement should supersede. |
| A8 | — | Whole rupees only (D-07); no upper limit on a single sale (a ₹2,80,300 mis-tap was possible in testing) | Owner decision (cap or warning). |

## 4. Fresh migration verification
Isolated environment: a throwaway container from the same image as the local stack
(`supabase/postgres:17.12.0.000`, tmpfs data, `--rm`, port 54398) plus the Auth schema from the same
Auth image (`gotrue:v2.198.0`, 77 migrations). The existing local database and Docker volumes were not
touched.
| Check | Result |
|---|---|
| 11 migrations, filename order, each in one transaction | all applied |
| Extensions | only `btree_gist` (created by migration 1); `pgcrypto` for seed; `pgtap` for tests |
| Auth dependencies | `auth.uid()`, `auth.users` (seed also needs the full Auth schema) |
| Seed | applied; creates 5 `@salonops.test` users with predictable passwords → local only |
| Schema vs live local DB | identical: 21 tables, 21 policies, 84 functions, 45 triggers, same function-source hash |
| `supabase test db` on fresh DB | **330/330 PASS** |
| Concurrency script on fresh server | **11/11 ok** |
| Repeatability | migrations are one-shot by design (re-running #1 fails on `schema "app" already exists`); the CLI history prevents double application |
| Manual steps not in migrations | Auth settings (sign-up off, Site URL), first owner login + `app.bootstrap_outlet(...)`, owner's setup checklist (cutoff, denominations, staff, catalogue, logins, initial float) |

## 5. Dependency and deployment audit
- Production dependencies (7): `next 16.4.6`, `react/react-dom 19.1.0`, `@supabase/ssr 0.12.7`,
  `@supabase/supabase-js 2.119.0`, `zod 4.6.7`, `server-only` → `npm audit --omit=dev`: **0 vulnerabilities**.
- Dev tooling: **16 high** advisories, all from one root, `picomatch ≤ 4.0.7` ReDoS
  (GHSA-fc5q-39xc-vjpf) via `vitest 5.1.0`/`vite` and `eslint-config-next`/`typescript-eslint`. No patched
  `picomatch` is published (4.0.7 is the latest); npm's only "fix" is a semver-major **downgrade**
  (vitest 3.1.4, eslint-config-next 16.3.8) — not applied. Not shipped; patterns are repo-controlled.
- Minor updates available (not applied, not security): supabase-js 2.119.1, vitest 5.1.1.
- Compatibility: Next 16.4.6 peer `react ^19`, Node ≥ 20.9 (local/CI 24); `@supabase/ssr` peer
  `supabase-js ^2.114`; build `next build --turbopack` succeeds; `vercel.json` region `bom1`.
- Env vars used by code: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (public),
  `SUPABASE_SERVICE_ROLE_KEY` (server-only). Display times use `Asia/Kolkata` explicitly; business dates
  are computed in the database, so the server's UTC timezone on Vercel does not matter.
- Repository hygiene: `.env*` ignored (only `.env.example` with placeholders tracked); no keys, tokens,
  private keys, database files or dumps anywhere in history; `.claude/launch.json` contains only the
  dev command; `supabase/config.toml` contains only template placeholders (`admin@email.com` comments).

## 6. Staging configuration checklist
See `docs/STAGING_SETUP.md`. Summary: Supabase free project in ap-south-1 · `supabase db push` (no seed)
· Email provider only, sign-up off, Site URL/redirects = staging domain · verify RLS queries · bootstrap
owner + `app.bootstrap_outlet` · test accounts via Admin · Vercel Next.js preset, root `./`, `npm run
build`, region `bom1` · 2 public + 1 server-only env var, staging keys on Preview · Preview deployment
protection · smoke test.

## 7. Tablet / offline readiness
Implemented: cached shell, IndexedDB outbox with per-user rows, idempotent `sync_ops`, explicit
conflicts (no last-write-wins), late/unassigned handling, persistent-storage request, sign-out guard,
JSON export + idempotent recovery. **Not verified on a real device.** Gaps: no PNG/apple-touch icons,
no Background Sync, on-demand caching (open the Register online after each deploy), service worker
needs HTTPS (a LAN `http://` test cannot work), iPadOS storage/Web Locks caveats. Plan:
`docs/TABLET_TEST_PLAN.md` (19 cases).

## 8. Accounting acceptance scenarios
`docs/ACCOUNTING_ACCEPTANCE_TESTS.md`: S1 normal day (S ₹3,940 → C ₹390, ED ₹5,100, TH ₹3,100),
S2 food excess + shortage + rejection, S3 top-ups and float shortfall, S4 overage, S5 commission owed to
head, S6 food paid later, S7 Paytm flags/import, S8 reopen → revision 2 (executed), S9 late entry,
S10 approval order, S11 suspect clock, S12 audit history.

## 9. Changes in this audit (uncommitted, for review)
| File | Change |
|---|---|
| `supabase/migrations/20261118001100_paytm_import_changes.sql` | new: Paytm re-import reports changed rows (`changed`, `changed_refs`) |
| `app/(app)/actions.ts` | import message names changed transactions |
| `supabase/tests/08_lifecycle_test.sql` | Paytm tests: identical re-import = duplicate; changed rows reported; originals never overwritten (plan 69 → 71) |
| `components/sign-out-button.tsx` | sign-out also refused while `blocked` ops exist |
| `docs/SECURITY.md`, `docs/OPERATIONS.md` | verification status; seed is local-only; migration 11 listed |
| `docs/RELEASE_READINESS.md`, `STAGING_SETUP.md`, `TABLET_TEST_PLAN.md`, `ACCOUNTING_ACCEPTANCE_TESTS.md` | new |
Migration 11 was applied to the local database with `supabase migration up --local` (additive; no reset).

## 10. Test and build results (after the changes)
| Check | Result |
|---|---|
| `npm run lint` | exit 0, no findings |
| `npx tsc --noEmit` | exit 0 |
| `npx vitest run` | 4 files, **53/53** passed |
| `supabase test db` (local stack) | 8 files, **330/330** PASS |
| `supabase test db` (fresh isolated DB, 11 migrations + seed) | **330/330** PASS |
| `scripts/test-concurrency.sh` (fresh isolated server) | **11/11** ok |
| `npm run build` | exit 0, compiled successfully |
| `.next/static` grep for service-role | 0 files |
| `npm audit --omit=dev` | 0 vulnerabilities |
| Browser: Paytm changed-row message | verified on local dev server |

## 11. Actions requiring the owner's approval
1. Push `salonops-v1` to GitHub; whether to rewrite the two unpushed commits' author email first.
2. Create the free Supabase staging project and Vercel project (no paid plan).
3. Business decisions: B1–B15 (`DECISIONS.md`); A1 counter role in closing; A3 re-approval of food
   excess after any change; A7 Paytm later statement superseding; A8 single-sale cap/warning and
   whole-rupee rule; I1 whether heads may see management names in history.
4. Paid Supabase plan (backups) before production.
5. Running the tablet plan on the actual counter tablet (needs staging HTTPS).
