"use client";
import { useState } from "react";
import { ActionForm } from "@/components/action-form";
import { input, labelCls } from "@/components/ui";
import { establishInitialFloat } from "../../actions";
import { rupees } from "@/lib/money";

/** G2/J4: one owner action — count by denomination, see the total, re-type it to confirm. */
export function InitialFloatForm({ outletId, today, denominations }: { outletId: string; today: string; denominations: number[] }) {
  const [counts, setCounts] = useState<Record<number, string>>({});
  const total = denominations.reduce((a, d) => a + d * (Number(counts[d]) || 0), 0);
  return (
    <ActionForm action={establishInitialFloat} submit="Confirm starting float" confirm={`Record the starting float of ${rupees(total)}? This can only be done once.`}>
      <input type="hidden" name="outlet" value={outletId} />
      <div><label className={labelCls} htmlFor="ie">First business day</label><input id="ie" name="effective" type="date" defaultValue={today} className={input} required /></div>
      <fieldset>
        <legend className={labelCls}>Count the float</legend>
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-6">
          {[...denominations].sort((a, b) => b - a).map((d) => (
            <div key={d}>
              <label className="text-sm" htmlFor={`if-${d}`}>₹{d / 100} ×</label>
              <input id={`if-${d}`} name={`den_${d}`} inputMode="numeric" className={input} value={counts[d] ?? ""} onChange={(e) => setCounts({ ...counts, [d]: e.target.value })} />
            </div>
          ))}
        </div>
      </fieldset>
      <p className="num text-lg font-semibold">Counted total: {rupees(total)}</p>
      <div><label className={labelCls} htmlFor="rt">Type the total again (₹) to confirm</label><input id="rt" name="retyped" inputMode="numeric" className={input} required /></div>
      <p className="text-xs text-slate-500">Recorded as counted, entered and self-confirmed by you in one action.</p>
    </ActionForm>
  );
}
