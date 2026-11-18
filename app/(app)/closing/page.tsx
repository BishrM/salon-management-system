import type { Metadata } from "next";
import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { Page, Card, StateBadge, Table, Notice, fmtDate, labelCls, input } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { prepareClosing } from "../actions";
import { rupees, signedRupees } from "@/lib/money";

export const metadata: Metadata = { title: "Closing" };

export default async function ClosingList() {
  const ctx = await requirePermission("outlet.read");
  const { supabase, outlet, today } = ctx;
  const [{ data: states }, { data: revs }] = await Promise.all([
    supabase.from("closing_state").select("*").eq("outlet_id", outlet.id).order("business_date", { ascending: false }).limit(60),
    supabase.from("closing_revisions").select("closing_id, revision_no, service_total, expected_drawer, counted_cash, variance, take_home")
      .eq("outlet_id", outlet.id).order("business_date", { ascending: false }).limit(200),
  ]);
  const latest = new Map<string, NonNullable<typeof revs>[number]>();
  for (const r of revs ?? []) if (!latest.has(r.closing_id) || latest.get(r.closing_id)!.revision_no < r.revision_no) latest.set(r.closing_id, r);

  return (
    <Page title="Daily closing">
      {!today && <Notice tone="warn">Setup is not finished (business-day cutoff).</Notice>}
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
