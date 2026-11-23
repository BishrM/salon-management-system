import { btnPrimary, input, labelCls } from "@/components/ui";

/** Business-date picker + "Open Closing Sheet". A plain GET form: opening reads data, it never starts a closing. */
export function OpenSheetForm({ today, date }: { today: string; date?: string }) {
  return (
    <form action="/closing/sheet" method="get" className="flex flex-wrap items-end gap-2 rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
      <div>
        <label htmlFor="sheet-date" className={labelCls}>Business date</label>
        <input id="sheet-date" name="date" type="date" defaultValue={date ?? today} max={today} className={input} required />
      </div>
      <button type="submit" className={`${btnPrimary} min-h-11`}>Open Closing Sheet</button>
    </form>
  );
}
