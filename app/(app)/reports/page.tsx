import type { Metadata } from "next";
import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { Page, Card, Table, Notice, input, labelCls, btnSecondary, fmtTime } from "@/components/ui";
import { PrintButton } from "@/components/print-button";
import { loadReport, group, MAX_DAYS } from "@/lib/reports";
import { rupees, signedRupees } from "@/lib/money";
import { parsePeriod } from "@/lib/period";

export const metadata: Metadata = { title: "Reports" };

export default async function Reports({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const ctx = await requirePermission("reports.read");
  const sp = await searchParams;
  const today = ctx.today ?? new Date().toISOString().slice(0, 10);
  const p = parsePeriod(sp, today);
  if ("error" in p) return <Page title="Reports"><Notice tone="error">{p.error}</Notice></Page>;
  const { from, to, by } = p;
  const r = await loadReport(ctx.supabase, ctx.outlet.id, from, to);
  const g = group(r.rows, by);
  const T = (k: keyof (typeof g)[number]) => g.reduce((a, x) => a + (x[k] as number), 0);
  const qs = `from=${from}&to=${to}&by=${by}`;
  const quick = (label: string, f: string, t: string, b: string) => (
    <Link className={btnSecondary} href={`/reports?from=${f}&to=${t}&by=${b}`}>{label}</Link>
  );
  const monthStart = today.slice(0, 8) + "01";
  const weekStart = (() => { const d = new Date(today + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7)); return d.toISOString().slice(0, 10); })();

  return (
    <Page title="Reports" actions={<>
      <a className={btnSecondary} href={`/api/export?${qs}`}>Download Excel</a>
      <PrintButton />
    </>}>
      <div className="no-print flex flex-wrap items-end gap-2">
        {quick("Today", today, today, "day")}
        {quick("This week", weekStart, today, "day")}
        {quick("This month", monthStart, today, "day")}
        {quick("Month by week", monthStart, today, "week")}
        <form className="flex flex-wrap items-end gap-2">
          <div><label className={labelCls} htmlFor="f">From</label><input id="f" type="date" name="from" defaultValue={from} className={input} /></div>
          <div><label className={labelCls} htmlFor="t">To</label><input id="t" type="date" name="to" defaultValue={to} className={input} /></div>
          <div><label className={labelCls} htmlFor="b">Group by</label>
            <select id="b" name="by" defaultValue={by} className={input}><option value="day">Day</option><option value="week">Week</option><option value="month">Month</option></select></div>
          <button className={btnSecondary}>Show</button>
        </form>
      </div>
      <p className="text-sm text-slate-600">{ctx.outlet.name} · {from} to {to} (max {MAX_DAYS} days). Submitted and approved days use the frozen closing; open days are live.</p>

      <Card title="Sales and cash summary">
        <Table
          head={["Period", "Services", "Commission", "Products", "Paytm", "Expenses", "Zakat", "Food", "Difference", "Taken home"]}
          rows={g.map((x) => [x.label, rupees(x.service), rupees(x.commission), rupees(x.products), rupees(x.paytm), rupees(x.expenses), rupees(x.zakat), rupees(x.food), signedRupees(x.variance), rupees(x.takeHome)])}
          foot={["Total", rupees(T("service")), rupees(T("commission")), rupees(T("products")), rupees(T("paytm")), rupees(T("expenses")), rupees(T("zakat")), rupees(T("food")), signedRupees(T("variance")), rupees(T("takeHome"))]}
          empty="No activity in this period."
        />
      </Card>

      <div className="grid gap-5 lg:grid-cols-2">
        <Card title="Employee sales and commission">
          <Table head={["Employee", "Entries", "Sales", "Commission"]}
            rows={r.employees.map((e) => [e.name, e.entries, rupees(e.sales), rupees(e.commission)])}
            foot={["Total", r.employees.reduce((a, e) => a + e.entries, 0), rupees(r.employees.reduce((a, e) => a + e.sales, 0)), rupees(r.employees.reduce((a, e) => a + e.commission, 0))]}
            empty="No service sales." />
        </Card>
        <Card title="Product sales">
          <Table head={["Product", "Qty", "Cash", "Paytm", "Total"]}
            rows={r.products.map((p) => [p.name, p.qty, rupees(p.cash), rupees(p.paytm), rupees(p.total)])}
            foot={["Total", r.products.reduce((a, p) => a + p.qty, 0), rupees(r.products.reduce((a, p) => a + p.cash, 0)), rupees(r.products.reduce((a, p) => a + p.paytm, 0)), rupees(r.products.reduce((a, p) => a + p.total, 0))]}
            empty="No product sales." />
        </Card>
      </div>

      <Card title="Cash reconciliation (per day)">
        <Table head={["Day", "Status", "Closing by", "Opening", "Added", "Expected", "Counted", "Difference", "Float kept", "Shortfall", "Taken home"]}
          rows={r.rows.map((d) => [<Link key="l" className="underline" href={`/closing/${d.date}`}>{d.date}</Link>, d.state, d.closedBy || "—", rupees(d.opening), rupees(d.topUps),
            rupees(d.expected), d.source === "revision" ? rupees(d.counted) : "—", d.source === "revision" ? signedRupees(d.variance) : "—",
            d.source === "revision" ? rupees(d.retained) : "—", d.source === "revision" ? rupees(d.shortfall) : "—", d.source === "revision" ? rupees(d.takeHome) : "—"])}
          empty="No closings in this period." />
      </Card>

      <div className="grid gap-5 lg:grid-cols-2">
        <Card title="Expenses">
          <Table head={["Day", "Time", "Description", "Paid from", "Amount"]}
            rows={r.expenses.map((e) => [e.business_date, fmtTime(e.received_at), e.description + (e.notes ? ` (${e.notes})` : ""), e.expense_source === "cash_drawer" ? "Drawer" : "Outside", rupees(e.amount)])}
            foot={["Total", "", "", "", rupees(r.expenses.reduce((a, e) => a + e.amount, 0))]} empty="No expenses." />
        </Card>
        <Card title="Zakat and food">
          <Table head={["Day", "Type", "Detail", "Amount"]}
            rows={[...r.zakat.map((z) => [z.business_date, "Zakat", z.description ?? (z.staff_id ? r.staffName.get(z.staff_id) : ""), rupees(z.amount)]),
              ...r.food.map((f) => [f.business_date, "Food", f.meal, rupees(f.amount)])]}
            empty="No zakat or food." />
        </Card>
      </div>
    </Page>
  );
}
