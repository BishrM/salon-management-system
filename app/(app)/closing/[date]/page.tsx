import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/session";
import { Page, Card, Row, StateBadge, Notice, Table, fmtTime, fmtDate, input, labelCls, ButtonLink } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { rupees, signedRupees } from "@/lib/money";
import { BLOCKERS, WARNINGS, ACKS, SETTLEMENT, KIND } from "@/lib/labels";
import type { DaySummary, Revision } from "@/lib/types";
import {
  updateDraft, submitClosing, approveClosing, rejectClosing, reopenClosing, allocateFoodExcess, recordHandover,
  recordReturn, acceptOverpayment, acknowledgeReview, reviewLateEntry, prepareClosing,
} from "../../actions";

export async function generateMetadata({ params }: { params: Promise<{ date: string }> }): Promise<Metadata> {
  return { title: `Closing ${(await params).date}` };
}

const EDITABLE = ["draft", "rejected", "reopened"];

export default async function ClosingDay({ params }: { params: Promise<{ date: string }> }) {
  const { date } = await params;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) notFound();
  const ctx = await requirePermission("outlet.read");
  const { supabase, outlet, can } = ctx;
  const { data: sum, error } = await supabase.rpc("day_summary", { p_outlet: outlet.id, p_date: date });
  if (error) return <Page title="Closing"><Notice tone="error">{error.message}</Notice></Page>;
  const s = sum as DaySummary;
  const closing = s.closing_id;

  const [{ data: revisions }, { data: events }, { data: handovers }, { data: staff }, { data: lateEntries }, { data: latePays }, { data: reviews }, { data: profiles }] =
    await Promise.all([
      closing ? supabase.from("closing_revisions").select("*").eq("closing_id", closing).order("revision_no") : Promise.resolve({ data: [] }),
      closing ? supabase.from("closing_events").select("*").eq("closing_id", closing).order("server_seq") : Promise.resolve({ data: [] }),
      closing ? supabase.from("commission_handovers").select("*").eq("closing_id", closing).order("at") : Promise.resolve({ data: [] }),
      supabase.from("staff").select("id, full_name, profile_id"),
      supabase.from("entries").select("id, kind, amount, staff_id, description, received_at, device_time, timestamp_flags").eq("outlet_id", outlet.id).eq("business_date", date).eq("late", true),
      supabase.from("food_payments").select("id, amount, paid_from, received_at").eq("outlet_id", outlet.id).eq("business_date", date).eq("late", true),
      closing ? supabase.from("late_entry_reviews").select("*").eq("closing_id", closing).order("server_seq") : Promise.resolve({ data: [] }),
      supabase.from("profiles").select("id, full_name"),
    ]);
  const revs = (revisions ?? []) as Revision[];
  const current = revs[revs.length - 1];
  const name = (id?: string | null) => (profiles ?? []).find((p) => p.id === id)?.full_name ?? "—";
  const staffName = (id?: string | null) => (staff ?? []).find((p) => p.id === id)?.full_name ?? "—";
  const editable = EDITABLE.includes(s.state);
  const canEdit = editable && can("closing.prepare");
  const lastDecision = new Map<string, { decision: string; reason: string | null }>();
  for (const r of reviews ?? []) lastDecision.set(r.entry_id, r);
  const openFlags = openReviewFlags(events ?? []);
  const needAcks = current ? [
    ...current.paytm_flags.filter((f) => f === "service_paytm_negative" || f === "service_paytm_exceeds_services"),
    ...(current.variance !== 0 ? ["variance"] : []),
    ...(s.warnings.includes("unassigned_entries") ? ["unassigned_entries"] : []),
  ] : [];
  const recipients = (staff ?? []).filter((x) => x.profile_id);

  return (
    <Page
      title={`Closing · ${fmtDate(date)}`}
      actions={<>
        <ButtonLink href={`/statement/${date}`}>Commission statement</ButtonLink>
        <ButtonLink href="/closing">All days</ButtonLink>
      </>}
    >
      <div className="flex flex-wrap items-center gap-3">
        <StateBadge state={s.state} />
        {current && <span className="text-sm text-slate-600">Revision {current.revision_no} · submitted by {name(current.submitted_by)} {fmtTime(current.submitted_at)}</span>}
        {s.needs_review && <span className="rounded-full bg-rose-100 px-2.5 py-0.5 text-xs font-semibold text-rose-900">Needs review</span>}
      </div>
      {s.state === "rejected" && <Notice tone="error">Rejected: {lastEvent(events ?? [], "rejected")?.reason}</Notice>}
      {s.state === "reopened" && <Notice tone="info">Reopened: {lastEvent(events ?? [], "reopened")?.reason}</Notice>}

      {!closing && (
        can("closing.prepare")
          ? <Card><ActionForm action={prepareClosing} submit="Start closing this day">
              <input type="hidden" name="outlet" value={outlet.id} /><input type="hidden" name="date" value={date} />
              <p className="text-sm text-slate-600">Figures below are live. Start the closing to enter Paytm and count the cash.</p>
            </ActionForm></Card>
          : <Notice>No closing has been started for this day.</Notice>
      )}

      <div className="grid gap-5 lg:grid-cols-2">
        <Card title="1. Sales">
          <Row label="Service sales (all payment types)" value={rupees(s.service_total)} />
          <Row label="Commission 10% (rounded down to ₹10)" value={`− ${rupees(s.commission_pool)}`} />
          <Row label="Product sales" value={rupees(s.product_total)} />
          <Row sub label="of which cash" value={rupees(s.product_cash)} />
          <Row sub label="of which Paytm" value={rupees(s.product_paytm)} />
          <Row label="Expenses from drawer" value={`− ${rupees(s.expenses_total)}`} />
          {s.expenses_outside_total > 0 && <Row sub label="Expenses paid outside the drawer (not deducted)" value={rupees(s.expenses_outside_total)} />}
          <Row label="Zakat" value={`− ${rupees(s.zakat_total)}`} />
          <Row label="Paytm total" value={s.paytm_entered ? `− ${rupees(s.paytm_total)}` : "not entered"} />
          <Row strong label="Expected physical cash (SRS formula)" value={rupees(s.net_cash)} />
          {s.paytm_entered && <p className="mt-2 text-xs text-slate-500">Paytm for services (derived): {rupees(s.service_paytm)}.
            {s.paytm_imported_count > 0 && <> Imported Paytm successes: {rupees(s.paytm_imported_success_total)} ({s.paytm_imported_count}).</>}</p>}
        </Card>

        <Card title="3. Food (paid from commission)">
          <Row label="Food cost today" value={rupees(s.food_cost)} />
          <Row sub label="funded by commission" value={rupees(s.food_commission_funded)} />
          {s.food_shop_funded > 0 && <Row sub label={s.blockers.includes("food_excess_unallocated") ? "extra paid by the shop (needs approval)" : "extra paid by the shop (approved)"} value={rupees(s.food_shop_funded)} />}
          <Row label="Paid from drawer today (today's food)" value={rupees(s.food_paid_drawer_today)} />
          <Row label="Paid from drawer today (earlier days' food)" value={rupees(s.food_paid_drawer_prior)} />
          <Row label="Today's food not paid from the drawer" value={rupees(s.food_not_paid_drawer)} />
          {s.blockers.includes("food_excess_unallocated") && (
            can("food_excess.allocate") && closing
              ? <div className="mt-3"><ActionForm action={allocateFoodExcess} submit="Shop pays the extra food" confirm="Record that the shop pays the food cost above the commission?">
                  <input type="hidden" name="closing" value={closing} />
                  <label className={labelCls} htmlFor="fx-reason">Reason</label>
                  <input id="fx-reason" name="reason" className={input} required />
                </ActionForm></div>
              : <Notice tone="warn">{BLOCKERS.food_excess_unallocated}</Notice>
          )}
        </Card>
      </div>

      <Card title="4. Commission statement" aside={<Link href={`/statement/${date}`} className="text-sm font-semibold text-brand-700 underline">Print</Link>}>
        <Table
          head={["Employee", "Service sales", "Exact 10%", "Allocated (₹10)", "Rounding"]}
          rows={s.allocations.map((a) => [a.staff_name, rupees(a.service_total), rupees(a.exact_share), rupees(a.allocated), signedRupees(a.rounding_adj)])}
          foot={["Total", rupees(s.service_total), rupees(s.allocations.reduce((x, a) => x + a.exact_share, 0)), rupees(s.commission_pool),
            signedRupees(s.allocations.reduce((x, a) => x + a.rounding_adj, 0))]}
          empty="No service sales."
        />
        <div className="mt-3 max-w-md">
          <Row label="Commission pool" value={rupees(s.commission_pool)} />
          <Row label="Food from commission" value={`− ${rupees(s.food_commission_funded)}`} />
          <Row strong label="Commission cash payable" value={rupees(s.remaining_payable)} />
        </div>
      </Card>

      <Card title="5. Commission cash handed to the head employee">
        {s.settlement && (
          <div className="mb-3 grid max-w-xl gap-x-6 sm:grid-cols-2">
            <Row label="Payable" value={rupees(s.settlement.allowed)} />
            <Row label="Status" value={SETTLEMENT[s.settlement.status] ?? s.settlement.status} />
            <Row label="From the drawer" value={rupees(s.settlement.drawer_net)} />
            <Row label="From outside the drawer" value={rupees(s.settlement.handed_outside_drawer)} />
            <Row label="Returned" value={rupees(s.settlement.returned)} />
            <Row label="Still owed to head" value={rupees(s.settlement.outstanding)} />
            {s.settlement.excess > 0 && <Row label="Over-handed" value={rupees(s.settlement.excess)} />}
            {s.settlement.accepted_overpayment > 0 && <Row label="Accepted overpayment (not cash)" value={rupees(s.settlement.accepted_overpayment)} />}
          </div>
        )}
        {(handovers ?? []).length > 0 && (
          <Table head={["Time", "Type", "Source", "Amount", "Who", "Reason"]} rows={(handovers ?? []).map((h) => [
            fmtTime(h.at), h.kind.replace("_", " "), h.source?.replace("_", " ") ?? "—", rupees(h.amount),
            h.kind === "handover" ? staffName(h.recipient_staff_id) : name(h.received_by ?? h.recorded_by), h.reason ?? "",
          ])} />
        )}
        {closing && can("commission.handover") && (
          <div className="mt-3 grid gap-4 md:grid-cols-2">
            <ActionForm action={recordHandover} submit="Record handover" confirm="Record this commission cash handover?">
              <input type="hidden" name="closing" value={closing} />
              <div><label className={labelCls} htmlFor="ho-to">Given to</label>
                <select id="ho-to" name="recipient" className={input} required>
                  {recipients.map((r) => <option key={r.id} value={r.id}>{r.full_name}</option>)}
                </select></div>
              <div><label className={labelCls} htmlFor="ho-amt">Amount (₹)</label><input id="ho-amt" name="amount" inputMode="numeric" className={input} required /></div>
              <div><label className={labelCls} htmlFor="ho-src">Taken from</label>
                <select id="ho-src" name="source" className={input} defaultValue={current ? "outside_drawer" : "drawer"}>
                  {!current && <option value="drawer">Cash drawer (before counting)</option>}
                  <option value="outside_drawer">Outside the drawer (e.g. from take-home)</option>
                </select></div>
            </ActionForm>
            <ActionForm action={recordReturn} submit="Record return">
              <input type="hidden" name="closing" value={closing} />
              <div><label className={labelCls} htmlFor="rt-amt">Amount returned by head (₹)</label><input id="rt-amt" name="amount" inputMode="numeric" className={input} required /></div>
              <div><label className={labelCls} htmlFor="rt-src">Returned to</label>
                <select id="rt-src" name="source" className={input}>
                  {!current && <option value="drawer">Cash drawer</option>}
                  <option value="outside_drawer">Management (outside the drawer)</option>
                </select></div>
              <div><label className={labelCls} htmlFor="rt-r">Reason</label><input id="rt-r" name="reason" className={input} required /></div>
            </ActionForm>
            {can("commission.adjust") && (s.settlement?.unresolved_excess ?? 0) > 0 && (
              <ActionForm action={acceptOverpayment} submit="Accept overpayment" confirm="Accept that the head keeps this extra commission? No cash moves.">
                <input type="hidden" name="closing" value={closing} />
                <div><label className={labelCls} htmlFor="ov-amt">Amount (₹, up to {rupees(s.settlement!.unresolved_excess)})</label><input id="ov-amt" name="amount" inputMode="numeric" className={input} required /></div>
                <div><label className={labelCls} htmlFor="ov-r">Reason</label><input id="ov-r" name="reason" className={input} required /></div>
              </ActionForm>
            )}
          </div>
        )}
      </Card>

      {closing && (
        <Card title="2 & 6. Paytm and cash count">
          {canEdit ? (
            <ActionForm action={updateDraft} submit="Save" resetOnSuccess={false}>
              <input type="hidden" name="closing" value={closing} />
              <div className="grid gap-3 sm:grid-cols-3">
                <div><label className={labelCls} htmlFor="pt">Paytm total today (₹)</label>
                  <input id="pt" name="paytm_total" inputMode="numeric" className={input} defaultValue={s.paytm_entered ? s.paytm_total / 100 : ""} placeholder="0 if none" /></div>
                <div><label className={labelCls} htmlFor="pu">of which UPI (optional)</label>
                  <input id="pu" name="paytm_upi" inputMode="numeric" className={input} defaultValue={s.paytm_upi != null ? s.paytm_upi / 100 : ""} /></div>
                <div><label className={labelCls} htmlFor="pc">of which card (optional)</label>
                  <input id="pc" name="paytm_card" inputMode="numeric" className={input} defaultValue={s.paytm_card != null ? s.paytm_card / 100 : ""} /></div>
              </div>
              <fieldset>
                <legend className={labelCls}>Count the drawer (number of notes/coins)</legend>
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-6">
                  {[...outlet.denominations].sort((a, b) => b - a).map((d) => (
                    <div key={d}>
                      <label className="text-sm font-medium" htmlFor={`den_${d}`}>₹{d / 100} ×</label>
                      <input id={`den_${d}`} name={`den_${d}`} inputMode="numeric" className={input} defaultValue={s.denominations[String(d)] ?? ""} />
                    </div>
                  ))}
                </div>
              </fieldset>
              <div className="grid gap-3 sm:grid-cols-2">
                <div><label className={labelCls} htmlFor="vr">Reason for any difference</label><input id="vr" name="variance_reason" className={input} defaultValue={s.variance_reason ?? ""} /></div>
                <div><label className={labelCls} htmlFor="th">Extra cash taken home by</label><input id="th" name="take_home_by" className={input} defaultValue={s.take_home_by ?? ""} /></div>
              </div>
            </ActionForm>
          ) : (
            <div className="max-w-md">
              <Row label="Paytm total" value={rupees(s.paytm_total)} />
              {Object.entries(s.denominations).sort((a, b) => Number(b[0]) - Number(a[0])).map(([d, q]) => (
                <Row key={d} sub label={`₹${Number(d) / 100} × ${q}`} value={rupees(Number(d) * q)} />
              ))}
            </div>
          )}
        </Card>
      )}

      <Card title="7. Cash check">
        <div className="grid gap-x-8 md:grid-cols-2">
          <div>
            <Row label="Float carried in" value={rupees(s.retained_float_carried)} />
            {s.pre_opening_funding !== 0 && <Row label="Added before opening" value={rupees(s.pre_opening_funding)} />}
            <Row label="Opening float" value={rupees(s.opening_float)} />
            {s.intraday_top_ups !== 0 && <Row label="Added during the day" value={rupees(s.intraday_top_ups)} />}
            <Row label="Cash sales (services + products − Paytm)" value={rupees(s.cash_sales)} />
            <Row label="Expenses and zakat" value={`− ${rupees(s.expenses_total + s.zakat_total)}`} />
            <Row label="Food paid from drawer" value={`− ${rupees(s.food_paid_drawer)}`} />
            <Row label="Commission handed from drawer" value={`− ${rupees(s.drawer_handover_total)}`} />
            <Row strong label="Expected in drawer" value={rupees(s.expected_drawer)} />
            <details className="mt-2 text-xs text-slate-600">
              <summary className="cursor-pointer">How this matches the SRS formula</summary>
              <p className="mt-1">Opening {rupees(s.opening_float)} + during-day {rupees(s.intraday_top_ups)} + SRS cash {rupees(s.net_cash)} + commission still in drawer {rupees(s.commission_retained)} + today&apos;s food not paid from drawer {rupees(s.food_not_paid_drawer)} − earlier food paid today {rupees(s.food_paid_drawer_prior)} − shop-paid food {rupees(s.food_shop_funded)} = {rupees(s.expected_drawer)}</p>
            </details>
          </div>
          <div>
            <Row label="Counted" value={rupees(s.counted_cash)} />
            <Row strong label="Difference" value={<span className={s.variance ? "text-rose-700" : "text-emerald-700"}>{signedRupees(s.variance)}</span>} />
            <Row label="Required float for next day" value={rupees(s.required_float)} />
            <Row label="Kept in drawer as float" value={rupees(s.retained_float)} />
            {s.float_shortfall > 0 && <Row label="Float shortfall (owner to top up)" value={<span className="text-rose-700">{rupees(s.float_shortfall)}</span>} />}
            <Row strong label="Cash taken home" value={rupees(s.take_home)} />
            {s.take_home > 0 && (s.commission_retained > 0 || s.food_not_paid_drawer > 0) && (
              <p className="text-xs text-slate-600">Of which: commission still owed to head {rupees(Math.max(0, s.commission_retained))}
                {s.food_not_paid_drawer > 0 && <>, food not yet paid {rupees(s.food_not_paid_drawer)}</>}.</p>
            )}
          </div>
        </div>
        {s.warnings.map((w) => <div key={w} className="mt-2"><Notice tone="warn">{WARNINGS[w] ?? w}</Notice></div>)}
        {editable && s.blockers.filter((b) => b !== "closing_frozen").length > 0 && (
          <div className="mt-3"><Notice tone="warn">
            <p className="font-semibold">Before submitting:</p>
            <ul className="ml-5 list-disc">{s.blockers.map((b) => <li key={b}>{BLOCKERS[b] ?? b}</li>)}</ul>
          </Notice></div>
        )}
        {closing && editable && can("closing.submit") && (
          <div className="mt-4">
            <ActionForm action={submitClosing} submit="Submit closing for approval"
              confirm={`Submit the closing for ${date}? Counted ${rupees(s.counted_cash)}, difference ${signedRupees(s.variance)}. After submitting, entries for this day are locked.`}>
              <input type="hidden" name="closing" value={closing} />
            </ActionForm>
          </div>
        )}
      </Card>

      {((lateEntries ?? []).length > 0 || (latePays ?? []).length > 0) && (
        <Card title="Late entries (arrived after this day was submitted)">
          <Table head={["Received", "Entry", "Amount", "Decision", ""]} rows={[
            ...(lateEntries ?? []).map((e) => ({ id: e.id, kind: "entry", label: `${KIND[e.kind]} ${e.kind === "service" ? staffName(e.staff_id) : e.description ?? ""}`, amount: e.amount, at: e.received_at })),
            ...(latePays ?? []).map((p) => ({ id: p.id, kind: "food_payment", label: `Food payment (${p.paid_from.replace("_", " ")})`, amount: p.amount, at: p.received_at })),
          ].map((e) => {
            const d = lastDecision.get(e.id);
            return [fmtTime(e.at), e.label, rupees(e.amount), d ? `${d.decision}${d.reason ? ` — ${d.reason}` : ""}` : <b key="u" className="text-rose-700">Needs decision</b>,
              can("late_entry.review") ? (
                <div key="f" className="flex flex-wrap gap-2">
                  <ActionForm action={reviewLateEntry} submit="Include" inline confirm="Include this entry? The day will be reopened for a new revision.">
                    <input type="hidden" name="kind" value={e.kind} /><input type="hidden" name="id" value={e.id} /><input type="hidden" name="decision" value="include" />
                    {!editable && <input name="reopen_reason" placeholder="Reopen reason" className={input} required aria-label="Reopen reason" />}
                  </ActionForm>
                  <ActionForm action={reviewLateEntry} submit="Exclude" inline>
                    <input type="hidden" name="kind" value={e.kind} /><input type="hidden" name="id" value={e.id} /><input type="hidden" name="decision" value="exclude" />
                    <input name="reason" placeholder="Why exclude?" className={input} required aria-label="Exclude reason" />
                  </ActionForm>
                </div>
              ) : null];
          })} />
        </Card>
      )}

      {current && (can("closing.approve") || can("closing.reopen")) && (
        <Card title="Management review">
          {openFlags.map((f) => (
            <div key={f.id} className="mb-3 rounded-lg border border-amber-300 bg-amber-50 p-3">
              <p className="text-sm font-semibold text-amber-900">Review flag: {f.payload?.flag === "opening_float_source_changed" ? "the previous day was corrected, so this day's opening float may be different" : f.payload?.flag}</p>
              {can("review.acknowledge") && (
                <ActionForm action={acknowledgeReview} submit="Acknowledge" inline>
                  <input type="hidden" name="closing" value={closing!} /><input type="hidden" name="flag" value={f.payload?.flag} />
                  <input name="reason" placeholder="Note" className={input} required aria-label="Acknowledgement note" />
                </ActionForm>
              )}
            </div>
          ))}
          <div className="grid gap-4 md:grid-cols-3">
            {s.state === "submitted" && can("closing.approve") && (
              <ActionForm action={approveClosing} submit="Approve" confirm={`Approve the closing for ${date}?${current.submitted_by === ctx.userId ? " You submitted it yourself; this is recorded." : ""}`}>
                <input type="hidden" name="revision" value={current.id} />
                {needAcks.map((a) => (
                  <label key={a} className="flex items-center gap-2 text-sm"><input type="checkbox" name="ack" value={a} className="h-5 w-5" required /> I have checked: {ACKS[a]}{a === "variance" ? ` (${signedRupees(current.variance)}: ${current.variance_reason})` : ""}</label>
                ))}
              </ActionForm>
            )}
            {s.state === "submitted" && can("closing.approve") && (
              <ActionForm action={rejectClosing} submit="Reject" danger>
                <input type="hidden" name="revision" value={current.id} />
                <label className={labelCls} htmlFor="rj">Reason</label><input id="rj" name="reason" className={input} required />
              </ActionForm>
            )}
            {(s.state === "submitted" || s.state === "approved") && can("closing.reopen") && (
              <ActionForm action={reopenClosing} submit="Reopen for correction" danger confirm="Reopen this day? A new revision will be needed; the current one is kept.">
                <input type="hidden" name="closing" value={closing!} />
                <label className={labelCls} htmlFor="ro">Reason</label><input id="ro" name="reason" className={input} required />
              </ActionForm>
            )}
          </div>
        </Card>
      )}

      {revs.length > 0 && (
        <Card title="Revisions (never changed after submission)">
          <Table
            head={["", ...revs.map((r) => `Rev ${r.revision_no}`)]}
            rows={([
              ["Submitted", (r: Revision) => `${name(r.submitted_by)} ${fmtTime(r.submitted_at)}`],
              ["Service sales", (r: Revision) => rupees(r.service_total)],
              ["Commission", (r: Revision) => rupees(r.commission_pool)],
              ["Products", (r: Revision) => rupees(r.product_total)],
              ["Paytm", (r: Revision) => rupees(r.paytm_total)],
              ["Expenses + zakat", (r: Revision) => rupees(r.expenses_total + r.zakat_total)],
              ["Food cost", (r: Revision) => rupees(r.food_cost)],
              ["Opening float", (r: Revision) => rupees(r.opening_float)],
              ["Expected", (r: Revision) => rupees(r.expected_drawer)],
              ["Counted", (r: Revision) => rupees(r.counted_cash)],
              ["Difference", (r: Revision) => signedRupees(r.variance)],
              ["Float kept / shortfall", (r: Revision) => `${rupees(r.retained_float)} / ${rupees(r.float_shortfall)}`],
              ["Taken home", (r: Revision) => `${rupees(r.take_home)} (${r.take_home_by ?? "—"})`],
            ] as [string, (r: Revision) => string][]).map(([label, f]) => [label, ...revs.map(f)])}
          />
        </Card>
      )}

      {(events ?? []).length > 0 && (
        <Card title="History">
          <ol className="space-y-1 text-sm">
            {(events ?? []).map((e) => (
              <li key={e.id}><span className="text-slate-500">{fmtTime(e.at)}</span> · <b>{e.type.replace(/_/g, " ")}</b> by {name(e.actor)}
                {e.reason ? ` — ${e.reason}` : ""}{e.payload?.self_approved ? " (self-approved)" : ""}</li>
            ))}
          </ol>
        </Card>
      )}
    </Page>
  );
}

type Ev = { id: string; type: string; server_seq: number; reason: string | null; payload: Record<string, unknown> | null };

function lastEvent(events: Ev[], type: string) {
  return [...events].reverse().find((e) => e.type === type);
}

function openReviewFlags(events: Ev[]) {
  return events.filter((e) => e.type === "review_flagged" && !events.some((a) => a.server_seq > e.server_seq &&
    (a.type === "reopened" || (a.type === "review_acknowledged" && a.payload?.flag === e.payload?.flag)))) as (Ev & { payload: { flag: string } })[];
}
