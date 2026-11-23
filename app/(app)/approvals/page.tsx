import type { Metadata } from "next";
import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { Page, Card, Table, StateBadge, fmtDate, fmtTime } from "@/components/ui";
import { rupees, signedRupees } from "@/lib/money";

export const metadata: Metadata = { title: "Approvals" };

export default async function Approvals() {
  const { supabase, outlet, userId } = await requirePermission("closing.approve");
  const { data: states } = await supabase.from("closing_state").select("*").eq("outlet_id", outlet.id)
    .in("state", ["submitted", "rejected", "reopened", "draft"]).order("business_date");
  const ids = (states ?? []).map((s) => s.current_revision_id).filter(Boolean);
  const { data: revs } = ids.length
    ? await supabase.from("closing_revisions").select("id, variance, variance_reason, paytm_flags, submitted_by, submitted_at, take_home, closed_by_staff_id, food_employee_owed, staff:closed_by_staff_id(full_name)").in("id", ids)
    : { data: [] };
  const rev = new Map((revs ?? []).map((r) => [r.id, r]));
  const firstPending = (states ?? [])[0]?.business_date;

  return (
    <Page title="Approvals">
      <p className="text-sm text-slate-600">Days are approved in date order. A day cannot be approved while an earlier day is open, rejected or under review.</p>
      <Card>
        <Table
          head={["Day", "Status", "Difference", "Flags", "Closing done by", "Food owed", "Submitted", ""]}
          rows={(states ?? []).map((s) => {
            const r = s.current_revision_id ? rev.get(s.current_revision_id) : null;
            return [
              fmtDate(s.business_date) + (s.business_date === firstPending ? " · next" : ""),
              <StateBadge key="s" state={s.state} />,
              r ? <span key="v" className={r.variance ? "font-semibold text-rose-700" : ""}>{signedRupees(r.variance)}{r.variance_reason ? ` — ${r.variance_reason}` : ""}</span> : "—",
              r?.paytm_flags?.length ? r.paytm_flags.join(", ") : "—",
              (r?.staff as unknown as { full_name: string } | null)?.full_name ?? "—",
              r?.food_employee_owed ? rupees(r.food_employee_owed) : "—",
              r ? `${fmtTime(r.submitted_at)}${r.submitted_by === userId ? " (you)" : ""}` : "—",
              <Link key="l" href={`/closing/${s.business_date}`} className="font-semibold text-brand-700 underline">Review</Link>,
            ];
          })}
          empty="Nothing waiting."
        />
      </Card>
    </Page>
  );
}
