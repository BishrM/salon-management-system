import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, input, labelCls, fmtDate } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { createStaff, updateStaff, assignStaff, endAssignment } from "../actions";

export const metadata: Metadata = { title: "Employees" };

export default async function StaffPage() {
  const ctx = await requirePermission("staff.manage");
  const { supabase, outlet, today, outlets } = ctx;
  const { data: staff } = await supabase.from("staff")
    .select("id, full_name, active, inactive_from, staff_assignments(id, outlet_id, start_date, end_date, end_reason, is_temporary)")
    .order("full_name");
  const outletName = (id: string) => outlets.find((o) => o.id === id)?.name ?? "another outlet";
  // Active first; deactivated employees stay listed (history, reactivation) but are never deleted.
  const ordered = [...(staff ?? [])].sort((a, b) => Number(b.active) - Number(a.active));

  return (
    <Page title="Employees">
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
                <ActionForm action={updateStaff} submit="Save details" className="flex h-full flex-col [&>*:last-child]:mt-auto">
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
            </details>
          </Card>
        );
      })}
    </Page>
  );
}
