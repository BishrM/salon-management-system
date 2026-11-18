# SalonOps — Accounting acceptance tests (HUDCO Big Boss, simulated data)

All names and amounts are invented. Amounts are whole rupees (D-07). Run each scenario on **staging**
with test accounts, compare every screen value with the "Expected" column, and record PASS/FAIL.

**Status of the expected values:** S1–S5 were computed by the production formula
(`app.cash_model`, migration `…000900`) on a fresh database on 2026-11-18 and agree with the hand
calculations below; S1/S2/SRS allocations were computed by `lib/accounting.ts#allocateCommission`
(same algorithm as the SQL). S8 was executed end-to-end in the browser on the local stack. The other
scenarios' expected *behaviour* follows the implemented rules and the pgTAP suite; they have **not**
been run as a full UI scenario yet.

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
| FC / FX | food funded by commission / extra paid by the shop | `FC = min(F, C)`, `FX = F − FC` (FX > 0 needs management approval, B6) |
| payable | commission cash payable to the head | `C − FC` |
| N | SRS expected physical cash | `S − C + P − Paytm − E − Z` (SRS §3.5, verbatim) |
| O | opening float | carried float R + pre-opening top-ups |
| I | top-ups during the day | Σ |
| CS | cash sales | `S + P − Paytm` |
| Fd | food paid from the drawer today (today's + earlier days' food) | Σ |
| H | commission handed to the head **from the drawer** | Σ handovers − returns (drawer) |
| ED | expected in drawer | `O + I + CS − E − Z − Fd − H` |
| V | difference | `counted − ED` (any V ≠ 0 needs a reason and approver acknowledgement, B2) |
| RF / AF / FS / TH | required next-day float / float kept / float shortfall / taken home | `AF = min(counted, RF)`, `FS = max(0, RF − counted)`, `TH = max(0, counted − RF)` |
Identity shown on the closing screen: `ED = O + I + N + (payable − H) + (F − f_today) − f_prior − FX`.

Commission rounding spot checks: S ₹99 → C ₹0 · S ₹100 → ₹10 · S ₹1,999 → ₹190 · S ₹15,550 → ₹1,550 (SRS §3.1).

---

## S1 — Normal busy day (cash + Paytm, products, expenses, zakat, food, handover)
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

## S4 — Overage
As S1 but counted ₹5,150 → V **+₹50** (reason + acknowledgement required), TH **₹3,150**.

## S5 — Commission not handed at closing (B13)
As S1 but no drawer handover (H = 0): ED **₹5,130**; counted ₹5,130 → V ₹0; TH **₹3,130**, screen
notes "of which commission still owed to head ₹30". Next day management records an
**outside-drawer** handover of ₹30 → settlement "Fully handed over"; no drawer effect on either day.
A handover above the payable (e.g. ₹50 against ₹30) is refused. If the payable later drops below what
was already handed (a correction lowers sales), the day is "Over-handed" and approval is blocked until
a return or an accepted overpayment is recorded (B10).

## S6 — Food paid on a later day (J2)
Day 1: S ₹2,500 → C ₹250; lunch ₹300 recorded **not paid now** → FX ₹50 needs approval; nothing paid
from drawer → ED = 2,000 + 2,500 = **₹4,500**; "today's food not paid from the drawer ₹300".
Day 2: S ₹1,000; the ₹300 Day-1 lunch is paid from the drawer → shown as "earlier days' food"
(f_prior ₹300) → ED = 2,000 + 1,000 − 300 = **₹2,700**. Day 1's figures do not change.

## S7 — Paytm reconciliation
- Paytm total left blank → blocker "Enter today's Paytm total (enter 0 if there was none)".
- UPI ₹900 + card ₹200 with total ₹1,150 → blocker `split_mismatch`.
- Product Paytm ₹250 but Paytm total ₹200 → warning "Paytm total is less than product Paytm sales";
  approver must acknowledge.
- Paytm for services > all service sales → warning + acknowledgement.
- CSV import (Admin → Paytm) of S1's statement: successes ₹1,150 vs manual ₹1,150 → no warning;
  a statement with a ₹50 difference → warning "Paytm total differs from the imported Paytm
  transactions". Re-importing the same file adds nothing; a later statement where a row changed
  status is reported as "differ from the earlier import and were NOT updated".

## S8 — Approved day reopened, corrected, resubmitted (executed 2026-11-18 on the local stack)
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

## S10 — Multi-day approval order
D and D+1 both submitted. Approving D+1 first is refused (approval in date order, D4); approve D, then
D+1. D+1's opening float = D's float kept. If D is later reopened and its float changes, D+1 shows the
review flag "the previous day was corrected…" which a manager must acknowledge.

## S11 — Future timestamp / suspect clock
Tablet clock 20 min fast, offline entry → flagged (`future_time`/`timestamp_suspect`), goes to
Admin → Undated entries; manager assigns the business date with a reason; it then counts on that day
(or is late if that day is already submitted).

## S12 — Audit history (check after S1–S11)
- Audit log (owner only): every correction shows old value, new value, user, time and reason; voids
  show the reason; float movements and top-ups show user and reason.
- Revisions, revision denominations and allocations, closing events, Paytm transactions and the audit
  log cannot be changed or deleted by any role (verified directly against the database).
- Counter, head and manager cannot open the audit log; another outlet's owner sees none of HUDCO's data.

## Sign-off
| Scenario | Tester | Date | Result | Notes |
|---|---|---|---|---|
| S1 … S12 | | | | |
SRS §15 also requires at least two weeks of parallel paper running with zero unexplained differences
before go-live.
