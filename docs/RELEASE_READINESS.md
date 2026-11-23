# SalonOps v1 — Release audit and staging readiness

Audit date: 2026-11-18 · Branch `salonops-v1` · Base commit `398e07d` (+ uncommitted audit changes listed in §9)
Scope: may SalonOps move to a **hosted staging** environment with test data? This is **not** a
production-readiness assessment. **Update 2026-11-18:** staging is live and was exercised — see §12.
**Update 2026-11-19:** all twelve accounting scenarios have now passed on staging; one security defect
(D3) was found and fixed — see §13. SalonOps is **not production-ready** (§13, "Remaining blockers").

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

## 12. Hosted staging results (2026-11-18)
Staging: **https://salonops-staging.vercel.app** (Vercel, `bom1`) on Supabase project
`salonops-staging` (`nzwmfoixqffwqzntvscn`, `ap-south-1`). Both free plans. Details in `STAGING_SETUP.md`.

**Database:** 11 migrations applied with `db push --remote` (no seed). Schema identical to local
(function bodies + ACLs hash, 21 policies row-by-row, triggers, extensions, Realtime tables).
`supabase test db --remote`: **330/330**; nothing persisted. Auth pushed from `config.toml`
`[remotes.staging]`: sign-up off, min 8 chars letters+digits, site/redirect URL = staging; diff 0.

**Deployment:** HTTPS; `X-Frame-Options: DENY`, HSTS, CSP `frame-ancestors 'none'`; no
`service_role`/`sb_secret_` in any client bundle; service key stored as a Vercel *Sensitive* variable.
GitHub → Vercel linked (production branch `salonops-v1`; other branches skipped by the Ignored Build
Step); earlier deploys used the CLI from a clean export of the committed branch.

**Exercised in the browser on staging (simulated data, all four roles):**
| Area | Result |
|---|---|
| Sign-in / sign-out (owner, manager, head, counter) | pass |
| Owner setup: cutoff, denominations, initial float ₹2,000 | pass |
| Employee management (4 employees, head linked to login) | pass |
| Create login for manager / head / counter | pass after fixing the Vercel secret (D2) |
| Product catalogue | pass after fix (D1) |
| Service sales, product sales (cash + Paytm), expenses (drawer + outside), zakat, food | pass — totals = S1 |
| Paytm CSV import + reconciliation; changed-row re-import (migration 11) | pass |
| Commission statement and food deduction | pass — 140/100/100/50, payable ₹30 |
| Commission handover (drawer; later outside-drawer per B13) | pass |
| Cash reconciliation: ED ₹5,100 = counted, AF ₹2,000, TH ₹3,100 | pass |
| Submit → reject → resubmit → approve (self-approval flagged) | pass |
| Reopen → correct entry (₹450→₹550) → resubmit → owner approves (revision 3) | pass |
| Dashboard, reports, Excel export (valid .xlsx), commission statement | pass |
| Audit history (who/what/reason, before→after) | pass |
| Counter blocked from Reports/Admin/Approvals/Dashboard pages and export (403) | pass |
| Direct API probes (anon, counter, head, manager, other-outlet owner) | **35/35 denied** |
| Realtime: owner receives entry events; other-outlet owner receives none | pass |

**Defects found on staging and fixed:**
- **D1 (bug):** Admin → Product catalogue "Add product" always failed with "Invalid input" — the form
  has no `product` id field and the schema rejected a missing value (the seed hid it locally). Fixed
  with `optionalUuid` in `lib/action.ts` (also used for the staff login field); unit test added;
  verified on staging.
- **D2 (configuration):** "Create login" failed with "Invalid API key" because the Supabase CLI prints a
  masked secret key unless `--reveal` is used. Re-set the Vercel variable; verified. Documented.
- **PWA:** PNG/maskable/apple-touch icons, manifest `id`/`scope`, Apple web-app meta added; `.png`
  excluded from the auth proxy (icons were otherwise redirected to /login); service-worker cache bumped.

**Observation (no change, needs owner review):** while a closing is reopened, the handover section shows
the previous revision's payable (Rev 6 §5.8) while the commission section shows the live payable; the
difference is settled after resubmission by an outside-drawer handover.

**Not verified:** offline use and installation on the real counter tablet (`TABLET_TEST_PLAN.md`
T1–T19); S2–S6, S9–S12 as full UI runs (S1, S7, S8 were run — the rest ran on 2026-11-19, §13);
production (not created).

## 13. Staging acceptance run (2026-11-19)
Scenarios S2–S6 and S9–S12 run on https://salonops-staging.vercel.app with simulated data; the user
signed in to each role in the browser pane (no credentials were read by the agent). Full results,
adaptations and figures: `ACCOUNTING_ACCEPTANCE_TESTS.md`.

