"use client";
import { useMemo, useState, useTransition } from "react";
import { parseCsv, amountToPaise, normaliseStatus, normaliseMethod, toIsoIST, PAYTM_FIELDS as FIELDS, guessPaytmColumns } from "@/lib/csv";
import { importPaytm } from "../../actions";
import { btnPrimary, input, labelCls } from "@/components/ui";
import { rupees } from "@/lib/money";

export function PaytmImport({ outletId }: { outletId: string }) {
  const [name, setName] = useState("");
  const [rows, setRows] = useState<string[][]>([]);
  const [map, setMap] = useState<Record<string, number>>({});
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const header = rows[0] ?? [];

  const parsed = useMemo(() => {
    if (!rows.length || FIELDS.some((f) => f.required && map[f.key] == null)) return null;
    const ok: { txn_ref: string; txn_time: string; amount: number; status: "success" | "pending" | "failed" | "refunded"; method: "upi" | "card" | "unknown" }[] = [];
    const bad: number[] = [];
    rows.slice(1).forEach((r, i) => {
      const t = toIsoIST(r[map.time] ?? "");
      const a = amountToPaise(r[map.amount] ?? "");
      const s = normaliseStatus(r[map.status] ?? "");
      const ref = (r[map.ref] ?? "").trim();
      if (!t || !a || !s || !ref) bad.push(i + 2);
      else ok.push({ txn_ref: ref, txn_time: t, amount: a, status: s, method: map.method != null ? normaliseMethod(r[map.method] ?? "") : "unknown" });
    });
    return { ok, bad };
  }, [rows, map]);

  return (
    <div className="space-y-3">
      <div><label className={labelCls} htmlFor="csv">CSV file</label>
        <input id="csv" type="file" accept=".csv,text/csv" className={input} onChange={async (e) => {
          const f = e.target.files?.[0];
          if (!f) return;
          if (f.size > 5_000_000) return setMsg({ ok: false, text: "File is too large." });
          const r = parseCsv(await f.text());
          setName(f.name);
          setRows(r);
          setMsg(null);
          setMap(guessPaytmColumns(r[0] ?? []));
        }} /></div>
      {header.length > 0 && (
        <div className="grid gap-3 sm:grid-cols-3">
          {FIELDS.map((f) => (
            <div key={f.key}><label className={labelCls} htmlFor={`m-${f.key}`}>{f.label}</label>
              <select id={`m-${f.key}`} className={input} value={map[f.key] ?? ""} onChange={(e) => setMap({ ...map, [f.key]: e.target.value === "" ? (undefined as unknown as number) : Number(e.target.value) })}>
                <option value="">—</option>
                {header.map((h, i) => <option key={i} value={i}>{h || `Column ${i + 1}`}</option>)}
              </select></div>
          ))}
        </div>
      )}
      {parsed && (
        <p className="text-sm">
          {parsed.ok.length} transaction(s) ready · successful total {rupees(parsed.ok.filter((r) => r.status === "success").reduce((a, r) => a + r.amount, 0))}
          {parsed.bad.length > 0 && <span className="text-rose-700"> · {parsed.bad.length} row(s) could not be read (rows {parsed.bad.slice(0, 10).join(", ")}{parsed.bad.length > 10 ? "…" : ""})</span>}
        </p>
      )}
      <button className={btnPrimary} disabled={!parsed?.ok.length || pending} onClick={() => start(async () => {
        const r = await importPaytm(outletId, parsed!.ok, name);
        setMsg(r.ok ? { ok: true, text: r.message ?? "Imported." } : { ok: false, text: r.error });
      })}>{pending ? "Importing…" : "Import"}</button>
      {msg && <p role={msg.ok ? "status" : "alert"} className={`text-sm ${msg.ok ? "text-emerald-700" : "text-rose-700"}`}>{msg.text}</p>}
    </div>
  );
}
