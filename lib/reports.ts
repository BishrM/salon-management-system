import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { DaySummary } from "@/lib/types";

// Report data (SRS §7.3). Frozen days (submitted/approved) use the immutable revision; open days use
// the live computation. All sums are integer paise.

export type DayRow = {
  date: string; state: string; source: "revision" | "live";
  service: number; commission: number; products: number; productCash: number; productPaytm: number; paytm: number;
  expenses: number; expensesOutside: number; zakat: number; food: number; foodShop: number;
  /** Food from commission and food owed to the salon by employees (D-31). */
  foodCommission: number; foodOwed: number;
  /** Employee recorded as performing the closing (D-30); "" when none. */
  closedBy: string;
  opening: number; topUps: number; expected: number; counted: number; variance: number; requiredFloat: number;
  retained: number; shortfall: number; takeHome: number; commissionHandedDrawer: number;
};

export const MAX_DAYS = 92;

function* days(from: string, to: string) {
  const d = new Date(from + "T00:00:00Z");
  const end = new Date(to + "T00:00:00Z");
  while (d <= end) {
    yield d.toISOString().slice(0, 10);
    d.setUTCDate(d.getUTCDate() + 1);
  }
}

export function weekKey(date: string): string {
  // ISO week starting Monday, labelled by its Monday.
  const d = new Date(date + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}

const NUMERIC: (keyof DayRow)[] = ["service", "commission", "products", "productCash", "productPaytm", "paytm", "expenses",
  "expensesOutside", "zakat", "food", "foodShop", "foodCommission", "foodOwed", "topUps", "variance", "shortfall", "takeHome", "commissionHandedDrawer"];

/** Sum day rows into week/month buckets (balances such as opening/expected are not summed). */
export function group(rows: DayRow[], by: "day" | "week" | "month"): (Pick<DayRow, (typeof NUMERIC)[number]> & { label: string; days: number })[] {
  const out = new Map<string, Record<string, number> & { label: string; days: number }>();
  for (const r of rows) {
    const label = by === "day" ? r.date : by === "week" ? `Week of ${weekKey(r.date)}` : r.date.slice(0, 7);
    const b = out.get(label) ?? Object.assign({ label, days: 0 }, Object.fromEntries(NUMERIC.map((k) => [k, 0])));
    b.days++;
    for (const k of NUMERIC) b[k] += r[k] as number;
    out.set(label, b);
  }
  return [...out.values()] as never;
}

export async function loadReport(supabase: SupabaseClient, outletId: string, from: string, to: string) {
  const [{ data: states }, { data: revs }, { data: entries }, { data: allocs }, { data: staff }] = await Promise.all([
    supabase.from("closing_state").select("business_date, state, current_revision_id").eq("outlet_id", outletId).gte("business_date", from).lte("business_date", to),
    supabase.from("closing_revisions").select("*").eq("outlet_id", outletId).gte("business_date", from).lte("business_date", to),
    supabase.from("entries").select("id, kind, amount, staff_id, product_name, quantity, payment_method, description, notes, expense_source, meal, business_date, received_at, recorded_by, late")
      .eq("outlet_id", outletId).eq("status", "active").gte("business_date", from).lte("business_date", to).order("server_seq").limit(20000),
    supabase.from("revision_commission_allocations").select("revision_id, staff_id, staff_name, service_total, allocated").eq("outlet_id", outletId),
    supabase.from("staff").select("id, full_name"),
  ]);
  const staffById = new Map((staff ?? []).map((s) => [s.id, s.full_name as string]));
  const stateBy = new Map((states ?? []).map((s) => [s.business_date, s]));
  const revBy = new Map((revs ?? []).map((r) => [r.id, r]));
  const activeDates = new Set((entries ?? []).map((e) => e.business_date));
  (states ?? []).forEach((s) => activeDates.add(s.business_date));

  const rows: DayRow[] = [];
  const liveAlloc = new Map<string, { staff_id: string; staff_name: string; service_total: number; allocated: number }[]>();
  for (const date of days(from, to)) {
    if (!activeDates.has(date)) continue;
    const st = stateBy.get(date);
    const frozen = st && (st.state === "submitted" || st.state === "approved") && st.current_revision_id;
    let r: Record<string, number> & { state?: string; closed_by_staff_id?: string | null };
    if (frozen) {
      r = revBy.get(st.current_revision_id!);
    } else {
      const { data } = await supabase.rpc("day_summary", { p_outlet: outletId, p_date: date });
      const d = data as DaySummary;
      liveAlloc.set(date, d.allocations);
      r = d as unknown as Record<string, number>;
    }
    rows.push({
      date, state: st?.state ?? "draft", source: frozen ? "revision" : "live",
      service: r.service_total, commission: r.commission_pool, products: r.product_total, productCash: r.product_cash,
      productPaytm: r.product_paytm, paytm: r.paytm_total, expenses: r.expenses_total, expensesOutside: r.expenses_outside_total,
      zakat: r.zakat_total, food: r.food_cost, foodShop: r.food_shop_funded,
      foodCommission: r.food_commission_funded, foodOwed: r.food_employee_owed ?? 0,
      closedBy: (r.closed_by_staff_id && staffById.get(r.closed_by_staff_id)) || "", opening: r.opening_float, topUps: r.intraday_top_ups,
      expected: r.expected_drawer, counted: r.counted_cash, variance: frozen ? r.variance : 0, requiredFloat: r.required_float,
      retained: r.retained_float, shortfall: frozen ? r.float_shortfall : 0, takeHome: frozen ? r.take_home : 0,
      commissionHandedDrawer: r.drawer_handover_total,
    });
  }

  // Employee sales and commission.
  const staffName = new Map((staff ?? []).map((s) => [s.id, s.full_name]));
  const emp = new Map<string, { name: string; sales: number; commission: number; entries: number }>();
  const add = (id: string, name: string, sales: number, commission: number, n: number) => {
    const e = emp.get(id) ?? { name, sales: 0, commission: 0, entries: 0 };
    e.sales += sales; e.commission += commission; e.entries += n;
    emp.set(id, e);
  };
  for (const row of rows) {
    if (row.source === "revision") {
      const revId = stateBy.get(row.date)!.current_revision_id;
      for (const a of (allocs ?? []).filter((x) => x.revision_id === revId)) add(a.staff_id, staffName.get(a.staff_id) ?? a.staff_name, a.service_total, a.allocated, 0);
    } else {
      for (const a of liveAlloc.get(row.date) ?? []) add(a.staff_id, staffName.get(a.staff_id) ?? a.staff_name, a.service_total, a.allocated, 0);
    }
  }
  for (const e of entries ?? []) if (e.kind === "service" && e.staff_id) add(e.staff_id, staffName.get(e.staff_id) ?? "—", 0, 0, 1);

  const prod = new Map<string, { qty: number; total: number; cash: number; paytm: number }>();
  for (const e of entries ?? []) {
    if (e.kind !== "product") continue;
    const p = prod.get(e.product_name) ?? { qty: 0, total: 0, cash: 0, paytm: 0 };
    p.qty += e.quantity; p.total += e.amount;
    if (e.payment_method === "paytm") p.paytm += e.amount; else p.cash += e.amount;
    prod.set(e.product_name, p);
  }

  return {
    rows,
    employees: [...emp.values()].sort((a, b) => b.sales - a.sales),
    products: [...prod.entries()].map(([name, v]) => ({ name, ...v })).sort((a, b) => b.total - a.total),
    expenses: (entries ?? []).filter((e) => e.kind === "expense"),
    zakat: (entries ?? []).filter((e) => e.kind === "zakat"),
    food: (entries ?? []).filter((e) => e.kind === "food"),
    staffName,
  };
}
