import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Notice, input, labelCls } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { setCutoff, setDenominations, setThresholds, setOutletDetails } from "../../actions";

export const metadata: Metadata = { title: "Outlet settings" };

export default async function Setup() {
  const ctx = await requirePermission("outlet.denominations");
  const { supabase, outlet, can } = ctx;
  const { data: o } = await supabase.from("outlets").select("*").eq("id", outlet.id).single();

  return (
    <Page title="Outlet settings">
      {can("outlet.details") && (
        <Card title="Outlet details">
          <ActionForm action={setOutletDetails} submit="Save details" resetOnSuccess={false}>
            <input type="hidden" name="outlet" value={outlet.id} />
            <div className="grid gap-3 sm:grid-cols-2">
              <div><label className={labelCls} htmlFor="nm">Name</label><input id="nm" name="name" defaultValue={o.name} className={input} required /></div>
              <div><label className={labelCls} htmlFor="gl">Go-live date</label><input id="gl" name="go_live" type="date" defaultValue={o.go_live_date ?? ""} className={input} /></div>
              <div className="sm:col-span-2"><label className={labelCls} htmlFor="ad">Address</label><input id="ad" name="address" defaultValue={o.address ?? ""} className={input} /></div>
              <div className="sm:col-span-2"><label className={labelCls} htmlFor="r1">Reason for change</label><input id="r1" name="reason" className={input} required /></div>
            </div>
          </ActionForm>
        </Card>
      )}

      <Card title="Business-day cutoff">
        <p className="mb-3 text-sm text-slate-600">
          Sales recorded after midnight but before this time count for the previous business day. Choose a time after the salon&apos;s
          latest possible closing. 04:00 is a common choice, but confirm it for this salon.
        </p>
        {!o.day_cutoff && <Notice tone="warn">Not set: the register is disabled until the owner sets it.</Notice>}
        {can("outlet.cutoff") ? (
          <ActionForm action={setCutoff} submit="Save cutoff" resetOnSuccess={false} confirm="Change the business-day cutoff? It affects how future entries are dated.">
            <input type="hidden" name="outlet" value={outlet.id} />
            <div className="grid gap-3 sm:grid-cols-2">
              <div><label className={labelCls} htmlFor="ct">Cutoff time</label><input id="ct" name="cutoff" type="time" defaultValue={o.day_cutoff?.slice(0, 5) ?? ""} className={input} required /></div>
              <div><label className={labelCls} htmlFor="r2">Reason</label><input id="r2" name="reason" className={input} required /></div>
            </div>
          </ActionForm>
        ) : <p className="text-sm">Current: {o.day_cutoff?.slice(0, 5) ?? "not set"} (owner only).</p>}
      </Card>

      <Card title="Cash denominations">
        <ActionForm action={setDenominations} submit="Save denominations" resetOnSuccess={false}>
          <input type="hidden" name="outlet" value={outlet.id} />
          <div className="grid gap-3 sm:grid-cols-2">
            <div><label className={labelCls} htmlFor="dn">Notes and coins in rupees, separated by commas</label>
              <input id="dn" name="list" defaultValue={(o.denominations as number[]).map((d) => d / 100).join(", ")} className={input} required /></div>
            <div><label className={labelCls} htmlFor="r3">Reason</label><input id="r3" name="reason" className={input} required /></div>
          </div>
        </ActionForm>
      </Card>

      {can("outlet.thresholds") && (
        <Card title="Offline dating thresholds (advanced)">
          <p className="mb-3 text-sm text-slate-600">How the system decides the date of entries made while the internet was down. Keep the defaults unless advised.</p>
          <ActionForm action={setThresholds} submit="Save thresholds" resetOnSuccess={false}>
            <input type="hidden" name="outlet" value={outlet.id} />
            <div className="grid gap-3 sm:grid-cols-4">
              <div><label className={labelCls} htmlFor="ow">Online window (seconds)</label><input id="ow" name="online" inputMode="numeric" defaultValue={o.online_window_s} className={input} required /></div>
              <div><label className={labelCls} htmlFor="cw">Clock warning (seconds)</label><input id="cw" name="clock" inputMode="numeric" defaultValue={o.clock_warn_s} className={input} required /></div>
              <div><label className={labelCls} htmlFor="gh">Long gap (hours)</label><input id="gh" name="gap" inputMode="numeric" defaultValue={o.gap_flag_h} className={input} required /></div>
              <div><label className={labelCls} htmlFor="r4">Reason</label><input id="r4" name="reason" className={input} required /></div>
            </div>
          </ActionForm>
        </Card>
      )}
    </Page>
  );
}
