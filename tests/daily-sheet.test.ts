import { describe, it, expect } from "vitest";
import { buildSheet, describeChange, ACCOUNT_LABELS, type SheetEntry, type SheetSummary, type SheetChange } from "@/lib/daily-sheet";
import { servicePayment, commissionPool } from "@/lib/accounting";

const R = (r: number) => r * 100;
let seq = 0;
const e = (kind: string, amount: number, x: Partial<SheetEntry> = {}): SheetEntry => ({
  id: `e${++seq}`, kind, amount: R(amount), staff_id: null, product_name: null, quantity: null, unit_price: null,
  payment_method: null, split_cash: null, split_paytm: null, tip_cash: 0, tip_paytm: 0, expense_source: null, meal: null,
  description: null, version: 1, status: "active", server_seq: seq, ...x,
});
const names: Record<string, string> = { s1: "Shuhaib", s2: "Employee 2", s3: "Employee 3" };
const summary = (x: Partial<SheetSummary> = {}): SheetSummary => ({
  cash_sales: R(460), zakat_total: R(20), expenses_total: R(50), expenses_outside_total: 0, paytm_total: R(840), paytm_entered: true,
  product_total: R(250), commission_pool: R(100), service_total: R(1050), paytm_recorded_total: R(840), paytm_difference: 0,
  tips_cash: 0, tips_paytm: 0, denominations: { "1000": 3, "50000": 2 }, ...x,
});
const DENS = [1000, 2000, 5000, 10000, 20000, 50000];

describe("Daily Sheet layout mapping", () => {
  const entries = [
    e("service", 100, { staff_id: "s1", payment_method: "cash" }),
    e("service", 200, { staff_id: "s2", payment_method: "paytm" }),
    e("service", 150, { staff_id: "s1", payment_method: "split", split_cash: R(100), split_paytm: R(50) }),
    e("service", 150, { staff_id: "s3", payment_method: "paytm", tip_paytm: R(50) }),
    e("service", 50, { staff_id: "s1", payment_method: "cash", version: 2 }),
    e("service", 999, { staff_id: "s2", payment_method: "cash", status: "voided", version: 2 }),
    e("product", 500, { product_name: "Shampoo", quantity: 2, unit_price: R(250), payment_method: "paytm" }),
    e("expense", 50, { description: "Tea", expense_source: "cash_drawer" }),
    e("zakat", 20, { description: "Masjid" }),
    e("food", 60, { meal: "breakfast" }), e("food", 300, { meal: "lunch" }), e("food", 200, { meal: "dinner" }), e("food", 100, { meal: "lunch" }),
  ];
  const sheet = buildSheet(entries, (id) => names[id], summary(), DENS);

  it("numbers employee columns 1..n left to right with the name under each number", () => {
    expect(sheet.columns.map((c) => [c.no, c.name])).toEqual([[1, "Shuhaib"], [2, "Employee 2"], [3, "Employee 3"]]);
  });
  it("creates one column per employee with sales (dynamic, no seven-column limit)", () => {
    const many = Array.from({ length: 10 }, (_, i) => e("service", 10, { staff_id: `x${i}`, payment_method: "cash" }));
    expect(buildSheet(many, (id) => id, summary(), DENS).columns).toHaveLength(10);
    expect(buildSheet(many.slice(0, 2), (id) => id, summary(), DENS).columns).toHaveLength(2);
  });
  it("lists each service sale vertically under its employee and totals the column (voided sales left out)", () => {
    expect(sheet.columns[0].cells.map((c) => c.amount)).toEqual([R(100), R(150), R(50)]);
    expect(sheet.columns[0].total).toBe(R(300));
    expect(sheet.columns[1].total).toBe(R(200));
    expect(sheet.serviceTotal).toBe(R(650));
    expect(sheet.maxCells).toBe(3);
  });
  it("keeps the split and the tip on the cell, never in the amount", () => {
    expect(sheet.columns[0].cells[1].split).toEqual([R(100), R(50)]);
    expect(sheet.columns[2].cells[0]).toMatchObject({ amount: R(150), tip: R(50) });
    expect(sheet.columns[0].cells[2].edited).toBe(true);
  });
  it("has no PTM columns: payments are not columns of the grid", () => {
    expect(sheet.columns.every((c) => !/ptm/i.test(c.name))).toBe(true);
  });
  it("keeps products separate with price, quantity, total and mode", () => {
    expect(sheet.products).toEqual([{ label: "Shampoo", detail: "₹250 × 2 · PTM", amount: R(500), edited: false }]);
  });
  it("puts expenses, zakat and breakfast in the expenses area, each labelled", () => {
    expect(sheet.expenses.map((x) => x.label)).toEqual(["Tea", "Zakat", "Breakfast"]);
  });
  it("totals lunch and dinner for the top-right corner", () => {
    expect([sheet.lunch, sheet.dinner]).toEqual([R(400), R(200)]);
  });
  it("lists rolling denominations 10..500 with count × note and the total", () => {
    expect(sheet.rolling.map((r) => r.den / 100)).toEqual([10, 20, 50, 100, 200, 500]);
    expect(sheet.rolling[0]).toEqual({ den: 1000, count: 3, total: R(30) });
    expect(sheet.rollingTotal).toBe(R(30) + R(1000));
  });
  it("keeps the Accounts labels and order exactly", () => {
    expect(sheet.accounts.map((a) => a.label)).toEqual([...ACCOUNT_LABELS]);
    expect(ACCOUNT_LABELS).toEqual(["TOTAL CASH SALES", "ZAKAT", "TOTAL EXPENSES", "TOTAL PAYTM AMOUNT", "TOTAL PRODUCT SALE", "TOTAL COMMISSION", "TOTAL SALES"]);
  });
  it("shows the entered Paytm statement total, not a Register sum, and blank until entered", () => {
    expect(sheet.accounts[3].amount).toBe(R(840));
    expect(buildSheet(entries, (id) => names[id], summary({ paytm_entered: false, paytm_total: 0 }), DENS).accounts[3].amount).toBeNull();
    expect(sheet.accounts[6].amount).toBe(R(1050) + R(250));
  });
});

