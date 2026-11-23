import type { Metadata } from "next";
import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { Page, Notice, StateBadge, ButtonLink } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { LiveRefresh } from "@/components/live-refresh";
import { rupees, signedRupees } from "@/lib/money";
import type { DaySummary } from "@/lib/types";
import { buildSheet, type SheetEntry } from "@/lib/daily-sheet";
import { updateDraft } from "../../actions";
import { OpenSheetForm } from "./open-form";

export const metadata: Metadata = { title: "Daily Sheet" };

const EDITABLE = ["draft", "rejected", "reopened"];
// Spreadsheet cell: continuous 1px grid lines (border-collapse), touch-friendly height.
const cell = "h-10 border border-slate-900 px-2 tabular-nums whitespace-nowrap";
const td = `${cell} text-right`;
const tdl = `${cell} text-left`;
const th = "h-10 border border-slate-900 px-2 text-center font-bold whitespace-nowrap";
const cellInput = "h-9 w-16 rounded border border-slate-400 px-1 text-right tabular-nums";

type RightRow =
  | { t: "head"; text: string }
  | { t: "line"; a: React.ReactNode; b?: React.ReactNode; c: React.ReactNode; edited?: boolean; muted?: boolean; strong?: boolean }
  | { t: "blank" };

export default async function DailySheet({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
  const ctx = await requirePermission("outlet.read");
  const { supabase, outlet, today, can } = ctx;
  const date = (await searchParams).date ?? today ?? "";
  if (!today) return <Page title="Daily Sheet"><Notice tone="warn">Setup is not finished (business-day cutoff).</Notice></Page>;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date > today)
    return <Page title="Daily Sheet"><OpenSheetForm today={today} date={today} /><Notice tone="error">Choose a business date up to {today}.</Notice></Page>;

  // Marks the sheet as opened (later Register changes to this day are listed for the owner). Creates no closing.
  const { error: openErr } = await supabase.rpc("open_daily_sheet", { p_outlet: outlet.id, p_date: date });
  const { data: sum, error } = await supabase.rpc("day_summary", { p_outlet: outlet.id, p_date: date });
  if (error || openErr) return <Page title="Daily Sheet"><Notice tone="error">{(error ?? openErr)!.message}</Notice></Page>;
  const s = sum as DaySummary;
  const ids = (s.entries_snapshot ?? []).map((x) => x.id);
  const [{ data: rows }, { data: staff }] = await Promise.all([
    ids.length
      ? supabase.from("entries").select("id, kind, amount, staff_id, product_name, quantity, unit_price, payment_method, split_cash, split_paytm, tip_cash, tip_paytm, expense_source, meal, description, version, status, server_seq").in("id", ids)
      : Promise.resolve({ data: [] }),
    supabase.from("staff").select("id, full_name"),
  ]);
  const names = new Map((staff ?? []).map((p) => [p.id, p.full_name as string]));
  const sheet = buildSheet((rows ?? []) as SheetEntry[], (id) => names.get(id) ?? "—", s, outlet.denominations);
  const editable = !!s.closing_id && EDITABLE.includes(s.state) && can("closing.prepare");
  const day = new Date(`${date}T00:00:00Z`).toLocaleDateString("en-IN", { weekday: "long", timeZone: "UTC" });
  const dateText = new Date(`${date}T00:00:00Z`).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric", timeZone: "UTC" });

  const pad = (list: RightRow[], min: number) => [...list, ...Array.from({ length: Math.max(0, min - list.length) }, () => ({ t: "blank" as const }))];
  const right: RightRow[] = [
    ...pad(sheet.expenses.map((e) => ({ t: "line" as const, a: e.label, b: e.detail, c: rupees(e.amount), edited: e.edited })), 4),
    { t: "head", text: "PRODUCT SALE" },
    ...pad(sheet.products.map((p) => ({ t: "line" as const, a: p.label, b: p.detail, c: rupees(p.amount), edited: p.edited })), 4),
    { t: "head", text: "ROLLING" },
    ...sheet.rolling.map((r) => ({
      t: "line" as const, a: `• ${r.den / 100} ×`,
      b: editable
        ? <input name={`den_${r.den}`} inputMode="numeric" defaultValue={r.count || ""} aria-label={`Number of ₹${r.den / 100} notes`} className={cellInput} />
        : r.count || "",
      c: r.total ? rupees(r.total) : "",
    })),
    { t: "line", a: "TOTAL :", c: rupees(sheet.rollingTotal), strong: true },
    { t: "line", a: "Opening float", b: s.intraday_top_ups ? `+ ${rupees(s.intraday_top_ups)} added today` : "", c: rupees(s.opening_float), muted: true },
    { t: "line", a: "Expected in drawer", c: rupees(s.expected_drawer), muted: true },
    { t: "line", a: "Difference (counted − expected)", c: s.closing_id ? signedRupees(s.variance) : "—", muted: true },
    { t: "line", a: "Kept as float / taken home", c: `${rupees(s.retained_float)} / ${rupees(s.take_home)}`, muted: true },
    { t: "head", text: "ACCOUNTS" },
    ...sheet.accounts.map((a) => ({
      t: "line" as const, a: <b>{a.label}</b>, b: <span className="text-xs text-slate-500">{a.note}</span>, strong: true,
      c: a.label === "TOTAL PAYTM AMOUNT" && editable
        ? <input name="paytm_total" inputMode="numeric" required defaultValue={s.paytm_entered ? s.paytm_total / 100 : ""} placeholder="₹"
            aria-label="What is the total Paytm / UPI / Card amount received today?" className={`${cellInput} w-24`} />
        : a.amount == null ? <span className="text-rose-700">not entered</span> : rupees(a.amount),
    })),
    { t: "line", a: "Paytm recorded in the Register", b: "services + products + tips", c: rupees(s.paytm_recorded_total), muted: true },
    ...(s.paytm_difference != null ? [{ t: "line" as const, a: "Paytm difference", b: "statement − Register",
      c: <span className={s.paytm_difference ? "font-bold text-rose-700" : ""}>{signedRupees(s.paytm_difference)}</span>, muted: true }] : []),
    ...(s.tips_cash || s.tips_paytm ? [{ t: "line" as const, a: "Tips (not sales)", b: "cash / UPI", c: `${rupees(s.tips_cash)} / ${rupees(s.tips_paytm)}`, muted: true }] : []),
  ];

  const cols = sheet.columns.length ? sheet.columns : [{ no: 1, staffId: "", name: "", cells: [], total: 0 }];
  const bodyRows = Math.max(sheet.maxCells + 2, right.length);

  const grid = (
    <div className="overflow-x-auto rounded border border-slate-300 bg-white p-3 sm:p-5" data-testid="daily-sheet">
      <div className="min-w-max text-sm text-slate-900 lg:min-w-0">
        {/* Top: DATE / DAY left, title centred, LUNCH / DINNER in the far-right corner. */}
        <div className="mb-3 grid grid-cols-[1fr_auto_1fr] items-start gap-4">
          <div className="font-bold leading-7">
            <div>DATE : <span className="font-normal">{dateText}</span></div>
            <div>DAY : <span className="font-normal">{day}</span></div>
          </div>
          <h2 className="border-b-4 border-slate-900 px-2 text-2xl font-extrabold tracking-wide sm:text-3xl">DAILY SHEET</h2>
          <div className="justify-self-end text-right font-bold leading-7">
            <div>LUNCH : <span className="font-normal tabular-nums">{rupees(sheet.lunch)}</span></div>
            <div>DINNER : <span className="font-normal tabular-nums">{rupees(sheet.dinner)}</span></div>
          </div>
        </div>

        <table className="w-full border-collapse border-2 border-slate-900">
          <colgroup>
            <col className="w-16" />
            {cols.map((c) => <col key={c.no} />)}
            <col className="w-56" /><col className="w-44" /><col className="w-28" />
          </colgroup>
          <thead>
            <tr>
              <th className={th}>Sl. No.</th>
              {cols.map((c) => <th key={c.no} className={`${th} min-w-24`}>{c.no}</th>)}
              <th className={th} colSpan={3} rowSpan={2}>EXPENSES</th>
            </tr>
            <tr>
              <th className={th}>Employee</th>
              {cols.map((c) => <th key={c.no} className={`${th} font-semibold`}>{c.name}</th>)}
            </tr>
          </thead>
          <tbody>
            {Array.from({ length: bodyRows }, (_, i) => {
              const r = right[i] ?? { t: "blank" as const };
              const isTotal = i === bodyRows - 2;
              const isAll = i === bodyRows - 1;
              return (
                <tr key={i}>
                  <td className={`${cell} text-center font-semibold`}>{isTotal ? "TOTAL" : isAll ? "ALL" : i + 1}</td>
                  {isAll
                    ? <td className={`${td} font-bold`} colSpan={cols.length}>Services {rupees(sheet.serviceTotal)}</td>
                    : cols.map((c) => {
                        if (isTotal) return <td key={c.no} className={`${td} font-bold`}>{c.cells.length ? rupees(c.total) : ""}</td>;
                        const cell = c.cells[i];
                        return (
                          <td key={c.no} className={td} title={cell ? payTitle(cell) : undefined}>
                            {cell && <>
                              {rupees(cell.amount)}
                              {cell.method === "split" && <sup className="ml-0.5 text-[10px] font-semibold text-sky-800">S</sup>}
                              {cell.edited && <span className="ml-1 rounded bg-violet-100 px-1 text-[10px] font-semibold text-violet-900">EDITED</span>}
                            </>}
                          </td>
                        );
                      })}
                  {r.t === "head" && <td className={`${th} bg-slate-50`} colSpan={3}>{r.text}</td>}
                  {r.t === "blank" && <><td className={tdl} /><td className={tdl} /><td className={td} /></>}
                  {r.t === "line" && <>
                    <td className={`${tdl} ${r.muted ? "text-slate-600" : ""} ${r.strong ? "font-semibold" : ""}`}>
                      {r.a}{r.edited && <span className="ml-1 rounded bg-violet-100 px-1 text-[10px] font-semibold text-violet-900">EDITED</span>}
                    </td>
                    <td className={`${tdl} ${r.muted ? "text-slate-600" : ""}`}>{r.b}</td>
                    <td className={`${td} ${r.strong ? "font-bold" : ""} ${r.muted ? "text-slate-600" : ""}`}>{r.c}</td>
                  </>}
                </tr>
              );
            })}
          </tbody>
        </table>
        <p className="mt-2 text-xs text-slate-600">S = split payment (cash + UPI / Paytm / Card). Hover or long-press a cell for its payment. Tips are not sales and are not in the employee columns.</p>
      </div>
    </div>
  );

  return (
    <Page title="Daily Sheet" actions={<>
      <ButtonLink href={`/closing/${date}`}>Closing for this day</ButtonLink>
      <ButtonLink href="/register">Register</ButtonLink>
    </>}>
      <LiveRefresh outletId={outlet.id} />
      <OpenSheetForm today={today} date={date} />
      <div className="flex flex-wrap items-center gap-3 text-sm">
        {s.closing_id ? <StateBadge state={s.state} /> : <span className="text-slate-600">No closing started for this day.</span>}
        <span className="text-slate-600">Figures come live from the Register. To add, correct or remove an entry, use the <Link href="/register" className="font-semibold text-brand-700 underline">Register</Link>; the owner is told about every change.</span>
      </div>
      {!s.closing_id && can("closing.prepare") && (
        <Notice>To count the rolling cash and enter the Paytm total, start the closing on the <Link href={`/closing/${date}`} className="font-semibold underline">closing page</Link>.</Notice>
      )}
      {editable ? (
        <ActionForm action={updateDraft} submit="Save rolling count and Paytm total" resetOnSuccess={false}>
          <input type="hidden" name="closing" value={s.closing_id!} />
          <input type="hidden" name="paytm_upi" value={s.paytm_upi != null ? s.paytm_upi / 100 : ""} />
          <input type="hidden" name="paytm_card" value={s.paytm_card != null ? s.paytm_card / 100 : ""} />
          <input type="hidden" name="variance_reason" value={s.variance_reason ?? ""} />
          <input type="hidden" name="take_home_by" value={s.take_home_by ?? ""} />
          {grid}
        </ActionForm>
      ) : grid}
    </Page>
  );
}

function payTitle(c: { method: string | null; split: [number, number] | null; tip: number }) {
  const base = c.split ? `Cash ${rupees(c.split[0])} + UPI / Paytm / Card ${rupees(c.split[1])}`
    : c.method === "paytm" ? "UPI / Paytm / Card" : c.method === "cash" ? "Cash" : "Payment not recorded";
  return c.tip ? `${base} · tip ${rupees(c.tip)} (not a sale)` : base;
}
