import Link from "next/link";
import { rupees } from "@/lib/money";
import { STATES } from "@/lib/labels";

// Small set of shared presentational pieces. Server-safe (no hooks).

export function Page({ title, actions, children }: { title: string; actions?: React.ReactNode; children: React.ReactNode }) {
  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-5 print-full">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
        {actions && <div className="no-print flex flex-wrap gap-2">{actions}</div>}
      </div>
      <div className="space-y-5">{children}</div>
    </div>
  );
}

export function Card({ title, children, className = "", aside }: { title?: string; children: React.ReactNode; className?: string; aside?: React.ReactNode }) {
  return (
    <section className={`rounded-xl border border-slate-200 bg-white p-4 shadow-sm ${className}`}>
      {(title || aside) && (
        <div className="mb-3 flex items-center justify-between gap-2">
          {title && <h2 className="text-base font-semibold text-slate-800">{title}</h2>}
          {aside}
        </div>
      )}
      {children}
    </section>
  );
}

export function Stat({ label, value, hint, tone = "" }: { label: string; value: number | null | undefined; hint?: string; tone?: string }) {
  return (
    <div className="rounded-lg border border-slate-200 bg-white p-3">
      <div className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`num mt-1 text-xl font-semibold ${tone}`}>{rupees(value)}</div>
      {hint && <div className="mt-0.5 text-xs text-slate-500">{hint}</div>}
    </div>
  );
}

export function StateBadge({ state }: { state: string }) {
  const s = STATES[state] ?? { label: state, tone: "bg-slate-100" };
  return <span className={`inline-flex rounded-full px-2.5 py-0.5 text-xs font-semibold ${s.tone}`}>{s.label}</span>;
}

export function Notice({ tone = "info", children }: { tone?: "info" | "warn" | "error" | "ok"; children: React.ReactNode }) {
  const c = {
    info: "border-sky-200 bg-sky-50 text-sky-900",
    warn: "border-amber-300 bg-amber-50 text-amber-900",
    error: "border-rose-300 bg-rose-50 text-rose-900",
    ok: "border-emerald-300 bg-emerald-50 text-emerald-900",
  }[tone];
  return <div role={tone === "error" ? "alert" : "status"} className={`rounded-lg border px-3 py-2 text-sm ${c}`}>{children}</div>;
}

export function Row({ label, value, strong, sub }: { label: React.ReactNode; value: React.ReactNode; strong?: boolean; sub?: boolean }) {
  return (
    <div className={`flex items-baseline justify-between gap-4 py-1 ${strong ? "border-t border-slate-200 pt-2 font-semibold" : ""} ${sub ? "pl-4 text-sm text-slate-600" : ""}`}>
      <span>{label}</span>
      <span className="num text-right">{value}</span>
    </div>
  );
}

export function ButtonLink({ href, children, variant = "secondary" }: { href: string; children: React.ReactNode; variant?: "primary" | "secondary" }) {
  return (
    <Link href={href} className={variant === "primary" ? btnPrimary : btnSecondary}>
      {children}
    </Link>
  );
}

export const btnPrimary =
  "inline-flex min-h-11 items-center justify-center rounded-lg bg-brand-700 px-4 text-sm font-semibold text-white hover:bg-brand-800 disabled:cursor-not-allowed disabled:opacity-50";
export const btnSecondary =
  "inline-flex min-h-11 items-center justify-center rounded-lg border border-slate-300 bg-white px-4 text-sm font-semibold text-slate-800 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50";
export const btnDanger =
  "inline-flex min-h-11 items-center justify-center rounded-lg bg-rose-700 px-4 text-sm font-semibold text-white hover:bg-rose-800 disabled:opacity-50";
export const input =
  "min-h-11 w-full rounded-lg border border-slate-300 bg-white px-3 text-base text-slate-900 placeholder:text-slate-400 focus:border-brand-600";
export const labelCls = "mb-1 block text-sm font-medium text-slate-700";

export function Table({ head, rows, foot, empty = "Nothing yet." }: { head: React.ReactNode[]; rows: React.ReactNode[][]; foot?: React.ReactNode[]; empty?: string }) {
  if (!rows.length) return <p className="text-sm text-slate-500">{empty}</p>;
  return (
    <div className="-mx-4 overflow-x-auto px-4">
      <table className="w-full min-w-max text-sm">
        <thead>
          <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
            {head.map((h, i) => <th key={i} className="py-2 pr-4 font-medium">{h}</th>)}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className="border-b border-slate-100 last:border-0">
              {r.map((c, j) => <td key={j} className="num py-2 pr-4 align-top">{c}</td>)}
            </tr>
          ))}
        </tbody>
        {foot && (
          <tfoot>
            <tr className="border-t-2 border-slate-300 font-semibold">
              {foot.map((c, j) => <td key={j} className="num py-2 pr-4">{c}</td>)}
            </tr>
          </tfoot>
        )}
      </table>
    </div>
  );
}

export function fmtTime(iso: string | null | undefined, tz = "Asia/Kolkata") {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-IN", { timeZone: tz, hour: "2-digit", minute: "2-digit", day: "2-digit", month: "short" });
}

export function fmtDate(d: string) {
  return new Date(d + "T00:00:00Z").toLocaleDateString("en-IN", { timeZone: "UTC", weekday: "short", day: "numeric", month: "short", year: "numeric" });
}
