# SalonOps — Accounting acceptance tests (HUDCO Big Boss, simulated data)

All names and amounts are invented. Amounts are whole rupees (D-07). Run each scenario on **staging**
with test accounts, compare every screen value with the "Expected" column, and record PASS/FAIL.

**Status of the expected values:** S1–S5 were computed by the production formula
(`app.cash_model`, migration `…000900`) on a fresh database on 2026-11-18 and agree with the hand
calculations below; S1/S2/SRS allocations were computed by `lib/accounting.ts#allocateCommission`
(same algorithm as the SQL). **All twelve scenarios have now been run on hosted staging** (S1, S7, S8 on
2026-11-18; S2–S6 and S9–S12 on 2026-11-19). Every figure matched; results, adaptations and limits are
recorded under each scenario and in the sign-off table. S9 and S11 used **simulated** offline ops sent to
the real `/api/sync` endpoint — they are **not** real-tablet tests (those are `TABLET_TEST_PLAN.md`).

**How the 2026-11-19 staging run was set up (test data only):**
- Staging had one open business day, so each of S3, S4, S5 ran on its own test outlet ("Staging S3
  (top-ups)", "Staging S4 (overage)", "Staging S5 (no handover)"), created with the documented
  `app.bootstrap_outlet`; staff, products, roles and the ₹2,000 initial float went through the app's own
  RPCs acting as the staging owner. S6 + S10 ran on "Staging S6+S10 (two days)" (starts 2026-11-18).
- Server time was ~00:10 IST, i.e. still business day 2026-11-18 under the 04:00 cut-off. The owner
  cut-off was set to 00:00 on Staging Test Salon and the S3/S4/S5 outlets (business day 2026-11-19), and on
  the two-day outlet after day 1 was submitted (to reach day 2). **All were restored to 04:00 afterwards
  and verified**; stored business dates do not change with the cut-off.
- S2 and S6 day 2 were entered through the Register screen; S3/S4/S5/S6 day 1 entries were posted by the
  counter login to `/api/sync` (the endpoint the Register uses). Closings, approvals, rejections, reopen,
  late-entry decisions, date assignment, float and top-ups were all done in the UI by the named role.

## Formulas used (paise in the database, rupees here)
| Symbol | Meaning | Formula |
|---|---|---|
| S | service sales (all payment types) | Σ active service entries |
| C | commission pool | `FLOOR(S × 10% / ₹10) × ₹10` (SRS §3.1, D1) |
| alloc | per-employee commission | each gets `FLOOR(own sales / ₹100) × ₹10`; the leftover ₹10 units go to the largest remainders (`own sales mod ₹100`), ties → higher sales, then staff id |
| P | product sales | Σ quantity × unit price (cash + Paytm) |
| Paytm | Paytm total for the day (UPI + card, entered at closing) | manual |
| E | ordinary expenses **paid from the drawer** (outside-drawer expenses are shown, not deducted — Rev 6 O2) | Σ |
| Z | zakat | Σ |
| F | food cost of the day | Σ food entries |
| FC / FX | food funded by commission / extra paid by the shop | days **before** `food_rule_v2_from`: `FC = min(F, C)`, `FX = F − FC` (FX > 0 needs management approval, B6) |
| B / LD / OW | breakfast / lunch + dinner / owed to the salon | days **from** `food_rule_v2_from` (D-31): `FX = B` (salon expense), `FC = min(LD, C)`, `OW = LD − FC` (no approval; repaid outside the drawer) |
| final balance | commission left after lunch/dinner (negative = owed) | `C − LD` |
| payable | commission cash payable to employees | `C − FC` |
| N | SRS expected physical cash | `S − C + P − Paytm − E − Z` (SRS §3.5, verbatim) |
| O | opening float | carried float R + pre-opening top-ups |
| I | top-ups during the day | Σ |
| CS | cash sales | `S + P − Paytm` |
| Fd | food paid from the drawer today (today's + earlier days' food) | Σ |
| H | commission handed to the head **from the drawer** | Σ handovers − returns (drawer) |
| ED | expected in drawer | `O + I + CS − E − Z − Fd − H` |
| V | difference | `counted − ED` (any V ≠ 0 needs a reason and approver acknowledgement, B2) |
| RF / AF / FS / TH | required next-day float / float kept / float shortfall / taken home | `AF = min(counted, RF)`, `FS = max(0, RF − counted)`, `TH = max(0, counted − RF)` |
Identity shown on the closing screen: `ED = O + I + N + (payable − H) + (F − f_today) − f_prior − FX − OW` (OW = 0 before D-31).
ED itself does not depend on how food is split: only food actually paid from the drawer (Fd) reduces it.

Commission rounding spot checks: S ₹99 → C ₹0 · S ₹100 → ₹10 · S ₹1,999 → ₹190 · S ₹15,550 → ₹1,550 (SRS §3.1).

---

## S1 — Normal busy day (cash + Paytm, products, expenses, zakat, food, handover)
**Executed on hosted staging 2026-11-18 through the UI (counter → head → manager → owner): every value
below matched** (S ₹3,940, C ₹390, allocation 140/100/100/50, payable ₹30, ED ₹5,100, V ₹0, AF ₹2,000,
TH ₹3,100, SRS N ₹3,100).
Opening: carried float R = ₹2,000; RF = ₹2,000.

| Entry | Amount |
|---|---|
| Arun: ₹450 cash, ₹600 Paytm, ₹350 cash | ₹1,400 |
| Bhavya: ₹300 Paytm, ₹250 cash, ₹480 cash | ₹1,030 |
| Chandan: ₹700 cash, ₹290 cash | ₹990 |
| Head employee: ₹520 cash | ₹520 |
| Product: Shampoo 2 × ₹350, cash | ₹700 |
| Product: Wax 1 × ₹250, Paytm | ₹250 |
| Expense (drawer): tea ₹80, cleaning ₹150 | ₹230 |
| Expense (outside drawer): plumber ₹500 | shown, not deducted |
| Zakat | ₹20 |
| Food: breakfast ₹120 + lunch ₹240, paid now from drawer | ₹360 |
| Closing: Paytm total ₹1,150 (UPI ₹900, card ₹250) | |
| Handover to head from drawer | ₹30 |

| Value | Calculation | Expected |
|---|---|---|
| S | 1,400 + 1,030 + 990 + 520 | **₹3,940** |
| C | FLOOR(394 / 10) × 10 | **₹390** |
| P (cash / Paytm) | 700 + 250 | **₹950** (₹700 / ₹250) |
| Service Paytm (derived) | 1,150 − 250 | ₹900 |
| FC / FX / payable | min(360, 390) / 0 / 390 − 360 | **₹360 / ₹0 / ₹30** |
| N (SRS) | 3,940 − 390 + 950 − 1,150 − 230 − 20 | **₹3,100** |
| CS | 3,940 + 950 − 1,150 | ₹3,740 |
| ED | 2,000 + 3,740 − 230 − 20 − 360 − 30 | **₹5,100** |
| Count | 500×7 + 200×5 + 100×4 + 50×2 + 20×4 + 10×2 = 3,500+1,000+400+100+80+20 | **₹5,100**, V **₹0** |
| AF / FS / TH | min(5,100, 2,000) / 0 / 5,100 − 2,000 | **₹2,000 / ₹0 / ₹3,100** ("taken home by" required) |

Commission statement (pool ₹390; floors 14 + 10 + 9 + 5 = 38 units, 1 leftover → largest remainder Chandan ₹90):

| Employee | Sales | Exact 10% | Allocated | Rounding |
|---|---:|---:|---:|---:|
| Arun | 1,400 | 140 | **140** | 0 |
| Bhavya | 1,030 | 103 | **100** | −3 |
| Chandan | 990 | 99 | **100** | +1 |
| Head employee | 520 | 52 | **50** | −2 |
| Total | 3,940 | 394 | **390** | −4 |
Statement footer: pool ₹390 − food ₹360 = **₹30 payable**, handed ₹30 → status "Fully handed over".

## S2 — Food above commission + cash shortage (management approval and acknowledgement)
R = ₹2,000 (S1's float), RF ₹2,000. Arun ₹450, Bhavya ₹450 (₹200 of it by Paytm), Chandan ₹280. Zakat ₹10.
Lunch ₹260 paid now from drawer. Paytm total ₹200. Counted ₹2,650.

| Value | Calculation | Expected |
|---|---|---|
| S / C | 1,180 / FLOOR(118/10)×10 | **₹1,180 / ₹110** |
| FC / FX / payable | min(260,110) / 260 − 110 / 0 | **₹110 / ₹150 / ₹0** |
| Blocker | FX > 0 | "Food cost is more than the commission…" — head cannot submit until manager/owner records "Shop pays the extra food" with a reason |
| N | 1,180 − 110 − 200 − 10 | ₹860 |
| ED | 2,000 + 980 − 10 − 260 | **₹2,710** |
| V | 2,650 − 2,710 | **−₹60** → reason required to submit; approver must tick "I have checked: Cash difference" |
| TH | 2,650 − 2,000 | **₹650** |
| Allocation | floors 4+4+2 = 10, 1 leftover → Chandan (remainder ₹80) | Arun **40**, Bhavya **40**, Chandan **30** (exact 45 / 45 / 28) |
Rejection path: manager rejects with reason "recount" → state "Rejected — needs changes", reason
shown; head recounts (e.g. finds ₹60 → counted ₹2,710, V ₹0), resubmits → **revision 2**; revision 1
stays visible unchanged.

*Staging 2026-11-19 — PASS (Staging Test Salon, UI):* Register showed S ₹1,180 / C ₹110. Closing: FC ₹110,
FX ₹150 "needs approval", payable ₹0, allocation 40/40/30 (exact 45/45/28), N ₹860, ED ₹2,710, counted
₹2,650, V −₹60, TH ₹650. Submit refused "Cannot submit yet: Food cost is more than the commission…" until
the manager recorded "Shop pays the extra food" with a reason; the reason blocker appeared until a reason
was entered. Approve without the variance tick was refused **by the server** ("acknowledge before
approving: variance", tested with the browser `required` check removed). Rejected "recount" → head recount
₹2,710 → revision 2; revision 1 unchanged. (S2 then continued as the S9 day.)

## S3 — Top-ups, all-Paytm services, float increase with shortfall
R ₹2,000; owner records pre-opening top-up ₹500 and intraday top-up ₹300 (both with reason).
Arun ₹500 Paytm, Chandan ₹300 Paytm; Paytm total ₹800; expense ₹100 drawer; handover ₹80 from drawer.
Manager changes the required float to ₹3,000 effective this day. Counted ₹2,620.

| Value | Calculation | Expected |
|---|---|---|
| O / I | 2,000 + 500 / 300 | **₹2,500 / ₹300** |
| S / C / payable | 800 / 80 / 80 | ₹800 / **₹80** / ₹80 |
| N | 800 − 80 − 800 − 100 | **−₹180** (negative is correct: no cash sales) |
| ED | 2,500 + 300 + 0 − 100 − 80 | **₹2,620**, V ₹0 |
| AF / FS / TH | min(2,620, 3,000) / 3,000 − 2,620 / 0 | **₹2,620 / ₹380 / ₹0** — shortfall shown explicitly ("owner to top up"), never hidden |
| Allocation | 5 + 3 = 8 units = pool | Arun 50, Chandan 30 |

*Staging 2026-11-19 — PASS (outlet "Staging S3 (top-ups)"):* owner recorded the ₹500 pre-opening and
₹300 intraday top-ups and the ₹3,000 required float in Admin → Cash float (float history and audit log
show user, day and reason). Adaptation: the owner, not the manager, changed the required float (both
hold `float.manage`). Head: O ₹2,500, I ₹300, S ₹800, C ₹80, ₹80 drawer handover ("Fully handed over"),
Paytm ₹800, N −₹180, ED ₹2,620 = counted, V ₹0, RF ₹3,000, AF ₹2,620, FS ₹380 shown as "Float shortfall
(owner to top up)", TH ₹0, allocation 50/30. Manager approved (no acknowledgement needed).

## S4 — Overage
As S1 but counted ₹5,150 → V **+₹50** (reason + acknowledgement required), TH **₹3,150**.

*Staging 2026-11-19 — PASS (outlet "Staging S4 (overage)"):* S1 figures reproduced (S ₹3,940, C ₹390,
140/100/100/50, P ₹950, outside-drawer ₹500 shown not deducted, payable ₹30, N ₹3,100); ₹30 drawer
handover; ED ₹5,100, counted ₹5,150, V +₹50, TH ₹3,150. Submit with the reason cleared was refused
("Counted cash differs from expected: write a reason"). Approval required the "I have checked: Cash
difference (+₹50 …)" tick.

## S5 — Commission not handed at closing (B13)
As S1 but no drawer handover (H = 0): ED **₹5,130**; counted ₹5,130 → V ₹0; TH **₹3,130**, screen
notes "of which commission still owed to head ₹30". Next day management records an
**outside-drawer** handover of ₹30 → settlement "Fully handed over"; no drawer effect on either day.
A handover above the payable (e.g. ₹50 against ₹30) is refused. If the payable later drops below what
was already handed (a correction lowers sales), the day is "Over-handed" and approval is blocked until
a return or an accepted overpayment is recorded (B10).

*Staging 2026-11-19 — PASS (outlet "Staging S5 (no handover)"):* ED ₹5,130 = counted, TH ₹3,130, note
"Of which: commission still owed to head ₹30." A ₹50 handover was refused ("handover exceeds the
commission payable (₹30 still payable)"). After approval the handover form offered only "Outside the
drawer"; ₹30 recorded → "Fully handed over", ED unchanged. Adaptation: recorded the same calendar day
after approval rather than "next day". Not run: the over-handed path (B10) — covered by pgTAP only.
Observation for the owner: the approved revision's cash section still reads "commission still owed to
head ₹30" after settlement (revisions are frozen snapshots; section 5 shows the live status).

## S6 — Food paid on a later day (J2)
Day 1: S ₹2,500 → C ₹250; lunch ₹300 recorded **not paid now** → FX ₹50 needs approval; nothing paid
from drawer → ED = 2,000 + 2,500 = **₹4,500**; "today's food not paid from the drawer ₹300".
Day 2: S ₹1,000; the ₹300 Day-1 lunch is paid from the drawer → shown as "earlier days' food"
(f_prior ₹300) → ED = 2,000 + 1,000 − 300 = **₹2,700**. Day 1's figures do not change.

*Staging 2026-11-19 — PASS (outlet "Staging S6+S10 (two days)", day 1 = 2026-11-18, day 2 =
2026-11-19):* Day 1 (entries via `/api/sync`, Arun ₹1,500 + Bhavya ₹1,000): FX ₹50 blocked submit until
the manager approved it; ED ₹4,500 = counted; "today's food not paid from the drawer ₹300"; TH ₹2,500.
Day 2 through the Register UI (head login): the unpaid Day-1 lunch was listed and paid with "Paid from
drawer"; Chandan ₹1,000; closing showed "earlier days' food ₹300", opening float ₹2,000 (= day-1 float
kept), ED ₹2,700 = counted, TH ₹700. Day-1 revision unchanged afterwards. Minor UX observation: the
"Unpaid food" list only cleared after a page reload.

## S7 — Paytm reconciliation
*Staging 2026-11-18:* CSV import of S1's statement (₹1,150 successes + one failed) → no mismatch warning
once the manual total was entered; a later statement with a changed status was reported, not applied.
- Paytm total left blank → blocker "Enter today's Paytm total (enter 0 if there was none)".
- UPI ₹900 + card ₹200 with total ₹1,150 → blocker `split_mismatch`.
- Product Paytm ₹250 but Paytm total ₹200 → warning "Paytm total is less than product Paytm sales";
  approver must acknowledge.
- Paytm for services > all service sales → warning + acknowledgement.
- CSV import (Admin → Paytm) of S1's statement: successes ₹1,150 vs manual ₹1,150 → no warning;
  a statement with a ₹50 difference → warning "Paytm total differs from the imported Paytm
  transactions". Re-importing the same file adds nothing; a later statement where a row changed
  status is reported as "differ from the earlier import and were NOT updated".

## S8 — Approved day reopened, corrected, resubmitted (executed 2026-11-18 on the local stack and on staging)
*Staging run:* revision 1 rejected → revision 2 resubmitted and approved (flagged self-approved) →
reopened, Arun ₹450 → ₹550 → revision 3: S ₹4,040, C ₹400, payable ₹40; the extra ₹10 commission was
settled after resubmission as an outside-drawer handover (B13; reopening never allows drawer
handovers). Note for the owner: while a day is reopened, section 5 still shows the previous revision's
payable (by design, Rev 6 §5.8 `allowed`) while section 4 shows the live figure.
Day state before: approved revision 1 — S ₹1,650, C ₹160, food ₹200 (₹40 shop-funded, approved),
expected ₹2,830, counted ₹2,830.
1. Owner: Reopen for correction, reason given → state "Reopened for correction".
2. Counter: corrects Chandan's ₹300 service to ₹400 with a reason (entry version 2, audit old/new).
3. Recomputed: S **₹1,750**, C **₹170**, food excess **₹30** → **needs approval again** (the earlier
   approval was for ₹40; it is tied to the exact food cost and pool).
4. Head: count shows ₹2,830 vs expected **₹2,930** (V −₹100) → recounts ₹2,930, V ₹0; submit refused
   with "Cannot submit yet: Food cost is more than the commission…" until the manager approves ₹30.
5. Manager approves the ₹30; head submits → **revision 2**; owner approves.
Expected history: food excess allocated → submitted → approved → reopened → food excess allocated →
submitted → approved; revisions table shows Rev 1 and Rev 2 side by side; Rev 1 unchanged.

## S9 — Late entry after submission
Day D submitted. A tablet that was offline syncs a ₹250 service for day D.
Expected: entry stored as **late**, not in D's totals; closing shows "Late entries — Needs decision";
D cannot be approved while undecided (D-06). **Exclude** (reason) → stays stored, listed separately,
outside totals (B11). **Include** (reopen reason) → day reopened → new revision includes ₹250.

*Staging 2026-11-19 — PASS, **simulated sync** (Staging Test Salon, after S2 revision 2):* two ops posted
to `/api/sync` by the head login from a new device id with device times 00:20/00:22 IST, last sync
00:10 IST, offset 0 (received 00:46): Arun ₹250 and Bhavya ₹100 → `offline_bounded`, business date
2026-11-19, `late = true`. Revision 2 totals unchanged; "Late entries (arrived after this day was
submitted) — Needs decision"; the head had no decision buttons; manager approval refused ("this closing
has open review items…"). Exclude ₹100 with reason → listed with the reason, outside totals. Include ₹250
with reopen reason → "Reopened for correction"; recomputed S ₹1,430, C ₹140, FX ₹120 (needed a new
allocation), allocation 70/40/30, ED ₹2,960 → revision 3 includes the ₹250; revisions 1–2 unchanged;
owner approved revision 3. Display observation: while a submitted day has undecided late entries, the
live sections show totals that include them (S ₹1,530) with no label; the official figures are the
revision's.

## S10 — Multi-day approval order
D and D+1 both submitted. Approving D+1 first is refused (approval in date order, D4); approve D, then
D+1. D+1's opening float = D's float kept. If D is later reopened and its float kept changes, D+1 shows
the review flag "the previous day was corrected…". Per Rev 6 §5.5 a manager may only **acknowledge** it
when D's new float kept equals the opening float D+1 used; otherwise D+1 must be **reopened** and
recounted. (Earlier wording here said only "a manager must acknowledge" — corrected 2026-11-19.)

*Staging 2026-11-19 — PASS (two-day outlet):* approving 2026-11-19 first → "approve earlier days first
(pending or under review: 2026-11-18)"; approve D → approved. D+1 rev 1 opened with D's float kept
₹2,000. Manager reopened D, changed the required float to ₹2,500 from 2026-11-18, resubmitted (rev 2: AF
₹2,500, TH ₹2,000; rev 1 unchanged), approved (flagged "self-approved"). D+1 showed the review flag;
approve → refused (open review item); acknowledge → refused "the corrected previous day leaves ₹2500 in
the float but this day opened with ₹2000; reopen this day". Reopened D+1 → opening float ₹2,500, ED
₹3,200, recount ₹3,200 → rev 2 → approved; flag cleared.

## S11 — Future timestamp / suspect clock
Tablet clock 20 min fast, offline entry → flagged (`future_time`/`timestamp_suspect`), goes to
Admin → Undated entries; manager assigns the business date with a reason; it then counts on that day
(or is late if that day is already submitted).

*Staging 2026-11-19 — PASS, **simulated sync**:* op posted with device time = now + 20 min and offset 0
(measured before the clock jumped) → Chandan ₹150 stored with no business date, flags `future_time`,
`timestamp_suspect`. The open day showed the warning "Some offline entries could not be dated
automatically…" with a required "Undated offline entries" acknowledgement. Admin → Undated entries listed
it with the device time, true-time bounds and flags; manager assigned 2026-11-19 with a reason → it became
a late entry (revision 3 was already submitted) → excluded with a reason. Audit log shows
`business_date: null → "2026-11-19"`, `date_basis → management_assigned` with the reason.

## S12 — Audit history (check after S1–S11)
- Audit log (owner only): every correction shows old value, new value, user, time and reason; voids
  show the reason; float movements and top-ups show user and reason.
- Revisions, revision denominations and allocations, closing events, Paytm transactions and the audit
  log cannot be changed or deleted by any role (verified directly against the database).
- Counter, head and manager cannot open the audit log; another outlet's owner sees none of HUDCO's data.

*Staging 2026-11-19 — PASS after a fix (defect D3):*
- Owner audit log shows the S8 correction (`amount: 45000 → 55000`, user, reason), a void made for this
  check (`status: active → voided`, `void_reason`, user) on the spare "Staging S6 (food later)" outlet,
  the S3 top-ups and float change (user + reason), the S11 date assignment and closing drafts/revisions.
- Counter, head and manager → `/admin/audit` → "Not available".
- Direct database probe (rolled back): UPDATE and DELETE on closing revisions, revision denominations,
  revision allocations, closing events, Paytm transactions, audit logs, late-entry reviews, float
  movements and commission handovers were refused for `postgres` (triggers: "does not allow UPDATE/
  DELETE") and for an authenticated owner ("permission denied") — 36/36.
- **D3 found:** the other outlet's owner could read 29 audit rows of outlet-less tables (`staff`,
  `profiles`) belonging to Staging Test Salon — staff and user names. Fixed by migration
  `20261118001200_audit_global_rows.sql` (pgTAP 03 +4 tests; failed before, pass after); applied to
  staging; re-check: other-outlet owner sees 0 staff rows and only their own profile row; owner still sees
  their staff rows; manager still sees none.

## S13 — Revised food rule (D-31), executed automatically (pgTAP 12, vitest `foodSplit`) and in the local UI
| Day | S → C | Food | Expected | Result |
|---|---|---|---|---|
| D1 | ₹20,000 → ₹2,000 | breakfast ₹300, lunch ₹1,500 | FX ₹300, FC ₹1,500, OW ₹0, payable ₹500, balance +₹500 | PASS |
| D2 (client example) | ₹15,000 → ₹1,500 | breakfast ₹300, lunch ₹1,000, dinner ₹500 | FX ₹300, FC ₹1,500, OW ₹0, payable ₹0, balance ₹0 | PASS |
| D3 | ₹15,000 → ₹1,500 | lunch ₹1,000, dinner ₹800 | FC ₹1,500, OW ₹300, payable ₹0, balance −₹300; no approval blocker; N = ₹13,500 (food not deducted again); ED = O + CS = ₹17,000 | PASS |
| Debt | — | — | pending ₹300 until approved; repaid ₹200 (owner, cash) → outstanding ₹100; over-repayment refused; reversal restores ₹300; frozen revision and next-day ED unchanged | PASS |
| Old rule | ₹1,000 → ₹100 | breakfast ₹300 on a day before the start date | FC ₹100, FX ₹200, approval blocker (unchanged B6) | PASS |

Local UI (2026-11-23, local Supabase, test data): breakfast ₹300 + lunch ₹1,000 + dinner ₹800 with S ₹15,000
→ "Final balance − ₹300 owed to the salon"; after approval the Closing page showed ₹300 owed, a ₹200 cash
repayment left ₹100. Not run on staging (not deployed).

## Sign-off
| Scenario | Tester | Date | Result | Notes |
|---|---|---|---|---|
| S1 | Claude (staging, UI) | 2026-11-18 | PASS | all four roles |
| S2 | Claude (staging, UI) | 2026-11-19 | PASS | server-side acknowledgement verified |
| S3 | Claude (staging, UI; entries via `/api/sync`) | 2026-11-19 | PASS | separate test outlet; owner changed required float |
| S4 | Claude (staging, UI; entries via `/api/sync`) | 2026-11-19 | PASS | separate test outlet |
| S5 | Claude (staging, UI; entries via `/api/sync`) | 2026-11-19 | PASS | same-day settlement; B10 over-handed path not run in UI |
| S6 | Claude (staging, UI; day-1 entries via `/api/sync`) | 2026-11-19 | PASS | two real days via cut-off change |
| S7 | Claude (staging, UI) | 2026-11-18 | PASS | CSV import + changed-row re-import |
| S8 | Claude (staging, UI) | 2026-11-18 | PASS | revision 3 |
| S9 | Claude (staging, simulated sync + UI decisions) | 2026-11-19 | PASS | not a real offline tablet |
| S10 | Claude (staging, UI) | 2026-11-19 | PASS | doc wording corrected to Rev 6 §5.5 |
| S11 | Claude (staging, simulated sync + UI assignment) | 2026-11-19 | PASS | not a real tablet clock |
| S12 | Claude (staging, UI + database probe) | 2026-11-19 | PASS after fix | defect D3 fixed (migration 12) |
| Owner sign-off | — | — | **pending** | owner must review results and B1–B15 |
SRS §15 also requires at least two weeks of parallel paper running with zero unexplained differences
before go-live.
