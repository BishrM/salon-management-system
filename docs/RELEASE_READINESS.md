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
