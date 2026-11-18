import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { Page, Row, Table, Notice, fmtDate, StateBadge } from "@/components/ui";
import { PrintButton } from "@/components/print-button";
import { rupees, signedRupees } from "@/lib/money";
import { SETTLEMENT } from "@/lib/labels";
import type { DaySummary } from "@/lib/types";

export const metadata: Metadata = { title: "Commission statement" };

// Printable statement for the head employee (SRS §3.2, Rev 6 §5.1/§5.8, J3).
export default async function Statement({ params }: { params: Promise<{ date: string }> }) {
  const { date } = await params;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) notFound();
  const { supabase, outlet } = await requirePermission("outlet.read");
  const { data, error } = await supabase.rpc("day_summary", { p_outlet: outlet.id, p_date: date });
  if (error) return <Page title="Statement"><Notice tone="error">{error.message}</Notice></Page>;
  const s = data as DaySummary;
  // Prefer the frozen revision's allocations when the day has been submitted.
  let alloc = s.allocations;
  if (s.current_revision_id && !["draft", "rejected", "reopened"].includes(s.state)) {
    const { data: rows } = await supabase.from("revision_commission_allocations")
      .select("staff_id, staff_name, service_total, exact_share, allocated, rounding_adj").eq("revision_id", s.current_revision_id).order("staff_name");
    alloc = rows ?? alloc;
  }
  const { data: recip } = s.closing_id
    ? await supabase.from("commission_handovers").select("recipient_staff_id, staff:recipient_staff_id(full_name)").eq("closing_id", s.closing_id).eq("kind", "handover")
    : { data: [] };
  const recipients = [...new Set((recip ?? []).map((r) => (r.staff as unknown as { full_name: string } | null)?.full_name).filter(Boolean))];
  const st = s.settlement;

  return (
    <Page title="Commission statement" actions={<PrintButton />}>
      <div className="rounded-xl border border-slate-200 bg-white p-6 print-full">
        <div className="mb-4 flex flex-wrap items-start justify-between gap-2">
          <div>
            <p className="text-lg font-semibold">{outlet.name}</p>
            <p className="text-slate-600">Business date: {fmtDate(date)}</p>
          </div>
          <StateBadge state={s.state} />
        </div>
        <Table
          head={["Employee", "Service sales", "Exact 10%", "Commission (₹10)", "Rounding"]}
          rows={alloc.map((a) => [a.staff_name, rupees(a.service_total), rupees(a.exact_share), rupees(a.allocated), signedRupees(a.rounding_adj)])}
          foot={["Total", rupees(s.service_total), rupees(alloc.reduce((x, a) => x + a.exact_share, 0)), rupees(s.commission_pool),
            signedRupees(alloc.reduce((x, a) => x + a.rounding_adj, 0))]}
          empty="No service sales on this day."
        />
        <div className="mt-5 max-w-md">
          <Row label="Commission pool" value={rupees(s.commission_pool)} />
          <Row label="Food cost" value={rupees(s.food_cost)} />
          <Row sub label="paid from commission" value={`− ${rupees(s.food_commission_funded)}`} />
          {s.food_shop_funded > 0 && <Row sub label="paid by the shop" value={rupees(s.food_shop_funded)} />}
          <Row sub label="food not yet paid from drawer" value={rupees(s.food_not_paid_drawer)} />
          <Row strong label="Remaining commission cash" value={rupees(s.remaining_payable)} />
          {st && <>
            <Row label="Handed from drawer" value={rupees(st.drawer_net)} />
            <Row label="Handed outside drawer" value={rupees(st.handed_outside_drawer)} />
            <Row label="Returned" value={rupees(st.returned)} />
            <Row label="Net handed over" value={rupees(st.net_transferred)} />
            <Row label="Still owed" value={rupees(st.outstanding)} />
            {st.accepted_overpayment > 0 && <Row label="Accepted overpayment" value={rupees(st.accepted_overpayment)} />}
            <Row strong label="Distribution status" value={SETTLEMENT[st.status] ?? st.status} />
          </>}
          <Row label="Recipient (head employee)" value={recipients.join(", ") || "—"} />
        </div>
        <p className="mt-5 text-xs text-slate-500">
          Pool is 10% of total service sales rounded down to ₹10; individual amounts are rounded to ₹10 by largest remainder so they add up to the pool.
        </p>
        <div className="mt-10 grid grid-cols-2 gap-10 text-sm">
          <div className="border-t border-slate-400 pt-1">Head employee signature</div>
          <div className="border-t border-slate-400 pt-1">Manager signature</div>
        </div>
      </div>
    </Page>
  );
}
