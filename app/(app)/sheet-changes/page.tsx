import type { Metadata } from "next";
import { Fragment } from "react";
import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { Page, Card, Notice, fmtDate, fmtTime } from "@/components/ui";
import { describeChange, type SheetChange } from "@/lib/daily-sheet";

export const metadata: Metadata = { title: "Sheet changes" };

/** Owner inbox: every Register change to a day made after that day's Daily Sheet was opened (from the audit log). */
export default async function SheetChanges() {
  const { supabase } = await requirePermission("audit.read");
  const { data, error } = await supabase.rpc("sheet_changes", { p_limit: 200 });
  if (error) return <Page title="Sheet changes"><Notice tone="error">{error.message}</Notice></Page>;
  const items = (data ?? []) as SheetChange[];
  return (
    <Page title="Sheet changes">
      <p className="text-sm text-slate-600">Additions, corrections and removals in the Register after a day&apos;s Daily Sheet was opened, newest first.
        Each one is a separate audit record; nothing here can be edited.</p>
      {items.length === 0 && <Notice>No changes after a sheet was opened.</Notice>}
      <div className="space-y-3">
        {items.map((c) => {
          const d = describeChange(c);
          return (
            <Card key={c.id} title={d.title}>
              <dl className="grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[10rem_1fr]">
                <dt className="text-slate-500">Business date</dt><dd><Link href={`/closing/sheet?date=${c.business_date}`} className="font-semibold text-brand-700 underline">{fmtDate(c.business_date)}</Link>{c.late && " (late entry)"}</dd>
                <dt className="text-slate-500">Section</dt><dd>{d.section}</dd>
                <dt className="text-slate-500">{d.subjectLabel}</dt><dd className="font-semibold">{d.subject || "—"}</dd>
                <dt className="text-slate-500">Action</dt><dd>{d.action}</dd>
                {d.changes.map((x) => <Fragment key={x}><dt className="text-slate-500">Changed</dt><dd>{x}</dd></Fragment>)}
                {d.amountLine && <><dt className="text-slate-500">{d.amountLine.label}</dt><dd className="font-semibold tabular-nums">{d.amountLine.value}</dd></>}
                {d.totals.map((t) => <Fragment key={t.label}><dt className="text-slate-500">{t.label}</dt><dd className="tabular-nums">{t.before} → <b>{t.after}</b></dd></Fragment>)}
                <dt className="text-slate-500">By</dt><dd>{c.actor ?? "—"} · {fmtTime(c.at)}</dd>
                {c.reason && <><dt className="text-slate-500">Reason</dt><dd>{c.reason}</dd></>}
              </dl>
            </Card>
          );
        })}
      </div>
    </Page>
  );
}
