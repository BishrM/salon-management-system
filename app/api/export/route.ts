import { NextResponse } from "next/server";
import { getContext } from "@/lib/session";
import { loadReport, group } from "@/lib/reports";
import { parsePeriod } from "@/lib/period";
import { buildXlsx, type Cell } from "@/lib/xlsx";

// Excel export of the report (SRS §7.3). Amounts are written in rupees as numbers (paise / 100 is exact
// for whole-rupee values and two-decimal for any paise), so totals can be summed in Excel.
const r = (p: number | null | undefined): Cell => (p == null ? null : p / 100);

export async function GET(req: Request) {
  const ctx = await getContext();
  if (!ctx.outlet || !ctx.can("reports.read")) return NextResponse.json({ error: "Not allowed" }, { status: 403 });
  const sp = Object.fromEntries(new URL(req.url).searchParams);
  const p = parsePeriod(sp, ctx.today ?? new Date().toISOString().slice(0, 10));
  if ("error" in p) return NextResponse.json({ error: p.error }, { status: 400 });
  const data = await loadReport(ctx.supabase, ctx.outlet.id, p.from, p.to);
  const g = group(data.rows, p.by);

  const xlsx = buildXlsx([
    { name: "Summary", rows: [
      [`${ctx.outlet.name} — ${p.from} to ${p.to} (₹)`],
      ["Period", "Days", "Services", "Commission", "Products", "Product cash", "Product Paytm", "Paytm total", "Expenses (drawer)", "Expenses (outside)", "Zakat", "Food", "Food paid by salon", "Food from commission", "Food owed by employees", "Difference", "Taken home"],
      ...g.map((x) => [x.label, x.days, r(x.service), r(x.commission), r(x.products), r(x.productCash), r(x.productPaytm), r(x.paytm), r(x.expenses), r(x.expensesOutside), r(x.zakat), r(x.food), r(x.foodShop), r(x.foodCommission), r(x.foodOwed), r(x.variance), r(x.takeHome)]),
    ] },
    { name: "Employees", rows: [["Employee", "Entries", "Service sales", "Commission"], ...data.employees.map((e) => [e.name, e.entries, r(e.sales), r(e.commission)])] },
    { name: "Products", rows: [["Product", "Quantity", "Cash", "Paytm", "Total"], ...data.products.map((x) => [x.name, x.qty, r(x.cash), r(x.paytm), r(x.total)])] },
    { name: "Cash reconciliation", rows: [
      ["Day", "Status", "Source", "Closing done by", "Opening float", "Added during day", "Expected", "Counted", "Difference", "Required float", "Float kept", "Shortfall", "Taken home", "Commission from drawer"],
      ...data.rows.map((d) => [d.date, d.state, d.source, d.closedBy, r(d.opening), r(d.topUps), r(d.expected), d.source === "revision" ? r(d.counted) : null, r(d.variance), r(d.requiredFloat), r(d.retained), r(d.shortfall), r(d.takeHome), r(d.commissionHandedDrawer)]),
    ] },
    { name: "Expenses", rows: [["Day", "Recorded", "Description", "Notes", "Paid from", "Amount"], ...data.expenses.map((e) => [e.business_date, e.received_at, e.description, e.notes, e.expense_source, r(e.amount)])] },
    { name: "Zakat", rows: [["Day", "Recorded", "Given by", "Note", "Amount"], ...data.zakat.map((z) => [z.business_date, z.received_at, z.staff_id ? data.staffName.get(z.staff_id) ?? "" : "", z.description, r(z.amount)])] },
    { name: "Food", rows: [["Day", "Recorded", "Meal", "Cost"], ...data.food.map((f) => [f.business_date, f.received_at, f.meal, r(f.amount)])] },
  ]);

  return new NextResponse(new Uint8Array(xlsx), {
    headers: {
      "content-type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "content-disposition": `attachment; filename="salonops-${p.from}-to-${p.to}.xlsx"`,
      "cache-control": "no-store",
    },
  });
}
