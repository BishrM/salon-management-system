// Daily Sheet (digital copy of the paper DAILY SHEET). Pure layout mapping: every figure comes from the
// Register entries of the day (the same entry set as compute_day) or from day_summary. Nothing is stored.

export type SheetEntry = {
  id: string; kind: string; amount: number; staff_id: string | null; product_name: string | null;
  quantity: number | null; unit_price: number | null; payment_method: string | null;
  split_cash: number | null; split_paytm: number | null; tip_cash: number; tip_paytm: number;
  expense_source: string | null; meal: string | null; description: string | null;
  version: number; status: string; server_seq: number;
};

export type SheetSummary = {
  cash_sales: number; zakat_total: number; expenses_total: number; expenses_outside_total: number;
  paytm_total: number; paytm_entered: boolean; product_total: number; commission_pool: number; service_total: number;
  paytm_recorded_total: number; paytm_difference: number | null; tips_cash: number; tips_paytm: number;
  denominations: Record<string, number>;
};

export type SheetCell = { id: string; amount: number; edited: boolean; method: string | null; split: [number, number] | null; tip: number };
export type SheetColumn = { no: number; staffId: string; name: string; cells: SheetCell[]; total: number };
export type SheetLine = { label: string; detail: string; amount: number; edited: boolean };

/** The seven Accounts rows, in the paper sheet's requested order and wording. */
export const ACCOUNT_LABELS = [
  "TOTAL CASH SALES", "ZAKAT", "TOTAL EXPENSES", "TOTAL PAYTM AMOUNT", "TOTAL PRODUCT SALE", "TOTAL COMMISSION", "TOTAL SALES",
] as const;

const edited = (e: { version: number; status: string }) => e.version - (e.status === "voided" ? 2 : 1) > 0;

export function buildSheet(entries: SheetEntry[], staffName: (id: string) => string, s: SheetSummary, denominations: number[]) {
  const ordered = [...entries].filter((e) => e.status === "active").sort((a, b) => a.server_seq - b.server_seq);

  // One column per employee with a service sale that day, numbered left to right in order of their first sale.
  const cols = new Map<string, SheetColumn>();
  for (const e of ordered) {
    if (e.kind !== "service" || !e.staff_id) continue;
    let c = cols.get(e.staff_id);
    if (!c) cols.set(e.staff_id, (c = { no: cols.size + 1, staffId: e.staff_id, name: staffName(e.staff_id), cells: [], total: 0 }));
    c.cells.push({ id: e.id, amount: e.amount, edited: edited(e), method: e.payment_method,
      split: e.payment_method === "split" ? [e.split_cash ?? 0, e.split_paytm ?? 0] : null, tip: e.tip_cash + e.tip_paytm });
    c.total += e.amount;
  }
  const columns = [...cols.values()];

  const expenses: SheetLine[] = [];
  for (const e of ordered) {
    if (e.kind === "expense") expenses.push({ label: e.description ?? "Expense", detail: e.expense_source === "outside_drawer" ? "outside drawer" : "drawer", amount: e.amount, edited: edited(e) });
    else if (e.kind === "zakat") expenses.push({ label: "Zakat", detail: e.description ?? (e.staff_id ? staffName(e.staff_id) : ""), amount: e.amount, edited: edited(e) });
    else if (e.kind === "food" && e.meal === "breakfast") expenses.push({ label: "Breakfast", detail: "salon", amount: e.amount, edited: edited(e) });
  }
  const products: SheetLine[] = ordered.filter((e) => e.kind === "product").map((e) => ({
    label: e.product_name ?? "Product",
    detail: `₹${(e.unit_price ?? 0) / 100} × ${e.quantity ?? 0} · ${e.payment_method === "paytm" ? "PTM" : "Cash"}`,
    amount: e.amount, edited: edited(e),
  }));
  const meal = (m: string) => ordered.filter((e) => e.kind === "food" && e.meal === m).reduce((a, e) => a + e.amount, 0);

  const rolling = [...denominations].sort((a, b) => a - b).map((d) => {
    const count = s.denominations[String(d)] ?? 0;
    return { den: d, count, total: d * count };
  });

  const accounts: { label: (typeof ACCOUNT_LABELS)[number]; amount: number | null; note?: string }[] = [
    { label: "TOTAL CASH SALES", amount: s.cash_sales, note: "services + products − Paytm statement" },
    { label: "ZAKAT", amount: s.zakat_total },
    { label: "TOTAL EXPENSES", amount: s.expenses_total, note: s.expenses_outside_total ? `drawer; + ${s.expenses_outside_total / 100} outside` : "from the drawer" },
    { label: "TOTAL PAYTM AMOUNT", amount: s.paytm_entered ? s.paytm_total : null, note: "statement, entered at closing" },
    { label: "TOTAL PRODUCT SALE", amount: s.product_total },
    { label: "TOTAL COMMISSION", amount: s.commission_pool, note: "10% of services, down to ₹10" },
    { label: "TOTAL SALES", amount: s.service_total + s.product_total, note: "services + products" },
  ];

  return {
    columns, expenses, products, lunch: meal("lunch"), dinner: meal("dinner"),
    rolling, rollingTotal: rolling.reduce((a, r) => a + r.total, 0),
    accounts,
    serviceTotal: columns.reduce((a, c) => a + c.total, 0),
    maxCells: Math.max(0, ...columns.map((c) => c.cells.length)),
  };
}