| Scenario | Result | How |
|---|---|---|
| S2 food excess + shortage + reject/resubmit | PASS | UI (Register + closing); server-side variance acknowledgement verified |
| S3 top-ups, required float ₹3,000, shortfall | PASS | UI; entries via `/api/sync`; own test outlet |
| S4 overage | PASS | UI; entries via `/api/sync`; own test outlet |
| S5 commission owed to head (B13) | PASS | UI; entries via `/api/sync`; B10 over-handed path not run in UI |
| S6 food paid on a later day | PASS | two real business days; day 2 through the Register UI |
| S9 late entry after submission | PASS | **simulated** offline ops via `/api/sync`; decisions in UI |
| S10 approval order + previous-day correction | PASS | UI; doc wording corrected to Rev 6 §5.5 |
| S11 future timestamp | PASS | **simulated** clock via `/api/sync`; date assigned in UI |
| S12 audit history and immutability | PASS after fix | UI + database probe (36/36 refused); D3 fixed |

**Test setup on staging (all test data):** four outlets created with the documented
`app.bootstrap_outlet` ("Staging S3 (top-ups)", "Staging S4 (overage)", "Staging S5 (no handover)",
"Staging S6+S10 (two days)") plus one unused ("Staging S6 (food later)", holds a single voided ₹50 test
expense); setup through the app's RPCs as the staging owner. Owner cut-off was set to 00:00 on five
outlets during the run (server time was before 04:00 IST) and **restored to 04:00 through Admin → Setup;
verified in the database** (Staging Test Salon and the four S-outlets: `04:00:00`; the Isolation outlet
was never changed). All test closings end approved; no undated entries remain. Nothing was deleted.

**Defect found and fixed:**
- **D3 (security, medium):** audit rows of the global `staff` and `profiles` tables have no
  `outlet_id`; the `audit_logs` policy let *any* owner read all of them, so the other outlet's owner saw
  29 rows with Staging Test Salon's staff and user names. Fix: migration
  `20261118001200_audit_global_rows.sql` (rows visible only with `audit.read` in an outlet the staff
  member/profile belongs to). pgTAP `03_rls_test` +4 tests (failed 2/26 before, pass after). Applied to
  staging with `db push --remote`; re-check on staging: other-outlet owner 0 staff rows (only their own
  profile row), owner still sees their staff, manager none.

**Findings recorded for the owner (no code change):** O-R2 frozen revision still says "commission still
owed" after settlement; O-R3 live figures on a submitted day include undecided late entries without a
label; O-R4 opening-float flag requires reopen unless amounts match — see `DECISIONS.md`. Minor UX: the
Register's "Unpaid food" list cleared only after a reload (S6).

**Checks after the fix:**
| Check | Result |
|---|---|
| `npm run lint` | exit 0 |
| `npx tsc --noEmit` | exit 0 |
| `npx vitest run` | 4 files, **55/55** |
| `supabase test db` (local stack, migration 12 applied with `migration up`) | 8 files, **334/334** PASS |
| `scripts/test-db-local.sh` (fresh throwaway PostgreSQL 17, 12 migrations) | **334/334** |
| `npm run build` | exit 0 |
| `.next/static` grep `service_role\|SUPABASE_SERVICE_ROLE_KEY` | 0 files |
| `npm audit --omit=dev` | 0 vulnerabilities |
| `supabase test db --remote` | **not re-run**: without the DB password the CLI's temporary login role cannot create the test schema ("permission denied for database postgres"); the password lives in `.env.staging.local`, which the agent was told not to read. Run it yourself (below). |

To re-run pgTAP on staging yourself:
`supabase test db --db-url "postgresql://postgres.nzwmfoixqffwqzntvscn:$(grep '^SUPABASE_DB_PASSWORD=' .env.staging.local | cut -d= -f2-)@aws-0-ap-south-1.pooler.supabase.com:5432/postgres?sslmode=require"`

**Remaining blockers before production (SalonOps is not production-ready):**
1. Real counter tablet: `TABLET_TEST_PLAN.md` T1–T19 not run (install, offline use, sync, recovery).
2. Owner sign-off on the scenario results and on B1–B15, A1/A3/A7/A8, I1 and O-R1–O-R4 (`DECISIONS.md`).
3. SRS §15: two weeks of parallel paper running with zero unexplained differences.
4. Production Supabase (paid plan for backups) and Vercel projects — need explicit approval; never
   reuse staging keys.
5. Optional: re-run `supabase test db` against staging with the DB password (above).

## 14. Food removal, stuck sync queue and account switching (2026-11-19)
Reported on staging: head and counter could remove expenses, zakat and products but not food that had
been "paid now from the drawer"; afterwards the Register showed failed and blocked changes and sign-out
was refused, trapping the user in the account.

**Root causes**
- **D4 (food removal):** the Register sent a plain `void_entry`; the deferred check `check_food_paid`
  refuses to void food whose payments are not reversed ("reverse the food payments before voiding…").
  The app had no single action that reverses and voids, and two separate client ops could leave a
  reversal applied with the void refused.
