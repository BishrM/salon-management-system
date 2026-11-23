import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, input, labelCls, fmtDate } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { LiveRefresh } from "@/components/live-refresh";
import { createStaff, updateStaff, assignStaff, endAssignment, deleteStaffPermanently } from "../actions";

export const metadata: Metadata = { title: "Employees" };

export default async function StaffPage() {
  const ctx = await requirePermission("staff.manage");
  const { supabase, outlet, today, outlets } = ctx;
  const isOwner = ctx.can("users.manage");   // owner-only permission; the database re-checks every delete
  const [{ data: staff }, { data: blockerRows }] = await Promise.all([
    supabase.from("staff")
      .select("id, full_name, active, inactive_from, staff_assignments(id, outlet_id, start_date, end_date, end_reason, is_temporary)")
      .order("full_name"),
    isOwner ? supabase.rpc("staff_delete_blockers") : Promise.resolve({ data: null }),
  ]);
  // Only employees the Owner owns at every outlet they worked at; empty list = may be deleted permanently.
  const blockers = new Map(((blockerRows ?? []) as { staff_id: string; blockers: string[] }[]).map((r) => [r.staff_id, r.blockers]));
  const outletName = (id: string) => outlets.find((o) => o.id === id)?.name ?? "another outlet";
  // Active first; deactivated employees stay listed (history, reactivation). Only an employee with no history
  // at all can be deleted permanently, by an Owner.
  const ordered = [...(staff ?? [])].sort((a, b) => Number(b.active) - Number(a.active));

  return (
    <Page title="Employees">
      <LiveRefresh outletId={outlet.id} />
      <Card title="Add employee">
        <ActionForm action={createStaff} submit="Add employee">
          <input type="hidden" name="outlet" value={outlet.id} />
          <p className="text-sm text-slate-600">Employees are records for sales, commission and closings. They do not get logins.</p>
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className={labelCls} htmlFor="n">Name</label><input id="n" name="name" className={input} required maxLength={120} /></div>
            <div><label className={labelCls} htmlFor="sd">Starts working here on</label><input id="sd" name="start" type="date" defaultValue={today ?? undefined} className={input} required /></div>
          </div>
        </ActionForm>
      </Card>

      {ordered.map((s) => {
        const asg = (s.staff_assignments as { id: string; outlet_id: string; start_date: string; end_date: string | null; end_reason: string | null; is_temporary: boolean }[])
          .sort((a, b) => b.start_date.localeCompare(a.start_date));
        return (
          <Card key={s.id} title={`${s.full_name}${s.active ? "" : ` (deactivated${s.inactive_from ? ` from ${fmtDate(s.inactive_from)}` : ""})`}`}>
            <ul className="mb-3 space-y-1 text-sm">
              {asg.map((a) => (
                <li key={a.id} className="flex flex-wrap items-center gap-2">
                  <span className={a.end_date && today && a.end_date < today ? "text-slate-500" : "font-medium"}>
                    {outletName(a.outlet_id)} · {fmtDate(a.start_date)} → {a.end_date ? fmtDate(a.end_date) : "now"}{a.is_temporary ? " · temporary" : ""}
                    {a.end_reason && !a.is_temporary ? ` (${a.end_reason})` : ""}
                  </span>
                  {!a.end_date && (
                    <ActionForm action={endAssignment} submit="End" inline confirm={`End ${s.full_name}'s assignment? History is kept.`}>
                      <input type="hidden" name="assignment" value={a.id} />
                      <input name="end" type="date" defaultValue={today ?? undefined} className={input} required aria-label="Last working day" />
                      <input name="reason" placeholder="Reason" className={input} required aria-label="Reason" />
                    </ActionForm>
                  )}
                </li>
              ))}
            </ul>
            <details>
              <summary className="cursor-pointer text-sm font-semibold text-brand-700">Change details or assignment</summary>
              <div className="mt-3 grid gap-4 md:grid-cols-2">
                {/* Remount when another session changes this employee (live refresh), so the name and status fields
                    never hold old values that a later save would write back. */}
                <ActionForm key={`${s.full_name}|${s.active}|${s.inactive_from}`} action={updateStaff} submit="Save details"
                  className="flex h-full flex-col [&>*:last-child]:mt-auto">
                  <input type="hidden" name="staff" value={s.id} />
                  <div><label className={labelCls} htmlFor={`nm-${s.id}`}>Name</label><input id={`nm-${s.id}`} name="name" defaultValue={s.full_name} className={input} required /></div>
                  <div><label className={labelCls} htmlFor={`ac-${s.id}`}>Status</label>
                    <select id={`ac-${s.id}`} name="active" defaultValue={String(s.active)} className={input}>
                      <option value="true">Active</option><option value="false">Deactivated (left — history is kept)</option>
                    </select></div>
                  <div><label className={labelCls} htmlFor={`rs-${s.id}`}>Reason</label><input id={`rs-${s.id}`} name="reason" className={input} required /></div>
                </ActionForm>
                <ActionForm action={assignStaff} submit="Assign" className="flex h-full flex-col [&>*:last-child]:mt-auto">
                  <input type="hidden" name="staff" value={s.id} />
                  <div><label className={labelCls} htmlFor={`o-${s.id}`}>Outlet</label>
                    <select id={`o-${s.id}`} name="outlet" className={input}>{outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</select></div>
                  <div className="grid grid-cols-2 gap-2">
                    <div className="flex flex-col justify-end"><label className={labelCls} htmlFor={`as-${s.id}`}>From</label><input id={`as-${s.id}`} name="start" type="date" className={input} required /></div>
                    <div className="flex flex-col justify-end"><label className={labelCls} htmlFor={`ae-${s.id}`}>Until (temporary)</label><input id={`ae-${s.id}`} name="end" type="date" className={input} /></div>
                  </div>
                  <div><label className={labelCls} htmlFor={`ar-${s.id}`}>Reason</label><input id={`ar-${s.id}`} name="reason" className={input} required /></div>
                  <label className="flex min-h-11 items-center gap-2 text-sm"><input type="checkbox" name="temporary" value="1" className="h-5 w-5" /> Temporary (visiting another outlet)</label>
                </ActionForm>
              </div>
              {blockers.has(s.id) && (
                <div className="mt-4 border-t border-slate-200 pt-3">
                  <p className="text-sm font-semibold">Delete permanently</p>
                  {blockers.get(s.id)!.length === 0 ? (
                    <>
                      <p className="mb-2 text-sm text-slate-600">
                        {s.full_name} has no sales, commission, closings or other history, so the record can be removed
                        completely. This is different from deactivating and cannot be undone.
                      </p>
                      <ActionForm action={deleteStaffPermanently} submit="Delete permanently" danger resetOnSuccess={false}
                        confirm={`Permanently delete ${s.full_name} from ${[...new Set(asg.map((a) => outletName(a.outlet_id)))].join(", ")}?\n\nThis cannot be undone. The audit log keeps a record of the deletion.`}>
                        <input type="hidden" name="outlet" value={asg[0]?.outlet_id ?? ""} />
                        <input type="hidden" name="staff" value={s.id} />
                      </ActionForm>
                    </>
                  ) : (
                    <>
                      <p className="mb-2 text-sm text-slate-600">
                        {s.full_name} cannot be deleted permanently because their history must be kept: {blockers.get(s.id)!.join(", ")}.
                        {s.active ? " Deactivate them instead: they stop appearing for new sales and all history stays." : " They are already deactivated, which keeps all history."}
                      </p>
                      {s.active && (
                        <ActionForm action={updateStaff} submit="Deactivate instead" inline>
                          <input type="hidden" name="staff" value={s.id} />
                          <input type="hidden" name="name" value={s.full_name} />
                          <input type="hidden" name="active" value="false" />
                          <input name="reason" placeholder="Reason" className={input} required aria-label={`Reason for deactivating ${s.full_name}`} />
                        </ActionForm>
                      )}
                    </>
                  )}
                </div>
              )}
            </details>
          </Card>
        );
      })}
    </Page>
  );
}