// ---- Owner "Sheet changes" (public.sheet_changes: one item per audited Register change after the sheet was opened) ----

export type SheetChange = {
  id: number; at: string; business_date: string; outlet: string; section: string; action: "added" | "corrected" | "removed";
  actor: string | null; reason: string | null; late: boolean; employee_old: string | null; employee_new: string | null;
  old: Record<string, unknown> | null; new: Record<string, unknown>;
  totals: { label: string | null; before: number; after: number }[] | null;
};

const SECTION: Record<string, string> = { service: "Services", product: "Products", expense: "Expenses", zakat: "Zakat", food: "Food" };
const money = (v: unknown) => (v == null ? "—" : `₹${(Number(v) / 100).toLocaleString("en-IN")}`);
const PAY: Record<string, string> = { cash: "Cash", paytm: "UPI / Paytm / Card", split: "Split" };
const FIELDS: [string, string, (v: unknown) => string][] = [
  ["amount", "Amount", money], ["quantity", "Quantity", (v) => (v == null ? "—" : String(v))], ["unit_price", "Unit price", money],
  ["payment_method", "Paid by", (v) => (v == null ? "not recorded" : PAY[String(v)] ?? String(v))],
  ["split_cash", "Cash part", money], ["split_paytm", "UPI / Paytm / Card part", money],
  ["tip_cash", "Cash tip", money], ["tip_paytm", "UPI tip", money],
  ["description", "Description", (v) => (v == null ? "—" : String(v))], ["meal", "Meal", (v) => (v == null ? "—" : String(v))],
  ["expense_source", "Paid from", (v) => (v === "outside_drawer" ? "outside the drawer" : v == null ? "—" : "drawer")],
];

/** Owner-readable lines for one change: what, who, before → after, and the totals it moved. */
export function describeChange(c: SheetChange) {
  const kind = c.section;
  const subject = kind === "service" ? (c.employee_old && c.employee_new && c.employee_old !== c.employee_new
      ? `${c.employee_old} → ${c.employee_new}` : c.employee_new ?? c.employee_old ?? "—")
    : kind === "product" ? String(c.new.product_name ?? "") : kind === "food" ? String(c.new.meal ?? "") : String(c.new.description ?? "");
  const what = kind === "service" ? "service entry" : kind === "product" ? "product sale" : kind === "food" ? "food entry" : `${kind} entry`;
  const action = c.action === "added" ? `New ${what} added.` : c.action === "removed" ? `${what[0].toUpperCase()}${what.slice(1)} removed.` : `${what[0].toUpperCase()}${what.slice(1)} corrected.`;
  const changes: string[] = [];
  if (c.action === "corrected" && c.old) {
    for (const [k, label, f] of FIELDS) if (JSON.stringify(c.old[k] ?? null) !== JSON.stringify(c.new[k] ?? null)) changes.push(`${label}: ${f(c.old[k])} → ${f(c.new[k])}`);
  }
  const amountLine = c.action === "added" ? { label: "Amount added", value: money(c.new.amount) }
    : c.action === "removed" ? { label: "Amount removed", value: money(c.old?.amount) } : null;
  const totals = (c.totals ?? []).map((t) => ({
    label: t.label ? `${kind === "service" ? `${t.label}'s` : t.label} total` : `${SECTION[kind] ?? kind} total`,
    before: money(t.before), after: money(t.after),
  }));
  return {
    title: `Daily Closing Sheet Updated — ${c.outlet}`,
    section: SECTION[kind] ?? kind,
    subjectLabel: kind === "service" ? "Employee" : kind === "product" ? "Product" : kind === "food" ? "Meal" : "Item",
    subject, action, changes, amountLine, totals,
  };
}