- **D5 (stuck queue):** `sync_ops` holds back every later op on a record while an earlier op from the same
  device on that record is failed and unresolved (correct, to keep the intended order). Only
  `sync.manage` holders (owner/manager) could resolve it, the device that sent it could not, and "Clear
  from this device" removed the local copy while the server failure stayed open — so the device kept
  retrying blocked ops forever and the sign-out guard never released.
- **D6 (isolation gap found in passing):** the outbox API returned every user's rows; callers filtered,
  but "Save pending entries" exported other users' queued ops on a shared device.

**Fix (migration `20261118001300_food_void_and_withdraw.sql` + client):**
- `void_entry` with `data.reverse_payments = true` reverses every unreversed payment of the food (same
  reason, audited, dated by receipt time — D-14) and voids it, inside the op's own subtransaction: all
  or nothing; reversal ids derive from the op id, so replays never add a second reversal. A plain void of
  paid food is refused with "this food has ₹X already paid; use "Remove and cancel payment" … (nothing was
  changed)". The Register shows "Remove + cancel payment" with an explicit confirmation, and stops
  lowering a paid food cost below what was paid.
- Blocked results name the op they wait for (`blocked_by`). `withdraw_sync_op(op_id, reason)`: only the
  sender of a **failed** op (not a conflict) may withdraw it; it stays stored as failed, resolved by the
  sender with the reason, and audited. The Register offers "Withdraw this change" (and "Withdraw the
  earlier failed change" on a blocked item whose blocker is no longer on the device); waiting ops then
  replay through normal validation. Managers keep `resolve_sync_issue`.
- Late entries (frozen day) show "management decides" instead of buttons the server always refuses.
- Sign-out: fully synced → signs out; pending → warning; failed/blocked → type KEEP; only when
  `navigator.storage.persisted()` is true, otherwise blocked with the reason and the alternatives
  (sync/resolve, or "Save pending entries" for the manager). Cache clearing on sign-out is unchanged. The
  outbox API is user-scoped (list, export, clear), so another login never sees, sends, exports or clears
  the ops; they sync when their owner signs in again.

**Tests:** pgTAP `09_food_void_queue_test.sql` (31): unpaid food voids; paid food refused with no
mutation; blocked + `blocked_by`; withdraw only by sender (not head, not manager), needs a reason,
retry-safe, audited, op kept as failed; remove-and-cancel applies once, net paid 0, reversal mirrors the
payment with reason and user; replay is a duplicate with no second reversal; stale version and non-food
flag change nothing; conflicts not withdrawable. Allow-list test updated. Vitest (+7): blocked ops keep
`blocked_by`; retry after resolution re-sends only the blocked op, in order; seq order; another account
cannot read/send/export/clear; pending and failed ops survive another account's session and sync for
their owner; sign-out decisions; durability detection.

| Check | Result |
|---|---|
| `npm run lint` / `npx tsc --noEmit` | exit 0 / exit 0 |
| `npx vitest run` | 4 files, **63/63** |
| `supabase test db` (local stack, migrations 12–13 via `migration up`) | 9 files, **365/365** |
| `scripts/test-db-local.sh` (fresh PostgreSQL 17, 13 migrations) | **365/365** |
| `scripts/test-concurrency.sh` (fresh) | **11/11** |
| `npm run build` | exit 0 |
| Local app (counter/head test logins): paid lunch → 2 old-style removes → failed + blocked → withdraw ×2 → "Remove + cancel payment" | voided, 1 reversal, net paid ₹0, both withdrawals kept |
| Local app: counter keeps 1 pending entry and signs out → head signs in (online) → counter signs back in | head saw 0 / server got nothing; entry synced on counter's sign-in, `recorded_by` = counter |
| Local app: sign-out with problems when storage not persisted | blocked with the reason |
| Staging | migration 13 applied with `db push --remote`; privileges: `withdraw_sync_op` authenticated only, `app.op_void_entry` no client access |

**Limitations:** raw IndexedDB is readable with developer tools on the same browser profile (use one
profile per person on shared tablets); real-tablet behaviour (T7, T11, T20, T21) is still untested;
ops already blocked on a device before this release recover through "Withdraw" (or a manager) — they
are never auto-skipped.

## 15. Client features 4 and 5: service payment method, EDITED entries (2026-11-20)
Deployed to staging on 2026-11-20 (see §16). Committed as `fde5947` on `salonops-v1`.

**Feature 4 — Cash / UPI / Paytm / Card on service sales (D-26).** Two buttons ("Cash", "UPI / Paytm /
Card") sit directly under the service calculator; "Save sale" stays disabled ("Choose how it was paid")
until one is chosen. The op carries `payment_method` through the IndexedDB outbox (same op id, device
seq and device time on every retry). The server (`app.entry_values`) refuses a service sale or service
correction without `cash`/`paytm`; refused ops create nothing. `day_summary` reports
`service_cash_recorded`, `service_paytm_recorded`, `service_method_unrecorded` and
`paytm_recorded_total`; the dashboard and closing page show them, and `paytm_recorded_mismatch` warns
when recorded UPI/Paytm/Card ≠ the entered Paytm total. `compute_day`, revisions, the cash model,
commission (10%, rounded down to ₹10) and Paytm reconciliation are unchanged.

**Feature 5 — EDITED entries and owner audit (D-27).** Corrections are unchanged in-place updates with a
required reason, audited by the existing `entries_audit` trigger. The Register and the Owner dashboard
tag corrected entries **EDITED** (new and merely removed entries are not tagged); for owners the tag opens
`/admin/audit?table=entries&row=…`, which now labels the action EDITED/VOIDED, shows original (struck
through) → corrected values in rupees and payment-method words, who, when, the device time of the op
(offline corrections) and the reason. The Register can now correct products (quantity, payment method)
and the payment method of service sales.

**Migration:** `20261120001500_service_payment_method.sql` — relaxes `entries_kind_columns` so service
rows may carry `payment_method` (existing rows stay valid, no backfill), adds `app.payment_method`
(no client access), replaces `app.entry_values`, `app.op_correct_entry` and `public.day_summary`
(grants unchanged). Safe on existing staging data: no row is rewritten.

**Tests:** new pgTAP `11_service_payment_and_edits_test.sql` (53): cash and UPI sales stored; missing or
unknown method refused with nothing created; offline sale keeps method, device time and recorder;
duplicate retries; outsider / non-member / other-outlet refused; recorded split and unchanged commission
(also via `compute_day`); older sale without a method stays valid and a correction must state it;
service, product and expense corrections are edited (new ones are not) with original and new values,
outlet, editor, time, reason and op in the audit log; offline correction keeps device time; retry adds
no correction and no audit event; stale version is a conflict; another outlet's owner cannot correct or
read the audit; audit is owner-only (head, counter read nothing); mismatch warning on/off; a submitted
day refuses corrections (SO423) with no change and no audit event. Existing service ops in tests 05, 08,
09 and the concurrency script now send `payment_method` (the new requirement); no assertion was removed.
Vitest (+4): method survives reload and a dropped request, sent once; correction keeps base version,
reason and device time; EDITED rule; labels.

| Check | Result |
|---|---|
| `npm run lint` / `npx tsc --noEmit` | exit 0 / exit 0 |
| `npx vitest run` | 5 files, **67/67** |
| `supabase test db` (local stack, migrations 14–15 via `migration up`) | 11 files, **434/434** |
| `scripts/test-db-local.sh` (fresh PostgreSQL 17, 15 migrations) | **434/434** |
| `scripts/test-concurrency.sh` (fresh) | **11/11** |
| `npm run build` | exit 0 |
| Local app, counter: ₹500 UPI sale; ₹300 Cash sale entered offline then synced; save disabled until a method is chosen | stored `paytm` / `cash`, one sync op each |
| Local app, counter: correct ₹500 UPI → ₹600 Cash; product quantity 1 → 2 | version 2, EDITED in the Register |
| Local app, owner: dashboard EDITED → audit history | ₹500 → ₹600, UPI / Paytm / Card → Cash, counter, times, reason |
| Phone width (375 px) | buttons fit, no horizontal scroll |

**Remaining:** apply to staging and repeat the walkthrough there; real tablets (T7, T11, T20, T21);
service ops queued on a device before the release, without a method, fail with "choose how it was paid"
and must be withdrawn and re-entered (none expected outside staging).

## 16. Staging deployment of features 4 and 5 (2026-11-20)
**Pre-checks:** the working tree was clean at `fde5947`. The staging server had no failed, blocked or
unresolved sync ops (all 22 applied), and every existing row satisfies the relaxed `entries_kind_columns`.
Queues held in device IndexedDB cannot be inspected from the server: a service sale queued before the
release without a method fails with "choose how it was paid". The op is stored as failed, nothing is
applied, and the sender can withdraw it and enter the sale again. None appeared.

**Backup:** taken before the migration, in
`staging-backups/2026-11-20/4-before-migration-001500_{public-data,schema}.sql` (outside the repo, mode 600).

**Migration:** `supabase db push --linked --yes` applied `20261120001500` to `salonops-staging` at 16:10:09 UTC,
and remote history lists it. The branch push reached GitHub about 15 s earlier: the first push attempt
needed explicit CLI consent and was re-run. No entries were written in that window. A before/after
fingerprint was identical:
- financial data: entries, food payments and float movements (count + hash); audit count; sync ops;
- protections: 0 tables without RLS, 21 policies, 45 user triggers, 0 disabled;
- privileges: the same 9 app helpers callable by clients, no public function callable by anon.

`app.payment_method` is not callable by any client role.

**Deploy:** `fde5947` pushed to `origin/salonops-v1`; the Vercel GitHub integration deployed it
(status success) to https://salonops-staging.vercel.app. `main` untouched, no production deployment.

**Live verification (Staging S5, simulated data, staging test accounts):**

| Check | Result |
|---|---|
| Counter: ₹500 Cash and ₹700 UPI/Paytm/Card sales; refresh | stored `cash` / `paytm`, shown after reload |
| Counter: ₹300 UPI sale entered offline, then online | queued with method, synced once as `paytm` |
| Counter: correct 2 older sales without a method (₹400 → Cash; ₹250 → ₹350 UPI), ₹700 UPI → ₹750 Cash, product qty 1 → 2 | version 2, EDITED in Register and dashboard |
| Owner dashboard | services ₹2,300 = Cash ₹1,650 + UPI/Paytm/Card ₹650; commission ₹230; products ₹500 (Paytm) |
| Owner audit via EDITED | original → corrected values, "not recorded → UPI / Paytm / Card", counter, server + device time, reason |
| Head closing: Paytm ₹1,000 vs recorded ₹1,150 | mismatch warning shown; at ₹1,150 it clears |
| Cash reconciliation | net cash ₹1,420 = 2,300 − 230 + 500 − 1,150; drawer ₹3,650 counted exactly; revision 1 submitted (head), approved (owner); stored service Paytm ₹650 = recorded |
| Counter corrects an entry of the approved day | refused SO423, entry unchanged; test op withdrawn |
| Head opens /admin/audit | redirected (denied) |
| Outsider: S5 audit row / correction via /api/sync | no rows / 403 |
| Duplicates | every S5 entry: 1 applied create op, 1 INSERT audit, UPDATE audits = version − 1; no duplicate op ids |
| Register at 375 px | no horizontal scroll, buttons 151×56 px |
| Console | only the known React #418 hydration warning |

**Defect found (D8, fixed locally, not yet deployed):** offline reload on the deployed build showed
"This page has not been opened on this device before". `public/sw.js` called `res.clone()` inside an
async callback, after the response had been handed to the page, so the clone failed. Nothing was ever
cached: only the five install-time shell files were in the cache. The fix clones before returning and
bumps the cache to `salonops-v3`. On a local production build: `/register` and the build assets were
cached (16 entries); a ₹420 UPI sale entered offline survived an offline reload and synced once as
`paytm`. Entering and syncing offline worked before the fix; only reloading or opening pages offline
was broken.

**Other findings (not fixed):** the Register still offers Correct/Remove on non-late entries of a submitted
or approved day, and the server refuses them (SO423) as a failed op the counter must withdraw. React #418
(times formatted server-side in UTC vs client IST) remains. Staging S3 keeps 13 service rows with no
recorded method (live user data, untouched).

## 17. Two-account structure, employee management, closing attribution, revised food (2026-11-23, local only)
**Scope:** branch `feature/two-account-model` from `salonops-v1` (`0939679`, which is one commit ahead of
the staging deployment `fde5947`). Migrations `…001600_shop_role`, `…001700_two_account_model`,
`…001800_closing_attribution_and_food`. Decisions D-28 to D-32; open items U1–U4 (`DECISIONS.md`).
**Nothing was pushed, deployed or applied to staging or production.** `main` untouched.

**Owner decisions taken before implementation (2026-11-23):** breakfast becomes a salon expense; food above
the commission is owed by employees (not absorbed by the shop); repayments go to the owner outside the
drawer; the manager login is kept as an owner-side account.

**What changed**
| Area | Before | After |
|---|---|---|
| Accounts | owner, manager, head, counter, acting head | Owner side (owner, manager) + one Shop/Staff login per outlet; head/counter/acting rows kept but powerless |
| Employees | managed by owner/manager; `active=false` invalid on every date | also by Shop/Staff; deactivation dated (`inactive_from`), valid for earlier dates; never deleted |
| Closing | submitter only | required "Who performed the closing?" employee, validated on the business date, stored per revision |
| Handover recipient | employee with a head login | any employee working at the outlet that day |
| Food (from start date) | all meals from commission; excess paid by the shop after approval | breakfast salon-funded; lunch/dinner from commission; excess owed by employees; repayments recorded outside the drawer |

**Migration safety:** additive only (enum value, columns with defaults, new table, unique partial indexes on
a role value no row had yet). Two CHECK constraints on `closing_revisions` were replaced (`rev_food_split`,
`rev_bridge`); the new forms equal the old ones when `food_employee_owed = 0`, which is true for every
existing row, and PostgreSQL re-validated them on apply. `rev_closed_by` is `NOT VALID` (new revisions only).
No row is updated or deleted. Applied to the local Supabase stack with existing data (`supabase migration
up`): no audit rows were written by the migration; existing revisions and entries unchanged.

**Effect when applied to staging (needs approval):** the existing staging head and counter logins will no
longer have access; the owner must create the HUDCO Shop/Staff login (Admin → Logins). Days from the
apply date use the revised food rule. A service worker cache bump is not needed for this change.

**Tests (all local)**
| Suite | Result |
|---|---|
| pgTAP, local PG17 harness (`npm run test:db`) | 491/491 (was 434; +63 new in `12_…`, legacy-role assertions rewritten) |
| pgTAP, genuine `supabase test db` on the local stack | 491/491 PASS |
| Concurrency (`scripts/test-concurrency.sh`) | 11/11 (committed closing now under the revised rule: ED ₹2,250 unchanged) |
| Vitest | 71/71 (incl. `foodSplit` mirror) |
| `tsc --noEmit`, `eslint` | clean |
| `next build` | success |

**Local UI walkthrough (in-app browser, local Supabase, test data):** Shop/Staff login → Register works;
nav shows Register / Dashboard / Closing / Employees only; `/approvals`, `/reports`, `/admin/users`,
`/admin/audit` redirect to "denied". Employees: added "Esha"; deactivated "Chandan" → "deactivated from
24 Nov", moved to the end, still offered for the 19 Nov closing. Closing 19 Nov: blocker "Choose who
performed the closing." until chosen; submitted from the Shop/Staff login; owner's Approvals list shows
"Closing done by Bhavya"; approved; history shows "submitted by HUDCO Shop/Staff (test)" and "approved by
Owner (test)". Revised food on 23 Nov (breakfast ₹300, lunch ₹1,000, dinner ₹800, S ₹15,000): Food card and
final balance "− ₹300 owed to the salon"; after approval the Closing page showed ₹300 owed; a ₹200 cash
repayment through the form left ₹100. 375 px and 768 px: no horizontal page scroll; no console errors.
(Two old local late entries on 18 Nov were excluded as owner to unblock the approval order — local data only.)

**Not verified:** staging/production (not applied), real tablets/offline on device, the export file opened in
Excel (code path type-checked and built only), concurrent repayments from two sessions (serialised by an
outlet row lock, not exercised by the concurrency script).

## 18. Staging release of the two-account model (2026-11-23)
**Released commit:** `e22e8d4` (= `e3f19bc` + migration `…001900` that sets the food-policy start date from
each outlet's business day, and a concurrent-repayment test). `feature/two-account-model` pushed;
`salonops-v1` fast-forwarded `fde5947 → e22e8d4` (owner's choice; no history rewritten). `main` untouched.
No production project exists or was touched.

**Targets confirmed:** Supabase `salonops-staging` (`nzwmfoixqffwqzntvscn`), Vercel `salonops-staging`
(production branch `salonops-v1`; the feature-branch preview was skipped by the Ignored Build Step).

**Pre-checks:** working tree clean; 5 auth users (owner, manager, outsider, head, counter), no Shop/Staff
login; 31 server sync ops (30 applied, 1 failed and resolved, none pending); the in-app browser that ran
earlier staging tests had no IndexedDB outbox for the staging origin. Real tablets: none in use.

**Backup** (`~/Desktop/Salons/staging-backups/2026-11-23/`, directory 700, files 600; SHA-256 in `SHA256SUMS`):
`before-001600_schema.sql` and `before-001600_data.sql` (schemas `public`, `app`, `supabase_migrations`),
`fingerprint-before.txt`, `fingerprint-after.txt`, `git-head.txt`. Verified: COPY row counts equal live
counts for all 16 checked tables, and a restore into a throwaway PostgreSQL 17 database (auth stub,
triggers off for the data load) reproduced the data fingerprint of all 19 tables **identically** (UTC).
Auth users are not in this backup (password hashes stay in Supabase).

**Migration:** dry run listed exactly `…001600`–`…001900`, no seed; `supabase db push` applied them at
11:17:50–11:17:52 UTC; remote history lists all four. Before/after (`fingerprint-*.txt`): all 19 data
tables identical (entries, food payments, float, closings, drafts, revisions, denominations, allocations,
events, handovers, late reviews, Paytm, staff, assignments, memberships, outlets, profiles, sync ops,
audit log — new columns excluded); policies 21 → 22 (`food_repayments_select`), user triggers 45 → 48
(staff deactivation date, repayment immutability + audit), 0 disabled; tables without RLS 0; anon-callable
functions 0; definer functions without `search_path` 0; client-callable `app` helpers unchanged. Replaced
CHECKs `rev_food_split`/`rev_bridge` validated against the existing revision; `rev_closed_by` NOT VALID.
**Effective date recorded:** `food_rule_v2_from = 2026-11-23` (India business date at apply time) on every
staging outlet; the existing pre-migration closing (S5, 20 Nov) recomputes live to exactly its frozen values.

**Deployment:** Vercel `dpl_7CQggXFesSKVXHgbVtUEGzLtCo9E`, Ready, aliased to
https://salonops-staging.vercel.app; GitHub commit status of `e22e8d4` points to this deployment; the live
`/sw.js` is the new build (`salonops-v3`).

**Shop/Staff login:** `shop@salonops-staging.test`, created by the procedure in STAGING_SETUP §1.6a
(password generated into `.env.staging.local`, never displayed), membership `shop` on Staging Test Salon
added by the owner.

**Live acceptance (REST as each real staging login, simulated data on Staging Test Salon, 23 Nov):**
| Check | Result |
|---|---|
| Owner / manager / outsider / head / counter / shop sign in | all authenticate |
| Manager permissions | previous set retained except `delegation.manage` (retired for everyone); gains `food_repayment.record` |
| Retired head and counter | `my_permissions` = [], no outlets, no entries visible |
| Shop/Staff | exactly 7 operational permissions; sees only Staging Test Salon; on another outlet `day_summary`, `food_debt_summary`, `prepare_closing`, `create_staff` → 403; owner-only `approve_closing`, `reopen_closing`, `record_food_repayment`, `establish_initial_float`, `set_outlet_cutoff` → 403; second Shop/Staff login and retired roles refused |
| Employees | shop added "Esha (sim)", renamed, deactivated → `inactive_from` 24 Nov; dropdown for 23 Nov includes her, for 24 Nov not; other-outlet employee refused; history kept |
| Sync | 5 ops (cash + UPI services, breakfast/lunch/dinner) applied; identical resend → no duplicates (5 entries, 5 ops) |
| Closing | blockers incl. "who performed" until set; S ₹15,000 → C ₹1,500; food ₹2,100 = breakfast ₹300 (salon) + lunch/dinner ₹1,800; deducted ₹1,500; owed ₹300; payable ₹0; N ₹8,500; ED ₹12,000 counted exactly; recorded UPI = Paytm total (no warning) |
| Actor vs employee | revision `submitted_by` = shop, `closed_by` = Esha; events: submitted by shop, approved by manager |
| Debt and repayments | pending ₹300 before approval, outstanding ₹300 after; ₹100 partial (owner, cash, employees named) → ₹200; **two simultaneous ₹200 attempts (owner + manager): one stored, one refused** → ₹0 |
| Drawer unaffected | revision ED unchanged; next day opens with the retained ₹2,000 only |
| Reopen | shop cannot reopen (403); owner reopens; debt moves to pending (outstanding −₹300 shown as "repaid more than currently owed"); shop changes employee to Arun; rev 2 approved by owner; rev 1 byte-identical (Esha); audit Esha → Arun by shop |
| Audit | every change recorded with the true login (shop / manager / owner) |

**Browser walkthrough (23 Nov, deployment `e22e8d4`, 375×812 and 768×1024, signed in by the user):**
| Screen | Login | Result |
|---|---|---|
| Register, Employees, Closing list, Closing 23 Nov, Commission statement | Shop/Staff | no page-level sideways scroll at 375 or 768 (wide tables scroll inside their card); attribution card "Arun", food card and final balance −₹300 match the REST run; revisions show Esha → Arun |
| Approvals, Logins | Shop/Staff | refused ("Not available") |
| Approvals, Closing list (repayment list with Reverse), Closing 23 Nov, Logins | Owner | no sideways scroll at 375 or 768; history names manager and owner; Logins shows Shop/Staff, Management, Owner and the two retired roles as "(retired, no access)" |
| Dashboard | both | **page scrolls sideways at 375** (543 px): Employee sales / Recent entries cards widen their grid track. Fine at 768 |
| Reports | Owner | **page scrolls sideways at 375** (388 px), same cause. Fine at 768 |

**Defects found:**
1. **W1, Register omits an employee on their last working day.** `register/page.tsx` filters on `staff.active`,
   but deactivation sets `active = false` immediately with `inactive_from` = tomorrow. On 23 Nov Esha is
   missing from "Who did the service?" and "Today by employee", her ₹5,000 sale shows as "Service · employee",
   and the shop cannot record another sale for her that day. Server-side checks and the closing screen are
   correct (date-aware). Introduced by this release.
2. **W2, hydration error (React #418) on Register.** `register.tsx:205` formats `received_at` without a time
   zone (server UTC vs tablet IST). Cosmetic after hydration, but logs an error on every load.
3. **W3, Dashboard and Reports overflow at 375 px.** Grid children lack `min-w-0` / `grid-cols-1`. Pre-existing.
4. Minor: the shop login sees "approved by —" in a closing's history (owner/manager names not readable by the
   shop); "Remove role" buttons on Logins at 768 sit inside the table's scroll area.
5. Not exercised in the UI: the "Closing done by" column on Approvals (nothing pending) and the repayment
   form (outstanding ₹0). Both covered by the REST run and pgTAP.

**Not yet done on staging:** fixes for W1–W3 (need a deploy); real tablets/offline (T7, T11, T20, T21); a
commission-rounding case with non-round sales on staging (covered by pgTAP).

## 19. Fixes for W1–W3 from the staging walkthrough (2026-11-23, local only)

Branch `fix/w1-w3-staging-ui`, based on `1682315` (docs only on top of the deployed `e22e8d4`). W1–W3 in
`45df464` (no migration); the W1 midnight-to-cutoff edge case in the next commit (one forward migration,
function-only, no data change).

**W1, employee missing from the Register on the deactivation day.**
- Root cause: `app/(app)/register/page.tsx` kept only `staff.active` rows. Deactivation sets `active = false`
  at once and `inactive_from` = the next date, so the Register dropped the employee for the rest of that day,
  although the database (`app.staff_assigned`: `active or date < inactive_from`) still accepted them.
- Fix: new `lib/staff.ts` `worksOn()` applies the same rule as `app.staff_assigned` to the Register's business
  date (`today`, which already honours the outlet cutoff); the query now also selects `inactive_from`.
  Historical records are untouched; the employee name map now includes the employee, so today's sales show
  their name instead of "employee".
- Tests: `tests/staff.test.ts` (5: active; earlier dates; whole deactivation date; unavailable from the next
  date; pre-2026-11-23 deactivation never works). `supabase/tests/13_deactivation_day_register_test.sql`
  (9: valid before deactivation; valid and a sale accepted through `sync_ops` on the deactivation business
  date; refused from the next business date; a late offline entry dated to the earlier working day accepted
  and kept on that day with its employee; commission allocations still name the employee).
- Midnight-to-cutoff edge case, fixed by migration `20261123002000_deactivation_business_date.sql`: the
  trigger used to date `inactive_from` from the India **calendar** date + 1, so a deactivation at 01:00 on
  24 Nov (business date 23 Nov) gave 25 Nov, one extra business day. New `app.staff_inactive_from_at(staff,
  instant)` = `app.business_date(outlet, instant) + 1` for the outlet of the employee's current assignment
  (outlet timezone and configured cutoff; the existing business-date function, no second definition);
  employees with no outlet cutoff keep the calendar rule. `app.staff_set_inactive_from` calls it with `now()`.
  Function-only: no staff row, sale, commission or closing is changed; rows deactivated before the migration
  keep their stored date. Tests: `supabase/tests/14_deactivation_cutoff_test.sql` (16: 23:59, 00:01, 01:00,
  03:59:59.999 → next date 24 Nov; exactly 04:00 and 10:30 → 25 Nov; the same instant in UTC; a 06:00 cutoff
  is honoured; the trigger uses business date + 1; available on the deactivation business date and not the
  next, for 01:00 and 04:00; the day's commission still names the employee and the sale is kept; no cutoff →
  calendar fallback). Test 12's expectation changed from "India calendar date + 1" to "business date + 1".
  Late offline entries stay covered by test 13 (unchanged, passing).

**W2, React #418 hydration error on the Register.**
- Root cause: `register.tsx` formatted `received_at` with `toLocaleTimeString` and no time zone, so the server
  (UTC on Vercel) rendered e.g. "10:51 am" and the tablet (India) "04:21 pm".
- Fix: the call now passes `timeZone: "Asia/Kolkata"`, the same salon-local zone `fmtTime` uses elsewhere.
  Stored timestamps unchanged; no suppression.
- Verified on a local production build served with `TZ=UTC`: server HTML contains "04:21 pm", browser
  console has no errors on Register load.

**W3, Dashboard and Reports wider than a phone.**
- Root cause: the content grids (`grid gap-5 lg:grid-cols-2`) had no column template below `lg`, so their
  implicit `auto` track grew to the tables' `min-w-max` width and pushed the page to 543 / 388 px.
- Fix: `grid-cols-1` (= `minmax(0, 1fr)`) on those grids in `dashboard/page.tsx` (1) and `reports/page.tsx`
  (2). Tables keep all columns and scroll inside their card.
- Verified on the local production build: Dashboard and Reports page width = viewport at 375, 768 and
  1280 px (two columns at 1280); wide tables scroll inside their cards.

**Test results (`45df464`):** vitest 76/76 (6 files); pgTAP 500/500 (13 files, local PG17 harness);
`tsc --noEmit` clean; `eslint` clean; `next build` succeeded.

**Test results (with the edge-case fix):** vitest 76/76 (6 files); pgTAP 516/516 (14 files) on the local PG17
harness **and** 516/516 via `supabase test db` on the local Docker stack (migration applied with
`supabase migration up --local`); concurrency script 13/13; `tsc --noEmit` clean; `eslint` clean;
`next build` succeeded. Local production build (`TZ=UTC`, port 3001): Register lists Chandan (inactive
from 24 Nov) on business date 23 Nov, entry times "04:21 pm", no console errors; Dashboard and Reports page
width ≤ viewport at 375, 768 and 1280 px, two columns at 1280.

**Still to do:** approval to push and deploy this branch to staging, then re-check W1–W3 there; real
tablets/offline (T7, T11, T20, T21).
