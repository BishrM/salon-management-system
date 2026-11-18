"use client";
import { useState, useTransition } from "react";
import { importRecovery } from "../../actions";
import { input } from "@/components/ui";

export function RecoveryImport() {
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  return (
    <div className="space-y-2">
      <label className="sr-only" htmlFor="rec">Pending entries file</label>
      <input id="rec" type="file" accept="application/json,.json" className={input} disabled={pending} onChange={(e) => {
        const f = e.target.files?.[0];
        if (!f) return;
        if (f.size > 5_000_000) return setMsg({ ok: false, text: "File is too large." });
        start(async () => {
          const r = await importRecovery(await f.text());
          setMsg(r.ok ? { ok: true, text: r.message ?? "Imported." } : { ok: false, text: r.error });
        });
      }} />
      {pending && <p className="text-sm">Importing…</p>}
      {msg && <p role={msg.ok ? "status" : "alert"} className={`text-sm ${msg.ok ? "text-emerald-700" : "text-rose-700"}`}>{msg.text}</p>}
    </div>
  );
}
