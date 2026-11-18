import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Notice, Table, input, labelCls, fmtTime } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { InitialFloatForm } from "./initial-float-form";
import { recordTopUp, changeRequiredFloat, reverseFloatMovement } from "../../actions";
import { rupees } from "@/lib/money";

export const metadata: Metadata = { title: "Cash float" };

// SRS §3.6 / Rev 6 §3.4: only owner and owner's son change the float; every change is recorded.
export default async function FloatPage() {
  const ctx = await requirePermission("float.manage");
  const { supabase, outlet, today, can } = ctx;
  const [{ data: moves }, { data: profiles }, { data: shortfalls }] = await Promise.all([
    supabase.from("float_movements").select("*").eq("outlet_id", outlet.id).order("recorded_at", { ascending: false }).limit(100),
    supabase.from("profiles").select("id, full_name"),
    supabase.from("closing_revisions").select("id, business_date, revision_no, float_shortfall").eq("outlet_id", outlet.id).gt("float_shortfall", 0).order("business_date", { ascending: false }).limit(20),
  ]);
  const name = (id: string) => profiles?.find((p) => p.id === id)?.full_name ?? "—";
  const initial = moves?.find((m) => m.type === "initial_float");
  const reversed = new Set((moves ?? []).map((m) => m.reverses_movement_id).filter(Boolean));

  return (
    <Page title="Cash float">
      <Card title="Starting float (one time)">
        {initial ? (
          <p className="text-sm">Initial float {rupees(initial.amount)} from {initial.effective_business_date} — counted, entered and self-confirmed by {name(initial.recorded_by)}, {fmtTime(initial.recorded_at)}. It cannot be changed; fix a miscount with a top-up.</p>
        ) : can("float.initial") ? (
          <InitialFloatForm outletId={outlet.id} today={today ?? ""} denominations={outlet.denominations} />
        ) : (
          <Notice tone="warn">The owner must count and record the starting float before the first closing can be approved.</Notice>
        )}
      </Card>

      <div className="grid gap-5 md:grid-cols-2">
        <Card title="Add cash to the float">
          <ActionForm action={recordTopUp} submit="Record top-up" confirm="Record this cash added to the float?">
            <input type="hidden" name="outlet" value={outlet.id} />
            <div className="grid grid-cols-2 gap-3">
              <div><label className={labelCls} htmlFor="te">For business day</label><input id="te" name="effective" type="date" defaultValue={today ?? undefined} className={input} required /></div>
              <div><label className={labelCls} htmlFor="ta">Amount (₹)</label><input id="ta" name="amount" inputMode="numeric" className={input} required /></div>
            </div>
            <div><label className={labelCls} htmlFor="tt">When</label>
              <select id="tt" name="timing" className={input}>
                <option value="pre_opening">Before opening (part of the opening float)</option>
                <option value="intraday">During the day (extra change)</option>
              </select></div>
            <div className="grid grid-cols-2 gap-3">
              <div><label className={labelCls} htmlFor="ts">Source</label>
                <select id="ts" name="source" className={input}>
                  <option value="owner_funds">Owner&apos;s money</option>
                  <option value="previous_take_home">Previous take-home</option>
                  <option value="other">Other</option>
                </select></div>
              <div><label className={labelCls} htmlFor="tn">Source note (if other)</label><input id="tn" name="note" className={input} /></div>
            </div>
            {(shortfalls ?? []).length > 0 && (
              <div><label className={labelCls} htmlFor="tr">Replaces the shortfall of</label>
                <select id="tr" name="relates" className={input}>
                  <option value="">—</option>
                  {shortfalls!.map((s) => <option key={s.id} value={s.id}>{s.business_date} (rev {s.revision_no}): {rupees(s.float_shortfall)} short</option>)}
                </select></div>
            )}
            <div><label className={labelCls} htmlFor="tz">Reason</label><input id="tz" name="reason" className={input} required /></div>
          </ActionForm>
        </Card>
        <Card title="Change the required float">
          <ActionForm action={changeRequiredFloat} submit="Change required float" confirm="Change the float to keep in the drawer from this day on?">
            <input type="hidden" name="outlet" value={outlet.id} />
            <div className="grid grid-cols-2 gap-3">
              <div><label className={labelCls} htmlFor="re">From business day</label><input id="re" name="effective" type="date" defaultValue={today ?? undefined} className={input} required /></div>
              <div><label className={labelCls} htmlFor="ra">Keep in drawer (₹)</label><input id="ra" name="amount" inputMode="numeric" className={input} required /></div>
            </div>
            <div><label className={labelCls} htmlFor="rr">Reason</label><input id="rr" name="reason" className={input} required /></div>
          </ActionForm>
        </Card>
      </div>

      <Card title="Float history">
        <Table head={["Recorded", "Type", "Day", "Amount", "Source", "By", "Reason", ""]} rows={(moves ?? []).map((m) => [
          fmtTime(m.recorded_at),
          (m.reverses_movement_id ? "reversal of " : "") + (m.type === "top_up" ? `top-up (${m.timing === "intraday" ? "during day" : "before opening"})` : m.type.replace(/_/g, " ")),
          m.effective_business_date,
          m.type === "required_float_change" ? `keep ${rupees(m.new_required_float)}` : rupees(m.amount),
          m.source ? m.source.replace(/_/g, " ") + (m.source_note ? ` (${m.source_note})` : "") : "—",
          name(m.recorded_by),
          m.reason,
          m.type !== "initial_float" && !m.reverses_movement_id && !reversed.has(m.id) ? (
            <ActionForm key="r" action={reverseFloatMovement} submit="Reverse" inline danger confirm="Reverse this movement? A reversing row is added; nothing is deleted.">
              <input type="hidden" name="movement" value={m.id} />
              <input name="reason" placeholder="Reason" className={input} required aria-label="Reversal reason" />
            </ActionForm>
          ) : "",
        ])} empty="No float movements yet." />
      </Card>
    </Page>
  );
}