describe("Register service payment (split and tips)", () => {
  it("1–2. cash-only and Paytm-only stay one field", () => {
    expect(servicePayment({ amount: R(150), method: "cash" })).toEqual({ ok: true, data: { amount: R(150), payment_method: "cash" } });
    expect(servicePayment({ amount: R(150), method: "paytm" })).toEqual({ ok: true, data: { amount: R(150), payment_method: "paytm" } });
  });
  it("3. split: cash + Paytm must equal the service amount", () => {
    expect(servicePayment({ amount: R(150), method: "split", splitCash: R(100), splitPaytm: R(50) }))
      .toEqual({ ok: true, data: { amount: R(150), payment_method: "split", split_cash: R(100), split_paytm: R(50) } });
    expect(servicePayment({ amount: R(150), method: "split", splitCash: R(100), splitPaytm: R(40) }).ok).toBe(false);
    expect(servicePayment({ amount: R(150), method: "split", splitCash: R(100), splitPaytm: null }).ok).toBe(false);
    expect(servicePayment({ amount: R(150), method: "split", splitCash: -R(50), splitPaytm: R(200) }).ok).toBe(false);
  });
  it("4. a tip is separate: ₹150 service paid ₹200 digitally → amount ₹150, tip ₹50", () => {
    const p = servicePayment({ amount: R(150), method: "paytm", tipPaytm: R(50) });
    expect(p).toEqual({ ok: true, data: { amount: R(150), payment_method: "paytm", tip_paytm: R(50) } });
    // An overpayment is never treated as a tip on its own: a split that adds up to ₹200 is refused.
    expect(servicePayment({ amount: R(150), method: "split", splitCash: R(100), splitPaytm: R(100) }).ok).toBe(false);
  });
  it("7. commission ignores tips and how the sale was paid", () => {
    expect(commissionPool(R(150))).toBe(R(10));
  });
});

describe("Owner sheet-change notice", () => {
  const base = { id: 1, at: "2026-11-23T10:00:00Z", business_date: "2026-11-23", outlet: "HUDCO Big Boss", actor: "Shop", reason: null, late: false };
  it("addition: employee, amount added and employee total before → after", () => {
    const d = describeChange({ ...base, section: "service", action: "added", employee_old: null, employee_new: "Shuhaib", old: null,
      new: { amount: R(150) }, totals: [{ label: "Shuhaib", before: R(1000), after: R(1150) }] } as SheetChange);
    expect(d).toMatchObject({ title: "Daily Closing Sheet Updated — HUDCO Big Boss", section: "Services", subject: "Shuhaib",
      action: "New service entry added.", amountLine: { label: "Amount added", value: "₹150" }, totals: [{ label: "Shuhaib's total", before: "₹1,000", after: "₹1,150" }] });
  });
  it("correction: product quantity 1 → 2 and section total", () => {
    const d = describeChange({ ...base, section: "product", action: "corrected", employee_old: null, employee_new: null,
      old: { product_name: "Shampoo", quantity: 1, unit_price: R(250), amount: R(250) },
      new: { product_name: "Shampoo", quantity: 2, unit_price: R(250), amount: R(500) },
      totals: [{ label: null, before: R(250), after: R(500) }] } as SheetChange);
    expect(d.subject).toBe("Shampoo");
    expect(d.changes).toEqual(["Amount: ₹250 → ₹500", "Quantity: 1 → 2"]);
    expect(d.totals).toEqual([{ label: "Products total", before: "₹250", after: "₹500" }]);
  });
  it("removal: amount removed", () => {
    const d = describeChange({ ...base, section: "service", action: "removed", employee_old: "Shuhaib", employee_new: "Shuhaib",
      old: { amount: R(150) }, new: { amount: R(150), status: "voided" }, totals: [{ label: "Shuhaib", before: R(1150), after: R(1000) }] } as SheetChange);
    expect(d.action).toBe("Service entry removed.");
    expect(d.amountLine).toEqual({ label: "Amount removed", value: "₹150" });
  });
});
