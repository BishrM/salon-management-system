# SalonOps — Security model and known issues

## Model
- **Authentication**: Supabase Auth, email + password, HTTP-only cookie sessions via `@supabase/ssr`;
  `proxy.ts` refreshes the session. Public sign-up is off; the owner creates logins.
- **Authorisation in the database**: every table has RLS; clients can only `SELECT` through policies
  (`app.is_member(outlet_id)`; audit log owner-only; sync log own ops or `sync.manage`). All `INSERT/
  UPDATE/DELETE` privileges are revoked from `anon`/`authenticated`. Writes go only through an
  allow-list of `SECURITY DEFINER` RPCs with `search_path = ''` that check the caller's permission in
  the target outlet (`app.require_permission`) and take actor columns from `auth.uid()`.
- **Roles are read from the database on every request** (never from JWT claims). Acting-head
  delegation is valid only inside its time window, while not revoked and while the grantor still
  holds owner/manager in the same outlet; self-grants are impossible (CHECK + RPC).
- **Immutability**: revisions, revision children, closing events, float movements, handovers, late
  reviews, Paytm transactions and the audit log reject UPDATE/DELETE for every role (trigger), including
  the RPCs. Entries and food payments are never deleted; their timestamp evidence and identity are
  frozen by trigger; corrections bump `version` and are audited with old and new values.
- **Server**: Zod validation in every server action and route handler; the database validates again.
  The service-role key is read only in `lib/supabase/server.ts#createAdminClient`, imported with
  `server-only`, and used only after a `users.manage` check through the caller's own session. CI
  greps the client bundle for it.
- **HTTP headers**: `X-Frame-Options: DENY`, CSP `frame-ancestors 'none'`, `nosniff`, HSTS,
  restrictive `Permissions-Policy`.
- **Devices**: cached pages and the outbox are per device; sign-out is blocked while entries are
  pending and clears the page cache. Use one Android/OS user per shared tablet.

## Verified by tests
pgTAP: direct writes denied for every role, anon has no access, exact RPC allow-list, every definer
function pins `search_path`, per-role permission matrix, cross-outlet isolation, delegation (active,
expired, future, revoked, demoted grantor, self-grant, NULL end), immutability triggers.
Concurrency script: device lock, duplicate ops, initial float, handover overshoot.

## Known issues / not yet verified
1. **Verified locally only.** On 2026-11-18 the migrations applied and `supabase test db` passed
   (328/328) on the local Supabase stack. A manual walkthrough covered sign-in for owner, manager, head
   and counter, the initial float, register entries (with live refresh), a void, closing, food-excess
   approval, submit and approve, reports, the Excel export and the audit log. Direct API probes
   confirmed that anon, counter and the other-outlet owner are denied. Not yet exercised: offline use
   on a real tablet, multi-day reopen/resubmit in the UI, and a hosted staging project.
2. **Dev-only dependency advisory**: `picomatch` ReDoS (GHSA-fc5q-39xc-vjpf) via vitest/eslint
   tooling. Not shipped to production; npm's only fix is a vitest downgrade, which was not applied.
   Production dependencies: 0 known vulnerabilities.
3. No rate limiting beyond Supabase Auth's own limits; `sync_ops` caps a batch at 200 ops and
   Paytm import at 5,000 rows.
4. No CSP `script-src` (Next.js inline runtime); add a nonce-based CSP when hardening further.
5. Passwords are handed over in person; there is no self-service password reset page yet (Supabase
   dashboard can reset).
