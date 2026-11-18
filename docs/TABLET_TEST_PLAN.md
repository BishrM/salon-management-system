# SalonOps — Real-tablet offline test plan

Status: **not yet executed on a real device.** Offline behaviour has been verified only by unit tests
(`tests/offline.test.ts` with `fake-indexeddb`), pgTAP sync tests and the two-session concurrency
script. Nothing in this document may be reported as passed until it has been run on the counter tablet.

## How the implementation works (as built)
| Part | File | Behaviour |
|---|---|---|
| Service worker | `public/sw.js` (registered by `components/service-worker.tsx`) | Caches `/offline.html`, icon, manifest at install. `/_next/static/*` cache-first after first use. Page navigations network-first; offline → last cached copy of that path, else `offline.html`. `/api/*` and non-GET never cached. |
| Persistent storage | `components/service-worker.tsx` | Calls `navigator.storage.persist()` to reduce eviction risk. |
| Outbox | `lib/offline/outbox.ts` (IndexedDB) | Every register write is queued first with a client UUID `op_id`, per-device `device_seq`, device time and measured clock offset; rows carry `user_id` and `outlet_id`. Failed/conflict rows are never deleted automatically. |
| Sync runner | `lib/offline/sync.ts`, `components/sync-badge.tsx` | One sender per device (Web Locks). Sends the signed-in user's `pending` + `blocked` ops in `device_seq` order, 100 per request, to `POST /api/sync` → RPC `sync_ops`. Triggers: page load, `online` event, right after an entry is queued, every 30 s while the app is open. **No Background Sync**: a closed app does not sync. |
| Server | `sync_ops` (migration `…000800`) | Idempotent on `op_id` and `(device_id, device_seq)`; same op replayed → stored result returned (`duplicate: true`); reused id with different content → `conflict`. Corrections/voids carry `base_version`; stale versions → `conflict` (no last-write-wins). Ops for a record not yet on the server → `blocked` (kept on device, retried). Entries for a frozen day → stored as **late** for management review. |
| Dating | migration `…000800` | Business date from receipt time, device time and clock offset with thresholds 120 s (online window) / 300 s (clock warning) / 48 h (long gap); suspect timestamps go to **Unassigned** for management to date. |
| Sign-out guard | `components/sign-out-button.tsx` | Refused while this user has `pending` or `blocked` ops on this device; clears cached pages on sign-out. |
| Recovery | Register → "Save pending entries" + Admin → Undated entries & sync issues → Recover | JSON export of unsynced rows; idempotent re-import. |

## Prerequisites
- **HTTPS is mandatory**: service workers only run on `https://` or `http://localhost`. Testing the
  tablet against `http://<Mac LAN IP>:3000` will *not* register the service worker, so offline reload
  will fail for that reason alone. Use the hosted staging URL (`docs/STAGING_SETUP.md`) or an HTTPS tunnel.
- Record: tablet model, OS version, browser + version, installed as home-screen app (yes/no).
- Test accounts: counter, second counter, head, manager (staging accounts, test data only).
- A second device (laptop) signed in as manager with the Dashboard open, to watch totals.
- Turn off battery optimisation for the browser on Android (it can kill background tabs).

## Test cases
Each case: run the steps, record PASS/FAIL, screenshots, and the Register's "This device" panel numbers.

