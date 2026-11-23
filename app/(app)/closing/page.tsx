import type { Metadata } from "next";
import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { Page, Card, Row, StateBadge, Table, Notice, fmtDate, labelCls, input } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { prepareClosing, recordFoodRepayment, reverseFoodRepayment } from "../actions";
import { PAID_BY } from "@/lib/labels";
import { rupees, signedRupees } from "@/lib/money";
import { OpenSheetForm } from "./sheet/open-form";

export const metadata: Metadata = { title: "Closing" };

export default async function ClosingList() {
  const ctx = await requirePermission("outlet.read");
  const { supabase, outlet, today } = ctx;
  const [{ data: states }, { data: revs }, { data: debt }, { data: people }] = await Promise.all([
    supabase.from("closing_state").select("*").eq("outlet_id", outlet.id).order("business_date", { ascending: false }).limit(60),
    supabase.from("closing_revisions").select("closing_id, revision_no, service_total, expected_drawer, counted_cash, variance, take_home")
      .eq("outlet_id", outlet.id).order("business_date", { ascending: false }).limit(200),
    supabase.rpc("food_debt_summary", { p_outlet: outlet.id }),
    supabase.from("staff_assignments").select("staff:staff_id(id, full_name)").eq("outlet_id", outlet.id),
  ]);
  const d = debt as FoodDebt | null;
  const staff = new Map((people ?? []).map((p) => p.staff as unknown as { id: string; full_name: string }).filter(Boolean).map((p) => [p.id, p.full_name]));
  const latest = new Map<string, NonNullable<typeof revs>[number]>();
  for (const r of revs ?? []) if (!latest.has(r.closing_id) || latest.get(r.closing_id)!.revision_no < r.revision_no) latest.set(r.closing_id, r);

  return (
    <Page title="Daily closing">
      {!today && <Notice tone="warn">Setup is not finished (business-day cutoff).</Notice>}
      {today && <OpenSheetForm today={today} />}
      {today && ctx.can("closing.prepare") && (
        <Card title="Close a day">
          <ActionForm action={prepareClosing} submit="Open closing" inline>
            <input type="hidden" name="outlet" value={outlet.id} />
            <div>
              <label htmlFor="date" className={labelCls}>Business day</label>
              <input id="date" name="date" type="date" defaultValue={today} max={today} className={input} required />
            </div>
          </ActionForm>
        </Card>
      )}
      {d && (d.owed_approved > 0 || d.owed_pending_approval > 0 || d.repayments.length > 0) && (
        <Card title="Food owed to the salon by employees">
          <p className="mb-3 text-sm text-slate-600">When lunch and dinner cost more than the day&apos;s commission, the difference is owed to the salon.
            It is never taken from the cash drawer. It counts once the owner approves the closing, and goes down only when a repayment is recorded.
            The app does not split it between employees.</p>
          <div className="max-w-md">
            <Row label="Owed (approved closings)" value={rupees(d.owed_approved)} />
            {d.owed_pending_approval > 0 && <Row sub label="waiting for approval (not yet counted)" value={rupees(d.owed_pending_approval)} />}
            <Row label="Repaid" value={`− ${rupees(d.repaid)}`} />
            <Row strong label={d.outstanding >= 0 ? "Still owed to the salon" : "Repaid more than currently owed (a reopened day is waiting)"}
              value={<span className={d.outstanding > 0 ? "text-rose-700" : ""}>{rupees(Math.abs(d.outstanding))}</span>} />
          </div>
          {d.days.length > 0 && <div className="mt-3"><Table head={["Day", "Status", "Food owed"]}
            rows={d.days.map((x) => [fmtDate(x.business_date), <StateBadge key="s" state={x.state} />, rupees(x.owed)])} /></div>}
          {d.repayments.length > 0 && <div className="mt-3"><Table head={["Received", "Amount", "Method", "From", "Note", ""]}
            rows={d.repayments.map((r) => [
              fmtDate(r.received_on),
              r.reverses_repayment_id ? `− ${rupees(r.amount)} (reversal)` : rupees(r.amount),
              PAID_BY[r.payment_method] ?? r.payment_method,
              r.staff_ids.map((id) => staff.get(id) ?? "—").join(", ") || "—",
              r.reverses_repayment_id ? r.reason ?? "" : r.note ?? "",
              !r.reverses_repayment_id && !r.reversed && ctx.can("food_repayment.record") ? (
                <ActionForm key="rv" action={reverseFoodRepayment} submit="Reverse" inline danger confirm="Reverse this repayment? It stays in the history.">
                  <input type="hidden" name="repayment" value={r.id} />
                  <input name="reason" placeholder="Reason" className={input} required aria-label="Reason" />
                </ActionForm>
              ) : r.reversed ? "reversed" : "",
            ])} /></div>}
          {ctx.can("food_repayment.record") && d.outstanding > 0 && (
            <div className="mt-4"><ActionForm action={recordFoodRepayment} submit="Record repayment" confirm="Record this food repayment? It is received outside the cash drawer.">
              <input type="hidden" name="outlet" value={outlet.id} />
              <div className="grid gap-3 sm:grid-cols-3">
                <div><label className={labelCls} htmlFor="fr-amt">Amount received (₹, up to {rupees(d.outstanding)})</label><input id="fr-amt" name="amount" inputMode="numeric" className={input} required /></div>
                <div><label className={labelCls} htmlFor="fr-m">Paid by</label>
                  <select id="fr-m" name="method" className={input}><option value="cash">Cash (to the owner, not the drawer)</option><option value="paytm">UPI / Paytm / Card</option></select></div>
                <div><label className={labelCls} htmlFor="fr-d">Date received</label><input id="fr-d" name="received" type="date" defaultValue={today ?? undefined} max={today ?? undefined} className={input} required /></div>
              </div>
              <fieldset><legend className={labelCls}>Handed over by (optional)</legend>
                <div className="flex flex-wrap gap-x-4 gap-y-2">{[...staff].map(([id, n]) => (
                  <label key={id} className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" name="staff" value={id} className="h-5 w-5" /> {n}</label>
                ))}</div></fieldset>
              <div><label className={labelCls} htmlFor="fr-n">Note (optional)</label><input id="fr-n" name="note" maxLength={500} className={input} /></div>
            </ActionForm></div>
          )}
        </Card>
      )}

      <Card title="Recent days">
        <Table
          head={["Day", "Status", "Services", "Expected", "Counted", "Difference", ""]}
          rows={(states ?? []).map((s) => {
            const r = latest.get(s.closing_id);
            return [
              fmtDate(s.business_date),
              <StateBadge key="s" state={s.state} />,
              r ? rupees(r.service_total) : "—",
              r ? rupees(r.expected_drawer) : "—",
              r ? rupees(r.counted_cash) : "—",
              r ? <span key="v" className={r.variance ? "font-semibold text-rose-700" : ""}>{signedRupees(r.variance)}</span> : "—",
              <Link key="l" href={`/closing/${s.business_date}`} className="font-semibold text-brand-700 underline">Open</Link>,
            ];
          })}
          empty="No closings yet."
        />
      </Card>
    </Page>
  );
}

type FoodDebt = {
  owed_approved: number; owed_pending_approval: number; repaid: number; outstanding: number;
  days: { business_date: string; state: string; owed: number }[];
  repayments: { id: string; amount: number; payment_method: string; received_on: string; staff_ids: string[]; note: string | null;
    reverses_repayment_id: string | null; reason: string | null; reversed: boolean }[];
};
