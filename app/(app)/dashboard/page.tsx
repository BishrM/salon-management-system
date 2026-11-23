import type { Metadata } from "next";
import Link from "next/link";
import { getContext } from "@/lib/session";
import { redirect } from "next/navigation";
import { Page, Card, Stat, StateBadge, Notice, Table, fmtTime, btnSecondary } from "@/components/ui";
import { LiveRefresh } from "@/components/live-refresh";
import { rupees } from "@/lib/money";
import { KIND, WARNINGS, PAID_BY, isEdited } from "@/lib/labels";
import type { DaySummary } from "@/lib/types";

export const metadata: Metadata = { title: "Dashboard" };

export default async function Dashboard({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
  const ctx = await getContext();
  if (!ctx.outlet) redirect("/no-outlet");
  if (!ctx.can("closing.prepare") && !ctx.can("reports.read")) redirect("/?denied=1");
  if (!ctx.today) {
    return <Page title="Dashboard"><Notice tone="warn">Finish the setup checklist first (Admin → Setup).</Notice></Page>;
  }
  const { date: q } = await searchParams;
  const date = q && /^\d{4}-\d{2}-\d{2}$/.test(q) ? q : ctx.today;
  const { supabase, outlet } = ctx;
  const [{ data: summary, error }, { data: recent }, { data: staff }, { count: unassigned }] = await Promise.all([
    supabase.rpc("day_summary", { p_outlet: outlet.id, p_date: date }),
    supabase.from("entries").select("id, kind, amount, staff_id, product_name, description, meal, payment_method, status, version, received_at, recorded_by, late")
      .eq("outlet_id", outlet.id).eq("business_date", date).order("server_seq", { ascending: false }).limit(25),
    supabase.from("staff").select("id, full_name"),
    supabase.from("entries").select("id", { count: "exact", head: true }).eq("outlet_id", outlet.id).is("business_date", null).eq("status", "active"),
  ]);
  if (error) return <Page title="Dashboard"><Notice tone="error">{error.message}</Notice></Page>;
  const s = summary as DaySummary;
  const names = new Map((staff ?? []).map((x) => [x.id, x.full_name]));
  const paytmKnown = s.paytm_entered;

  return (
    <Page
      title={date === ctx.today ? "Today" : `Day ${date}`}
      actions={
        <form className="flex gap-2">
          <label htmlFor="d" className="sr-only">Date</label>
          <input id="d" type="date" name="date" defaultValue={date} max={ctx.today} className="min-h-11 rounded-lg border border-slate-300 px-2" />
          <button className={btnSecondary}>Show</button>
        </form>
      }
    >
      <LiveRefresh outletId={outlet.id} />
      <div className="flex flex-wrap items-center gap-3">
        <StateBadge state={s.state} />
        {s.needs_review && <span className="rounded-full bg-rose-100 px-2.5 py-0.5 text-xs font-semibold text-rose-900">Needs review</span>}
        <Link href={`/closing/${date}`} className="text-sm font-semibold text-brand-700 underline">Open closing</Link>
      </div>
      {(unassigned ?? 0) > 0 && ctx.can("date.assign") && (
        <Notice tone="warn">{unassigned} offline entr{unassigned === 1 ? "y needs" : "ies need"} a date. <Link className="underline" href="/admin/review">Review</Link></Notice>
      )}
      {s.warnings.map((w) => <Notice key={w} tone="warn">{WARNINGS[w] ?? w}</Notice>)}

      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Service sales" value={s.service_total}
          hint={`Cash ${rupees(s.service_cash_recorded)} · UPI/Paytm/Card ${rupees(s.service_paytm_recorded)}${s.service_method_unrecorded ? ` · not recorded ${rupees(s.service_method_unrecorded)}` : ""}`} />
        <Stat label="Commission" value={s.commission_pool} hint="10%, rounded down to ₹10" />
        <Stat label="Product sales" value={s.product_total} hint={`Cash ${rupees(s.product_cash)} · Paytm ${rupees(s.product_paytm)}`} />
        <Stat label="Paytm" value={paytmKnown ? s.paytm_total : null} hint={paytmKnown ? "entered at closing" : "not entered yet"} />
        <Stat label={paytmKnown ? "Physical cash expected" : "Cash estimate (before Paytm)"} value={s.net_cash}
          hint="Service − commission + products − Paytm − expenses − zakat" />
        <Stat label="Expenses (drawer)" value={s.expenses_total} hint={s.expenses_outside_total ? `+ ${rupees(s.expenses_outside_total)} paid outside` : undefined} />
        <Stat label="Zakat" value={s.zakat_total} />
        <Stat label="Food (from commission)" value={s.food_cost} hint={`Paid from drawer ${rupees(s.food_paid_drawer)}`} />
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
        <Card title="Employee sales">
          <Table
            head={["Employee", "Sales", "Commission"]}
            rows={s.allocations.map((a) => [a.staff_name, rupees(a.service_total), rupees(a.allocated)])}
            foot={["Total", rupees(s.service_total), rupees(s.commission_pool)]}
            empty="No service sales yet."
          />
        </Card>
        <Card title="Recent entries">
          <Table
            head={["Time", "Type", "Detail", "Amount"]}
            rows={(recent ?? []).map((e) => [
              fmtTime(e.received_at),
              KIND[e.kind],
              <span key="d" className={e.status === "voided" ? "line-through text-slate-400" : ""}>
                {e.kind === "service" ? names.get(e.staff_id ?? "") : e.product_name ?? e.description ?? e.meal ?? ""}
                {e.late ? " (late)" : ""}
                {e.payment_method ? <span className="text-slate-500"> · {PAID_BY[e.payment_method]}</span> : null}
                {isEdited(e) && (ctx.can("audit.read")
                  ? <Link href={`/admin/audit?table=entries&row=${e.id}`} title="See what changed, who changed it and when"
                      className="ml-1 rounded bg-violet-100 px-1 text-xs font-semibold text-violet-900 underline">EDITED</Link>
                  : <span className="ml-1 rounded bg-violet-100 px-1 text-xs font-semibold text-violet-900">EDITED</span>)}
              </span>,
              rupees(e.amount),
            ])}
            empty="No entries yet."
          />
        </Card>
      </div>
    </Page>
  );
}