| # | Case | Steps | Expected |
|---|---|---|---|
| T1 | Initial load + install | Online: open staging URL, sign in as counter, open Register, "Add to Home screen", reopen from the icon | Register loads; standalone window; `navigator.serviceWorker.controller` set (check via remote debugging) |
| T2 | Online entry | Service ₹300 for Arun | Toast "saved"; entry in Recent with synced state within ~3 s; manager dashboard updates live (Realtime) or within 60 s (poll) |
| T3 | Go offline | Airplane mode | Offline banner; sync badge shows offline |
| T4 | Offline entries | Record service ₹450 (Bhavya), product 2×₹350 cash, expense ₹80 tea, food lunch ₹240 paid now | Each appears in Recent marked waiting; "N waiting to sync" increments; Register totals include them immediately |
| T5 | Offline reload | Still offline: close the app fully, reopen from the icon | Cached Register shell loads (or offline page if the Register was never opened online); queued entries still listed from IndexedDB |
| T6 | Device restart with pending | Still offline: reboot the tablet, reopen | Pending count unchanged; nothing lost |
| T7 | Sign-out guard | Offline with pending entries: tap Sign out | Refused with "N entries have not reached the server yet" |
| T8 | Reconnect + auto sync | Turn airplane mode off, keep app open | Within ~30 s (immediately on `online`): waiting → 0; manager dashboard shows the four entries; totals equal the pre-sync tablet totals |
| T9 | Duplicate prevention | During T8, toggle network off/on rapidly 3–4 times; or kill the app mid-sync and reopen | Server has exactly one row per entry (check Dashboard counts and Admin audit); responses marked duplicate are harmless |
| T10 | Long offline + session expiry | Offline > 1 h (JWT expiry 3600 s), record 2 entries, reconnect | Session refreshes and entries sync; if the refresh token was revoked, sync shows "Signed out — sign in again to sync", entries stay queued, and after signing in **as the same user** they sync |
| T11 | Different user on same tablet | With pending entries for counter A (sign-out refused), force a session change by having management revoke A (or wait for expiry), sign in as counter B | B's sync never sends A's entries (outbox is per user); A's entries remain; use "Save pending entries" + Admin → Recover to deliver them; confirm `recorded_by` stays A |
| T12 | Failed sync + retry | While online, have management submit the day's closing, then record an entry for that day on the tablet | Entry syncs as **late**; closing shows "Late entries — Needs decision"; Include → reopen/new revision, Exclude → stays outside totals |
| T13 | Conflict | Device 1 offline corrects entry X ₹300→₹350; device 2 online corrects X ₹300→₹400; device 1 reconnects | Device 1's op shows **conflict** (not silently applied); X = ₹400; conflict visible in "problems" and in Admin sync issues; nothing discarded |
| T14 | Multiple devices | Tablet + phone, both counters, alternate entries offline then reconnect both | All entries present once; dashboard totals = sum of both devices; `device_label` distinguishes devices |
| T15 | Clock wrong | Set tablet clock 20 min ahead, record entry online and offline | Clock warning banner (> 300 s); offline entry beyond tolerance flagged and placed in Unassigned for management dating |
| T16 | Day boundary | Offline across the 04:00 cutoff, record one entry before and one after, reconnect | Entries dated to the correct business days (or Unassigned if suspect) |
| T17 | Export recovery | Offline with pending: Register → "Save pending entries"; import the file on a laptop as manager (Admin → Recover) twice | File downloads; first import applies, second reports duplicates only |
| T18 | Storage eviction | Check `navigator.storage.persisted()` via remote debugging | `true` on Chrome/Android when installed; record the value on iPadOS |
| T19 | Totals before/after | For T4/T8, write down Register totals offline, then Dashboard totals after sync | Identical services, commission, products, expenses, food |

## Known gaps / compatibility risks (inspect before and during testing)
1. **No PNG icons / no `apple-touch-icon`**: manifest has one SVG icon. Android Chrome may not offer
   an install prompt and iPadOS shows a screenshot as the home-screen icon. Add 192/512 PNG and a
   180×180 apple-touch-icon if T1 fails (asset work, not code logic).
2. **iPadOS Safari**: no Background Sync, Web Locks supported only in recent versions (the runner falls
   back to a single in-page sender), storage may be evicted after ~7 days without use unless installed
   to the home screen. Prefer an Android tablet with Chrome, or install to the home screen on iPad.
3. Pages are available offline only if visited online at least once after the latest deploy (the
   service worker caches on demand; JS chunks for unvisited pages are not pre-cached). Open the
   Register online after every deployment.
4. Client-side navigation between pages while offline uses RSC requests that are not cached; use the
   Register only while offline (it is the only screen designed for offline work).
5. A closed app does not sync; staff must open the app after connectivity returns.
6. Cached pages may contain the previous user's data until sign-out clears them; use one OS user per
   shared tablet.
