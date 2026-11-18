# SalonOps — Decision log

Source of truth, in priority order: explicit business requirements (`SRS.md`, owner instructions) →
approved Rev 6 plan (accounting and technical rules) → existing implementation where consistent.
Business decisions D1–D4 and B1–B15 are listed at the end; B1–B15 are implemented with the proposed
defaults and **still need the owner's confirmation**.

| # | Decision | Reason | Alternatives considered | Impact |
|---|---|---|---|---|
| D-01 | One `entries` table with a `kind` column (service/product/expense/zakat/food) and per-kind CHECKs, instead of five tables. Read-only views keep the Rev 6 / SRS names (`service_sales`, `product_sales`, `expenses`, `zakat_entries`, `food_deductions`). | Rev 6 §3.2 gives all five the same common columns, evidence rules, correction/void/late/sync lifecycle. One table = one correction path, one sync path, one late-entry path. | Five tables with duplicated RPCs and triggers. | Schema detail only; no business rule changes. |
| D-02 | `product_catalog` created in the M1-completion migration. | Rev 6 §11 lists it in M1; the pre-existing migration had deferred it ("M1 authorisation excludes products"), which conflicts with the plan and the business scope. | Leave for later. | Products can be sold from day one. |
| D-03 | Staff may have one *home* and one *temporary* assignment overlapping (exclusion constraint on staff, is_temporary, date range). Temporary assignments always have an end date. | Business requirement "temporary cross-outlet assignments". The existing constraint forbade any overlap, forcing a loaned employee's home assignment to be ended. | End and re-create home assignment (loses clarity). | Loans are recorded without touching history. |
| D-04 | **All** register writes (online and offline) go through `sync_ops`; `public.sync_ops` (op log) is the idempotency store. | One code path; online and offline behave identically; retries and duplicates are handled the same way. | Separate online RPC (`record_entry`) + offline sync. | Rev 6 §4.1's `record_entry`/`correct_entry`/`void_entry` are op types of `sync_ops`. |
| D-05 | Kept the existing permission matrix (`app.has_permission`) as the role check. | It implements Rev 6's `app.has_role` validity predicate and the §4 matrix exactly, and is already tested. Added `catalog.manage`, `reports.read`, `outlet.details`. | Rewrite as `has_role`. | No change to who can do what. |
| D-06 | Undecided late entries block *submission* (blocker `late_entries_undecided`) as well as approval. Late **food payments** follow the same include/exclude review. | Rev 6 §5.6 requires an explicit decision per late entry; a revision must not silently absorb an undecided one. Food payments are offline-capable and can also arrive for a frozen day. | Include undecided entries automatically. | Management decides every late row; nothing is silently included or dropped. |
| D-07 | All entered amounts are **whole rupees** (stored as integer paise, CHECK `amount % 100 = 0`). | Salon prices, Paytm counter amounts and cash denominations are whole rupees; it makes the per-employee exact 10 % share an exact integer (J3) with no rounding inside the statement. | Allow paise (exact share would need fractional paise). | A price such as ₹99.50 cannot be entered. Reversible: relax the CHECKs and store `exact_share` as numeric. |
| D-08 | Plain Tailwind components instead of shadcn/ui. | A dozen small shared components cover the UI; avoids generating and maintaining a component library. | shadcn/ui (SRS §12 suggestion). | Visual only. |
| D-09 | Excel export with a small built-in XLSX writer (`lib/xlsx.ts`) instead of exceljs. PDF via print stylesheet (O11). | exceljs 4.4.0 depends on a `uuid` version with an open advisory; the only "fix" is a downgrade, which is not allowed. The writer is ~120 lines using Node's `zlib.crc32`. | exceljs; CSV only. | Zero production dependency vulnerabilities. |
| D-10 | **Paytm: manual daily total + optional CSV statement import with explicit column mapping.** No API integration. | Official Paytm docs show no transaction-list API for static QR/Soundbox merchants: Transaction Status needs our own order IDs and Settlement APIs return settled T+1 data (sources below). The statement export layout is not verified, so the importer maps columns instead of assuming one. | Building against an unverified API (forbidden: "never invent API functionality"). | Closing is fully usable; imported transactions are de-duplicated by reference and compared with the manual total (warning `paytm_import_mismatch`). |
| D-11 | Hand-written service worker (`public/sw.js`) and raw IndexedDB outbox instead of Serwist + idb. | Next 16 builds with Turbopack; a 50-line worker covers the needed caching (static cache-first, pages network-first, API never cached). | Serwist, Workbox, idb. | Two fewer dependencies. |
| D-12 | Approval requires explicit acknowledgement of: a non-zero variance, the two "service Paytm" flags, and undated offline entries that may belong to the day. | Rev 6 §5.3/§5.4 require acknowledgement of variance and Paytm flags; §6.3 says the closing shows a warning while unassigned entries exist — acknowledgement makes the approver see it. | Warning only. | One extra checkbox in rare cases. |
| D-13 | "Previous day" for the opening float = latest business date on/after the initial-float date that has a closing **or** active entries. Days with entries but no closing block approval of later days. | Days with no trading need no closing; days with trading must not be skipped in the cash chain. | Require a closing for every calendar day. | Closed days need no paperwork. |
| D-14 | A food-payment reversal is dated by its own receipt time and affects that day's drawer. | The reversal represents cash coming back at that moment. | Back-date to the original payment (would touch a frozen day). | No frozen day is ever changed. |
| D-15 | A device clock running backwards relative to an earlier op of the same device (beyond the online window) is flagged `seq_order` and goes to Unassigned. | Rev 6 §6.3 lists "device_seq out of order" as a suspect condition. | Ignore. | Rare; management dates such entries. |
| D-16 | Commit-time (deferred) constraint triggers run `SECURITY DEFINER`. | Found by the two-session test: at COMMIT they run outside the RPC, as the client role, and could not read their helpers — every real handover would have failed. | — | Bug fixed before release. |
| D-17 | Users are created by the owner with a temporary password (service-role key used only in that server action, after a `users.manage` check through the owner's own session). Public sign-up is disabled. | No email (SMTP) is configured; owner-invited accounts per Rev 6 §4. | Email invites (needs SMTP, an external account setting). | Owner hands the password over in person. |
| D-18 | Dashboard visible to owner, manager and head; register to all roles. | SRS §5.3 head "viewing outlet sales"; §5.5 counter "viewing relevant daily totals" (shown on the Register). | Owner/manager only. | — |
| D-19 | Local database tests run on plain PostgreSQL 17 with a stub of Supabase's `auth` schema and a pgTAP-compatible shim (`supabase/tests/local/`). CI also runs the genuine `supabase test db`. | Docker could not start on the development machine (disk 99 % full) and building pgTAP from source was not permitted in this session. | Wait for Docker. | Same test files run in both; the shim implements only the pgTAP functions used. |
| D-20 | Realtime publication on `entries` and `closing_events`; dashboard also polls every 60 s. | Live dashboard (SRS §7.1) with a fallback if Realtime is unavailable. | Polling only. | — |

## Confirmed business decisions (unchanged)
D1 commission pool `FLOOR(S×10%/₹10)×₹10`, split by largest remainder in ₹10 units · D2 food at pool level,
excess needs a management allocation · D3 manual Paytm at launch · D4 later days may be submitted while
earlier ones are pending; approval in date order.

## Awaiting owner confirmation (implemented with the proposed default)
| # | Default implemented |
|---|---|
| B1 | Business-day cutoff has **no default**; the owner sets it in Admin → Outlet settings (04:00 suggested). Entries are refused until set. |
| B2 | Variance tolerance ₹0 — any difference needs a reason and an approver acknowledgement. |
| B3 | Take-home records amount and recipient (free text). |
| B4 | Initial float: one owner action, denomination count + re-typed total, unique, never reversed. |
| B5 | Acting-head delegation has no maximum length; an end time is always required. |
| B6 | Food excess = exactly F − C, paid by the shop. |
| B7 | Commission changed after distribution: per-employee adjustment visible; head settles. |
| B8 | Paytm flags: `paytm_missing`, `split_mismatch` block submission; service-Paytm flags need acknowledgement. |
| B9 | Offline thresholds 120 s / 300 s / 48 h, owner-configurable. |
| B10 | Over-handed commission blocks approval until a return or accepted overpayment; no automatic deduction from future days. |
| B11 | An excluded late entry stays stored and active, outside that day's totals, listed separately. |
| B12 | `future_time` tolerance = online window. |
| B13 | Commission not handed over at closing leaves with take-home and is settled by an outside-drawer handover. |
| B14 | Food paid by the head from personal cash: recorded as `outside_drawer`; reimbursement outside the system. |
| B15 | Food form defaults to "Paid now from drawer". |

## Paytm sources
- Transaction Status API — https://www.paytmpayments.com/docs/api/v3/transaction-status-api/
- Settlement Detail API — https://www.paytmpayments.com/docs/api/settlement-detail-api/
- Settlement API — https://www.paytmpayments.com/docs/api/settlement-api/
- Soundbox receipt verification — https://paytm.com/support/paytm-soundbox/how-merchants-can-verify-payment-receipts
