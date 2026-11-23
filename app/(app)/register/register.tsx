"use client";
import { useCallback, useEffect, useMemo, useState } from "react";
import { enqueue, listOps, removeOps, exportPending, getMeta, type OutboxRow } from "@/lib/offline/outbox";
import { withdrawSyncOp, withdrawBlockedOp } from "@/app/(app)/actions";
import { deviceLabel } from "@/lib/offline/sync";
import { commissionPool, servicePayment, type PayMethod } from "@/lib/accounting";
import { rupees, parseRupees, parseRupeesAllowZero } from "@/lib/money";
import { KIND, FLAGS, PAID_BY, isEdited } from "@/lib/labels";
import { btnPrimary, btnSecondary, input, labelCls } from "@/components/ui";

export type RegisterEntry = {
  id: string; kind: string; amount: number; staff_id: string | null; product_name: string | null; quantity: number | null;
  unit_price: number | null; payment_method: string | null; description: string | null; meal: string | null;
  split_cash: number | null; split_paytm: number | null; tip_cash: number; tip_paytm: number;
  expense_source: string | null; status: string; version: number; received_at: string; late: boolean;
  timestamp_flags: string[]; business_date: string | null;
};
type Staff = { id: string; name: string; temporary: boolean };
type Product = { id: string; name: string; price: number };
type UnpaidFood = { id: string; meal: string; date: string; cost: number; unpaid: number };
type Tab = "service" | "product" | "expense" | "zakat" | "food";

export function Register(props: {
  outletId: string; userId: string; today: string; clockWarnMs: number;
  staff: Staff[]; products: Product[]; entries: RegisterEntry[]; unpaidFood: UnpaidFood[];
  paidByFood: Record<string, { paid: number; activeIds: string[] }>;
}) {
  const { outletId, userId, staff, products, entries, unpaidFood, paidByFood } = props;
  const [tab, setTab] = useState<Tab>("service");
  const [outbox, setOutbox] = useState<OutboxRow[]>([]);
  const [flash, setFlash] = useState<{ ok: boolean; text: string } | null>(null);
  const [offset, setOffset] = useState<number | null>(null);
  const [stale, setStale] = useState(false);
  const staffName = useMemo(() => new Map(staff.map((s) => [s.id, s.name])), [staff]);

  const refresh = useCallback(async () => {
    const rows = await listOps(userId).catch(() => []);
    const mine = rows.filter((r) => r.outlet_id === outletId);
    setOutbox(mine);
    setStale(mine.some((r) => r.status === "pending" && Date.now() - Date.parse(r.created_at) > 10 * 60_000));
    const m = await getMeta().catch(() => null);
    setOffset(m?.offset_ms ?? null);
  }, [outletId, userId]);

  useEffect(() => {
    const first = setTimeout(refresh, 0);
    const t = setInterval(refresh, 3000);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [refresh]);

  async function queue(type: OutboxRow["op"]["type"], recordId: string, data: Record<string, unknown>, extra: { base_version?: number; reason?: string } = {}) {
    try {
      await enqueue(outletId, userId, { type, record_id: recordId, data, ...extra });
      window.dispatchEvent(new Event("salonops:queued"));
      await refresh();
      return true;
    } catch {
      setFlash({ ok: false, text: "Could not save on this device. Write it on paper and tell the manager." });
      return false;
    }
  }

  const saved = (text: string) => {
    setFlash({ ok: true, text });
    setTimeout(() => setFlash(null), 3000);
  };

  // Withdraw a failed op on the server (kept there as resolved by this user, never deleted), then drop the
  // device copy; ops waiting behind it are retried by the next sync and go through normal validation.
  async function withdraw(opId: string, localRow?: string) {
    const why = window.prompt("Why withdraw this change? (it stays in the history for the manager)");
    if (!why?.trim()) return setFlash({ ok: false, text: "A reason is required." });
    const fd = new FormData();
    fd.set("op", opId);
    fd.set("reason", why.trim());
    const r = await withdrawSyncOp(fd).catch(() => ({ ok: false as const, error: "Could not reach the server. Try again when online." }));
    if (!r.ok) return setFlash({ ok: false, text: r.error });
    if (localRow) await removeOps(userId, [localRow]);
    window.dispatchEvent(new Event("salonops:queued"));
    await refresh();
    saved(r.message ?? "Withdrawn.");
  }

  // A blocked op was never stored on the server: send it with the withdrawal so the server records it as
  // withdrawn under its own op id (a later re-send is then a duplicate and never runs).
  async function withdrawBlocked(row: OutboxRow) {
    const why = window.prompt("Why withdraw this change? (it stays in the history for the manager)");
    if (!why?.trim()) return setFlash({ ok: false, text: "A reason is required." });
    const meta = await getMeta().catch(() => null);
    if (!meta) return setFlash({ ok: false, text: "This device's saved entries could not be read. Reload and try again." });
    const fd = new FormData();
    fd.set("outlet", row.outlet_id);
    fd.set("device", meta.device_id);
    fd.set("label", deviceLabel());
    fd.set("op", JSON.stringify(row.op));
    fd.set("reason", why.trim());
    const r = await withdrawBlockedOp(fd).catch(() => ({ ok: false as const, error: "Could not reach the server. Try again when online." }));
    if (!r.ok) return setFlash({ ok: false, text: r.error });
    await removeOps(userId, [row.op_id]);
    window.dispatchEvent(new Event("salonops:queued"));
    await refresh();
    saved(r.message ?? "Withdrawn.");
  }

  // Server entries plus local creates not yet visible in the server props (pending, or synced but
  // the page has not refreshed yet — LiveRefresh catches up), so totals never drop between the two.
  const serverIds = new Set(entries.map((e) => e.id));
  const localCreates = outbox.filter((r) => r.op.type === "create_entry" && !serverIds.has(r.op.record_id));
  const active = entries.filter((e) => e.status === "active" && e.business_date === props.today);

  const byStaff = new Map<string, number>();
  for (const e of active) if (e.kind === "service" && e.staff_id) byStaff.set(e.staff_id, (byStaff.get(e.staff_id) ?? 0) + e.amount);
  for (const r of localCreates) {
    if (r.op.data.kind === "service" && (r.status === "pending" || r.status === "synced")) {
      const sid = r.op.data.staff_id as string;
      byStaff.set(sid, (byStaff.get(sid) ?? 0) + Number(r.op.data.amount));
    }
  }
  const serviceTotal = [...byStaff.values()].reduce((a, b) => a + b, 0);
  const sum = (k: string, f?: (e: RegisterEntry) => boolean) => active.filter((e) => e.kind === k && (!f || f(e))).reduce((a, e) => a + e.amount, 0);
  const issues = outbox.filter((r) => r.status === "failed" || r.status === "conflict" || r.status === "blocked");
  const oldestPending = outbox.filter((r) => r.status === "pending").map((r) => r.created_at).sort()[0];

  return (
    <div className="mx-auto max-w-6xl px-4 py-4">
      {offset != null && Math.abs(offset) > props.clockWarnMs && (
        <div role="alert" className="mb-3 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          This device&apos;s clock is off by about {Math.round(Math.abs(offset) / 60000)} minutes. Ask the manager to fix the date and time settings.
        </div>
      )}
      {stale && oldestPending && (
        <div role="alert" className="mb-3 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          Some entries have been waiting to sync since {new Date(oldestPending).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" })}.
          Keep the paper register too, and use “Save pending entries” below if the internet stays down.
        </div>
      )}
      <div className="grid gap-4 lg:grid-cols-[1fr_340px]">
        <div className="space-y-4">
          <div role="tablist" aria-label="Entry type" className="grid grid-cols-5 gap-1 rounded-xl bg-slate-200 p-1">
            {(["service", "product", "expense", "zakat", "food"] as Tab[]).map((t) => (
              <button key={t} role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
                className={`min-h-12 rounded-lg text-sm font-semibold sm:text-base ${tab === t ? "bg-white text-brand-800 shadow" : "text-slate-700"}`}>
                {KIND[t]}
              </button>
            ))}
          </div>
          {flash && (
            // Fixed overlay: an in-flow banner would shift the keypad under the operator's finger.
            <div role={flash.ok ? "status" : "alert"} className={`pointer-events-none fixed inset-x-4 bottom-4 z-30 mx-auto max-w-md rounded-lg px-4 py-3 text-center text-base font-medium shadow-lg ${flash.ok ? "bg-emerald-100 text-emerald-900" : "bg-rose-100 text-rose-900"}`}>
              {flash.text}
            </div>
          )}
          <div className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
            {tab === "service" && <ServiceForm staff={staff} onSave={async (sid, pay) => {
              if (await queue("create_entry", crypto.randomUUID(), { kind: "service", staff_id: sid, ...pay }))
                saved(`${rupees(Number(pay.amount))} (${payText(pay)}) saved for ${staffName.get(sid)}.`);
            }} />}
            {tab === "product" && <ProductForm products={products} onSave={async (d) => {
              if (await queue("create_entry", crypto.randomUUID(), { kind: "product", ...d })) saved("Product sale saved.");
            }} />}
            {tab === "expense" && <SimpleForm kind="expense" onSave={async (d) => {
              if (await queue("create_entry", crypto.randomUUID(), { kind: "expense", ...d })) saved("Expense saved.");
            }} />}
            {tab === "zakat" && <SimpleForm kind="zakat" staff={staff} onSave={async (d) => {
              if (await queue("create_entry", crypto.randomUUID(), { kind: "zakat", ...d })) saved("Zakat saved.");
            }} />}
            {tab === "food" && <FoodForm onSave={async (d) => {
              if (await queue("create_entry", crypto.randomUUID(), { kind: "food", ...d, ...(d.pay_now ? { payment_id: crypto.randomUUID() } : {}) }))
                saved(d.pay_now ? "Food cost and payment saved." : "Food cost saved (unpaid).");
            }} />}
          </div>

          {unpaidFood.length > 0 && (
            <div className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
              <h2 className="mb-2 font-semibold">Unpaid food</h2>
              <ul className="divide-y divide-slate-100">
                {unpaidFood.map((f) => (
                  <li key={f.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                    <span className="capitalize">{f.meal} · {f.date} · <span className="num font-semibold">{rupees(f.unpaid)}</span> unpaid</span>
                    <span className="flex gap-2">
                      <button className={btnSecondary} onClick={async () => {
                        if (await queue("food_payment", crypto.randomUUID(), { food_id: f.id, amount: f.unpaid, paid_from: "drawer" })) saved("Food paid from the drawer.");
                      }}>Paid from drawer</button>
                      <button className={btnSecondary} onClick={async () => {
                        if (await queue("food_payment", crypto.randomUUID(), { food_id: f.id, amount: f.unpaid, paid_from: "outside_drawer" })) saved("Food marked paid outside the drawer.");
                      }}>Paid outside</button>
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
            <h2 className="mb-2 font-semibold">Recent entries</h2>
            <ul className="divide-y divide-slate-100">
              {localCreates.map((r) => (
                <li key={r.op_id} className="flex items-center justify-between gap-2 py-2 text-sm">
                  <span>{describe(r.op.data, staffName)}</span>
                  <span className="flex items-center gap-2"><span className="num font-semibold">{rupees(amountOf(r.op.data))}</span><Status s={r.status} /></span>
                </li>
              ))}
              {entries.slice(0, 80).map((e) => (
                <li key={e.id} className={`flex flex-wrap items-center justify-between gap-2 py-2 text-sm ${e.status === "voided" ? "text-slate-400 line-through" : ""}`}>
                  <span>
                    <span className="text-slate-500">{new Date(e.received_at).toLocaleTimeString("en-IN", { timeZone: "Asia/Kolkata", hour: "2-digit", minute: "2-digit" })}</span>{" "}
                    {describe(e as unknown as Record<string, unknown>, staffName)}
                    {e.business_date == null && <span className="ml-1 rounded bg-amber-100 px-1 text-xs text-amber-900">undated</span>}
                    {e.late && <span className="ml-1 rounded bg-amber-100 px-1 text-xs text-amber-900">late</span>}
                    {isEdited(e) && <span className="ml-1 rounded bg-violet-100 px-1 text-xs font-semibold text-violet-900">EDITED</span>}
                    {e.timestamp_flags.filter((f) => FLAGS[f]).map((f) => <span key={f} className="ml-1 rounded bg-slate-100 px-1 text-xs">{FLAGS[f]}</span>)}
                  </span>
                  <span className="flex items-center gap-2">
                    <span className="num font-semibold">{rupees(e.amount)}</span>
                    {/* Late entries belong to a submitted/approved day: the server refuses changes until management
                        reopens it (they decide include/exclude on the closing), so offer no buttons that can only fail. */}
                    {e.late && e.status === "active" && <span className="text-xs text-slate-500">management decides</span>}
                    {e.status === "active" && !e.late && (
                      <button className="rounded px-2 py-1 text-xs font-semibold text-brand-700 hover:bg-brand-50" onClick={async () => {
                        const data = askCorrection(e, paidByFood[e.id]?.paid ?? 0);
                        if (typeof data === "string") return setFlash({ ok: false, text: data });
                        if (!data) return;
                        const why = window.prompt("Reason for the correction:");
                        if (!why?.trim()) return setFlash({ ok: false, text: "A reason is required." });
                        if (await queue("correct_entry", e.id, data, { base_version: e.version, reason: why.trim() })) saved("Correction saved.");
                      }}>Correct</button>
                    )}
                    {e.status === "active" && !e.late && (
                      <button className="rounded px-2 py-1 text-xs font-semibold text-rose-700 hover:bg-rose-50" onClick={async () => {
                        const why = window.prompt("Why remove this entry? (it stays in history)");
                        if (!why?.trim()) return;
                        // A paid food entry can only be voided once its payments are reversed (server rule). One op
                        // does both on the server, all or nothing, so the money goes back to where it was paid from.
                        const paid = paidByFood[e.id]?.paid ?? 0;
                        if (paid && !window.confirm(`This food was paid (${rupees(paid)}). Removing it also cancels that payment: the money counts as returned to where it was paid from. Continue?`)) return;
                        if (await queue("void_entry", e.id, paid ? { reverse_payments: true } : {}, { base_version: e.version, reason: why.trim() }))
                          saved(paid ? "Food removed and its payment cancelled." : "Entry removed.");
                      }}>{(paidByFood[e.id]?.paid ?? 0) > 0 ? "Remove + cancel payment" : "Remove"}</button>
                    )}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        </div>

        <aside className="space-y-4">
          <div className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
            <h2 className="mb-2 font-semibold">Today by employee</h2>
            <ul className="space-y-1">
              {staff.map((s) => (
                <li key={s.id} className="flex justify-between text-sm"><span>{s.name}</span><span className="num">{rupees(byStaff.get(s.id) ?? 0)}</span></li>
              ))}
            </ul>
            <div className="mt-2 flex justify-between border-t border-slate-200 pt-2 font-semibold"><span>Services</span><span className="num">{rupees(serviceTotal)}</span></div>
            <div className="flex justify-between text-sm text-slate-600"><span>Commission (10%, rounded down)</span><span className="num">{rupees(commissionPool(serviceTotal))}</span></div>
            <div className="mt-2 space-y-1 text-sm">
              <div className="flex justify-between"><span>Products</span><span className="num">{rupees(sum("product"))}</span></div>
              <div className="flex justify-between"><span>Expenses (drawer)</span><span className="num">{rupees(sum("expense", (e) => e.expense_source === "cash_drawer"))}</span></div>
              <div className="flex justify-between"><span>Zakat</span><span className="num">{rupees(sum("zakat"))}</span></div>
              <div className="flex justify-between"><span>Food</span><span className="num">{rupees(sum("food"))}</span></div>
            </div>
          </div>
          <div id="sync" className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm">
            <h2 className="mb-2 font-semibold">This device</h2>
            <p className="text-sm text-slate-600">
              {outbox.filter((r) => r.status === "pending").length} waiting to sync · {issues.length} problem(s)
            </p>
            {issues.length > 0 && (
              <ul className="mt-2 space-y-2">
                {issues.map((r) => (
                  <li key={r.op_id} className="rounded-lg bg-rose-50 p-2 text-sm text-rose-900">
                    <div className="font-medium">{describe(r.op.data, staffName) || r.op.type.replace("_", " ")} · {rupees(amountOf(r.op.data))}</div>
                    <div>{r.error ?? r.status}</div>
                    {r.status === "failed" && (
                      <button className="mt-1 text-xs font-semibold underline" onClick={() => withdraw(r.op_id, r.op_id)}>
                        Withdraw this change
                      </button>
                    )}
                    {r.status === "conflict" && (
                      <>
                        <div className="mt-1 text-xs">The server kept a copy for the manager; later changes to this entry wait until they resolve it.</div>
                        <button className="mt-1 text-xs font-semibold underline" onClick={async () => {
                          if (!window.confirm("The server has kept a copy for the manager. Remove it from this device?")) return;
                          await removeOps(userId, [r.op_id]);
                          refresh();
                        }}>Clear from this device</button>
                      </>
                    )}
                    {r.status === "blocked" && (() => {
                      const by = (r.result as { blocked_by?: string | null } | undefined)?.blocked_by;
                      const local = by ? outbox.find((x) => x.op_id === by) : undefined;
                      if (local) return <div className="mt-1 text-xs">Waits for the failed change above. Withdraw that one (or a manager resolves it) and this is sent again.</div>;
                      if (by) return (
                        <>
                          <div className="mt-1 text-xs">Waits for an earlier change from this device that failed on the server.</div>
                          <button className="mt-1 text-xs font-semibold underline" onClick={() => withdraw(by)}>Withdraw the earlier failed change</button>
                        </>
                      );
                      return (
                        <>
                          <div className="mt-1 text-xs">Waits for the entry it changes to reach the server. If that entry no longer exists, withdraw this change.</div>
                          <button className="mt-1 text-xs font-semibold underline" onClick={() => withdrawBlocked(r)}>Withdraw this change</button>
                        </>
                      );
                    })()}
                  </li>
                ))}
              </ul>
            )}
            <button className={`${btnSecondary} mt-3 w-full`} onClick={async () => {
              const blob = new Blob([await exportPending(userId)], { type: "application/json" });
              const a = document.createElement("a");
              a.href = URL.createObjectURL(blob);
              a.download = `salonops-pending-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, "-")}.json`;
              a.click();
              URL.revokeObjectURL(a.href);
            }}>Save pending entries</button>
          </div>
        </aside>
      </div>
    </div>
  );
}

// Prompt for the corrected values. Returns the changed fields, null if cancelled or unchanged, or an error text.
function askCorrection(e: RegisterEntry, paid: number): Record<string, unknown> | string | null {
  if (e.kind === "product") {
    const v = window.prompt(`Correct quantity of ${e.product_name} (price ${rupees(e.unit_price ?? 0)} each):`, String(e.quantity));
    if (v == null) return null;
    const q = Number(v);
    if (!Number.isInteger(q) || q < 1 || q > 1000) return "Enter a quantity between 1 and 1000.";
    const m = askMethod(e.payment_method);
    if (m === undefined) return null;
    const d: Record<string, unknown> = {};
    if (q !== e.quantity) d.quantity = q;
    if (m !== e.payment_method) d.payment_method = m;
    return Object.keys(d).length ? d : null;
  }
  const v = window.prompt("Correct amount (₹):", String(e.amount / 100));
  if (v == null) return null;
  const amt = parseRupees(v);
  if (!amt) return "Enter a whole rupee amount.";
  // The server refuses a food cost below what was already paid; say so here instead of creating a sync problem.
  if (e.kind === "food" && amt < paid) return `${rupees(paid)} was already paid for this food. Remove it and enter it again instead.`;
  const d: Record<string, unknown> = {};
  if (amt !== e.amount) d.amount = amt;
  if (e.kind === "service") {
    // Sales recorded before payment methods existed have none: the correction must say how it was paid.
    const m = askMethod(e.payment_method, true);
    if (m === undefined) return null;
    if (m !== e.payment_method) d.payment_method = m;
    let sc: number | null = null, sp: number | null = null;
    if (m === "split") {
      const c = window.prompt(`Split of ${rupees(amt)}: part paid in cash (₹):`, e.split_cash != null ? String(e.split_cash / 100) : "");
      if (c == null) return null;
      sc = parseRupeesAllowZero(c);
      const u = window.prompt("Part paid by UPI / Paytm / Card (₹):", sc != null && sc <= amt ? String((amt - sc) / 100) : "");
      if (u == null) return null;
      sp = parseRupeesAllowZero(u);
    }
    const tip = window.prompt("Tip kept by the employee (not a sale). Type C50 for cash, U50 for UPI / Paytm / Card, C20 U30 for both, or leave empty for none:",
      tipText(e.tip_cash, e.tip_paytm));
    if (tip == null) return null;
    const t = parseTip(tip);
    if (!t) return "Write the tip like C50, U50 or C20 U30, or leave it empty.";
    const pay = servicePayment({ amount: amt, method: m, splitCash: sc, splitPaytm: sp, tipCash: t.cash, tipPaytm: t.paytm });
    if (!pay.ok) return pay.error;
    if (m === "split" && (sc !== e.split_cash || sp !== e.split_paytm || amt !== e.amount || m !== e.payment_method)) {
      d.split_cash = sc; d.split_paytm = sp;
    }
    if (t.cash !== e.tip_cash) d.tip_cash = t.cash;
    if (t.paytm !== e.tip_paytm) d.tip_paytm = t.paytm;
  }
  return Object.keys(d).length ? d : null;
}

function tipText(cash: number, paytm: number) {
  return [cash ? `C${cash / 100}` : "", paytm ? `U${paytm / 100}` : ""].filter(Boolean).join(" ");
}

/** "C20 U30" → paise per channel; empty → none; null if unreadable. */
function parseTip(v: string): { cash: number; paytm: number } | null {
  const out = { cash: 0, paytm: 0 };
  for (const part of v.trim().toUpperCase().split(/\s+/).filter(Boolean)) {
    const m = /^([CU])(\d{1,7})$/.exec(part);
    if (!m) return null;
    out[m[1] === "C" ? "cash" : "paytm"] = Number(m[2]) * 100;
  }
  return out;
}

/** "Cash ₹100 + UPI ₹50 · tip ₹50 (UPI)" for a service payload or entry. */
function payText(d: Record<string, unknown>) {
  const m = String(d.payment_method ?? "");
  const base = m === "split" ? `Cash ${rupees(Number(d.split_cash))} + UPI / Paytm / Card ${rupees(Number(d.split_paytm))}` : PAID_BY[m] ?? "";
  const tips = [Number(d.tip_cash ?? 0) ? `${rupees(Number(d.tip_cash))} cash` : "", Number(d.tip_paytm ?? 0) ? `${rupees(Number(d.tip_paytm))} UPI` : ""].filter(Boolean);
  return tips.length ? `${base} · tip ${tips.join(" + ")}` : base;
}

function askMethod(current: string | null, allowSplit: true): PayMethod | undefined;
function askMethod(current: string | null): "cash" | "paytm" | undefined;
function askMethod(current: string | null, allowSplit = false): PayMethod | undefined {
  for (;;) {
    const v = window.prompt(`Paid by? Type C for Cash or U for UPI / Paytm / Card${allowSplit ? ", or S for Split (both)" : ""}:`,
      current === "paytm" ? "U" : current === "cash" ? "C" : current === "split" ? "S" : "");
    if (v == null) return undefined;
    const k = v.trim().toUpperCase();
    if (k === "C") return "cash";
    if (k === "U") return "paytm";
    if (k === "S" && allowSplit) return "split";
  }
}

function amountOf(d: Record<string, unknown>) {
  if (d.kind === "product") return Number(d.quantity) * Number(d.unit_price);
  return Number(d.amount ?? 0);
}

function describe(d: Record<string, unknown>, names: Map<string, string>) {
  switch (d.kind) {
    case "service": return `Service · ${names.get(String(d.staff_id)) ?? "employee"}${d.payment_method ? ` · ${payText(d)}` : ""}`;
    case "product": return `Product · ${d.product_name ?? "item"}${d.quantity ? ` × ${d.quantity}` : ""} · ${d.payment_method === "paytm" ? "Paytm" : "Cash"}`;
    case "expense": return `Expense · ${d.description ?? ""}${d.expense_source === "outside_drawer" ? " (outside drawer)" : ""}`;
    case "zakat": return `Zakat${d.staff_id ? ` · ${names.get(String(d.staff_id)) ?? ""}` : ""}`;
    case "food": return `Food · ${d.meal ?? ""}`;
    default: return "";
  }
}

function Status({ s }: { s: string }) {
  const map: Record<string, string> = { pending: "bg-sky-100 text-sky-900", synced: "bg-emerald-100 text-emerald-900", failed: "bg-rose-100 text-rose-900", conflict: "bg-rose-100 text-rose-900", blocked: "bg-amber-100 text-amber-900" };
  return <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${map[s] ?? ""}`}>{s === "pending" ? "waiting" : s}</span>;
}

function Keypad({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const press = (k: string) => onChange(k === "⌫" ? value.slice(0, -1) : k === "C" ? "" : (value + k).replace(/^0+/, "").slice(0, 7));
  return (
    <div>
      <div className="num mb-2 rounded-lg border border-slate-300 bg-slate-50 px-3 py-2 text-right text-3xl font-semibold" aria-live="polite">
        ₹{value || "0"}
      </div>
      <div className="grid grid-cols-3 gap-2">
        {["1", "2", "3", "4", "5", "6", "7", "8", "9", "C", "0", "⌫"].map((k) => (
          <button key={k} type="button" onClick={() => press(k)} aria-label={k === "⌫" ? "Delete digit" : k === "C" ? "Clear" : k}
            className="num min-h-14 rounded-lg border border-slate-300 bg-white text-2xl font-semibold active:bg-slate-100">{k}</button>
        ))}
      </div>
    </div>
  );
}

function ServiceForm({ staff, onSave }: { staff: Staff[]; onSave: (staffId: string, pay: Record<string, unknown>) => Promise<void> }) {
  const [sid, setSid] = useState<string | null>(null);
  const [amt, setAmt] = useState("");
  const [method, setMethod] = useState<PayMethod | null>(null);
  const [splitCash, setSplitCash] = useState("");
  const [splitPaytm, setSplitPaytm] = useState("");
  const [tipOpen, setTipOpen] = useState(false);
  const [tipCash, setTipCash] = useState("");
  const [tipPaytm, setTipPaytm] = useState("");
  if (!staff.length) return <p className="text-sm text-slate-600">No employees are assigned to this outlet today. Ask the manager.</p>;
  const amount = parseRupees(amt);
  const zero = (v: string) => (v.trim() === "" ? 0 : parseRupeesAllowZero(v));
  const pay = amount && method ? servicePayment({
    amount, method,
    splitCash: method === "split" && splitCash.trim() !== "" ? parseRupeesAllowZero(splitCash) : null,
    splitPaytm: method === "split" && splitPaytm.trim() !== "" ? parseRupeesAllowZero(splitPaytm) : null,
    tipCash: zero(tipCash), tipPaytm: zero(tipPaytm),
  }) : null;
  const badTip = zero(tipCash) == null || zero(tipPaytm) == null;
  const reset = () => { setAmt(""); setSid(null); setMethod(null); setSplitCash(""); setSplitPaytm(""); setTipOpen(false); setTipCash(""); setTipPaytm(""); };
  return (
    <div className="grid gap-4 md:grid-cols-2">
      <div>
        <p className={labelCls}>1. Who did the service?</p>
        <div className="grid grid-cols-2 gap-2">
          {staff.map((s) => (
            <button key={s.id} type="button" onClick={() => setSid(s.id)} aria-pressed={sid === s.id}
              className={`min-h-14 rounded-lg border px-2 text-base font-semibold ${sid === s.id ? "border-brand-700 bg-brand-50 text-brand-800" : "border-slate-300 bg-white"}`}>
              {s.name}{s.temporary && <span className="block text-xs font-normal text-slate-500">visiting</span>}
            </button>
          ))}
        </div>
      </div>
      <div>
        <p className={labelCls}>2. Service amount (after discount, without tip)</p>
        <Keypad value={amt} onChange={setAmt} />
        <fieldset className="mt-3">
          <legend className={labelCls}>3. Paid by</legend>
          <div className="grid grid-cols-3 gap-2">
            {(["cash", "paytm", "split"] as const).map((m) => (
              <button key={m} type="button" aria-pressed={method === m} onClick={() => setMethod(m)}
                className={`min-h-14 rounded-lg border-2 px-1 text-sm font-semibold sm:text-base ${method === m ? "border-brand-700 bg-brand-700 text-white" : "border-slate-300 bg-white"}`}>
                {method === m && <span aria-hidden="true">✓ </span>}{m === "split" ? "Split" : PAID_BY[m]}
              </button>
            ))}
          </div>
        </fieldset>
        {method === "split" && (
          <div className="mt-3 grid grid-cols-2 gap-2">
            <div><label htmlFor="split-cash" className={labelCls}>Cash (₹)</label>
              <input id="split-cash" inputMode="numeric" className={input} value={splitCash} onChange={(e) => setSplitCash(e.target.value)} /></div>
            <div><label htmlFor="split-paytm" className={labelCls}>UPI / Paytm / Card (₹)</label>
              <input id="split-paytm" inputMode="numeric" className={input} value={splitPaytm} onChange={(e) => setSplitPaytm(e.target.value)} /></div>
            <p className={`col-span-2 text-sm ${pay && !pay.ok ? "text-rose-700" : "text-slate-600"}`}>
              {pay && !pay.ok ? pay.error : `Together ${amount ? rupees(amount) : "the service amount"}.`}
            </p>
          </div>
        )}
        <div className="mt-3">
          {!tipOpen ? (
            <button type="button" className="text-sm font-semibold text-brand-700 underline" onClick={() => setTipOpen(true)}>+ Customer gave a tip</button>
          ) : (
            <fieldset className="rounded-lg border border-slate-200 p-2">
              <legend className="px-1 text-sm font-semibold">Tip for the employee (not a sale, no commission)</legend>
              <div className="grid grid-cols-2 gap-2">
                <div><label htmlFor="tip-cash" className={labelCls}>Tip in cash (₹)</label>
                  <input id="tip-cash" inputMode="numeric" className={input} value={tipCash} onChange={(e) => setTipCash(e.target.value)} /></div>
                <div><label htmlFor="tip-paytm" className={labelCls}>Tip by UPI / Paytm / Card (₹)</label>
                  <input id="tip-paytm" inputMode="numeric" className={input} value={tipPaytm} onChange={(e) => setTipPaytm(e.target.value)} /></div>
              </div>
              <p className="mt-1 text-xs text-slate-600">Give the tip to the employee now. A UPI / Paytm / Card tip is paid to them in cash from the drawer.</p>
              {badTip && <p className="text-sm text-rose-700">Enter the tip in whole rupees.</p>}
            </fieldset>
          )}
        </div>
        <button className={`${btnPrimary} mt-3 w-full min-h-14 text-lg`} disabled={!sid || !pay?.ok || badTip}
          onClick={async () => { if (sid && pay?.ok && !badTip) { await onSave(sid, pay.data); reset(); } }}>
          {method ? "Save sale" : "Choose how it was paid"}
        </button>
      </div>
    </div>
  );
}

function ProductForm({ products, onSave }: { products: Product[]; onSave: (d: Record<string, unknown>) => Promise<void> }) {
  const [pid, setPid] = useState("");
  const [qty, setQty] = useState("1");
  const [price, setPrice] = useState("");
  const [method, setMethod] = useState<"cash" | "paytm" | "">("");
  if (!products.length) return <p className="text-sm text-slate-600">No products in the catalogue yet. Ask the manager to add them.</p>;
  const unit = parseRupees(price);
  const q = Number(qty);
  const ok = pid && unit && Number.isInteger(q) && q >= 1 && q <= 1000 && method;
  return (
    <form className="grid gap-3 sm:grid-cols-2" onSubmit={async (e) => {
      e.preventDefault();
      if (!ok) return;
      await onSave({ product_id: pid, product_name: products.find((p) => p.id === pid)?.name, quantity: q, unit_price: unit, payment_method: method });
      setPid(""); setQty("1"); setPrice(""); setMethod("");
    }}>
      <div className="sm:col-span-2">
        <label htmlFor="product" className={labelCls}>Product</label>
        <select id="product" className={input} value={pid} onChange={(e) => {
          setPid(e.target.value);
          const p = products.find((x) => x.id === e.target.value);
          if (p) setPrice(String(p.price / 100));
        }}>
          <option value="">Choose…</option>
          {products.map((p) => <option key={p.id} value={p.id}>{p.name} ({rupees(p.price)})</option>)}
        </select>
      </div>
      <div><label htmlFor="qty" className={labelCls}>Quantity</label><input id="qty" inputMode="numeric" className={input} value={qty} onChange={(e) => setQty(e.target.value)} /></div>
      <div><label htmlFor="price" className={labelCls}>Price per unit (₹)</label><input id="price" inputMode="numeric" className={input} value={price} onChange={(e) => setPrice(e.target.value)} /></div>
      <fieldset className="sm:col-span-2">
        <legend className={labelCls}>Paid by</legend>
        <div className="grid grid-cols-2 gap-2">
          {(["cash", "paytm"] as const).map((m) => (
            <button key={m} type="button" aria-pressed={method === m} onClick={() => setMethod(m)}
              className={`min-h-12 rounded-lg border font-semibold ${method === m ? "border-brand-700 bg-brand-50 text-brand-800" : "border-slate-300"}`}>
              {m === "cash" ? "Cash" : "Paytm (UPI / card)"}
            </button>
          ))}
        </div>
      </fieldset>
      <div className="sm:col-span-2 flex items-center justify-between">
        <span className="num text-lg font-semibold">Total {unit && q > 0 ? rupees(unit * q) : "—"}</span>
        <button className={btnPrimary} disabled={!ok}>Save product sale</button>
      </div>
    </form>
  );
}

function SimpleForm({ kind, staff, onSave }: { kind: "expense" | "zakat"; staff?: Staff[]; onSave: (d: Record<string, unknown>) => Promise<void> }) {
  const [amt, setAmt] = useState("");
  const [desc, setDesc] = useState("");
  const [notes, setNotes] = useState("");
  const [src, setSrc] = useState("cash_drawer");
  const [donor, setDonor] = useState("");
  const amount = parseRupees(amt);
  const ok = amount && (kind === "zakat" || desc.trim());
  return (
    <form className="grid gap-3 sm:grid-cols-2" onSubmit={async (e) => {
      e.preventDefault();
      if (!ok) return;
      await onSave(kind === "expense"
        ? { amount, description: desc.trim(), notes: notes.trim() || undefined, expense_source: src }
        : { amount, description: desc.trim() || undefined, staff_id: donor || undefined });
      setAmt(""); setDesc(""); setNotes(""); setDonor("");
    }}>
      <div><label htmlFor={`${kind}-amt`} className={labelCls}>Amount (₹)</label><input id={`${kind}-amt`} inputMode="numeric" className={input} value={amt} onChange={(e) => setAmt(e.target.value)} /></div>
      <div><label htmlFor={`${kind}-desc`} className={labelCls}>{kind === "expense" ? "What was it for?" : "Note (optional)"}</label><input id={`${kind}-desc`} maxLength={300} className={input} value={desc} onChange={(e) => setDesc(e.target.value)} /></div>
      {kind === "expense" ? (
        <>
          <div>
            <label htmlFor="src" className={labelCls}>Paid from</label>
            <select id="src" className={input} value={src} onChange={(e) => setSrc(e.target.value)}>
              <option value="cash_drawer">Cash drawer</option>
              <option value="outside_drawer">Outside the drawer (owner paid)</option>
            </select>
          </div>
          <div><label htmlFor="notes" className={labelCls}>Notes (optional)</label><input id="notes" maxLength={500} className={input} value={notes} onChange={(e) => setNotes(e.target.value)} /></div>
        </>
      ) : (
        <div>
          <label htmlFor="donor" className={labelCls}>Given by (optional)</label>
          <select id="donor" className={input} value={donor} onChange={(e) => setDonor(e.target.value)}>
            <option value="">—</option>
            {staff?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
        </div>
      )}
      <div className="sm:col-span-2 flex justify-end"><button className={btnPrimary} disabled={!ok}>Save {kind === "expense" ? "expense" : "zakat"}</button></div>
    </form>
  );
}

function FoodForm({ onSave }: { onSave: (d: { meal: string; amount: number; pay_now: boolean; description?: string }) => Promise<void> }) {
  const [meal, setMeal] = useState("");
  const [amt, setAmt] = useState("");
  const [payNow, setPayNow] = useState(true); // B15: "Paid now from drawer" pre-ticked
  const amount = parseRupees(amt);
  return (
    <form className="grid gap-3 sm:grid-cols-2" onSubmit={async (e) => {
      e.preventDefault();
      if (!meal || !amount) return;
      await onSave({ meal, amount, pay_now: payNow });
      setMeal(""); setAmt(""); setPayNow(true);
    }}>
      <fieldset className="sm:col-span-2">
        <legend className={labelCls}>Meal</legend>
        <div className="grid grid-cols-3 gap-2">
          {["breakfast", "lunch", "dinner"].map((m) => (
            <button key={m} type="button" aria-pressed={meal === m} onClick={() => setMeal(m)}
              className={`min-h-12 rounded-lg border font-semibold capitalize ${meal === m ? "border-brand-700 bg-brand-50 text-brand-800" : "border-slate-300"}`}>{m}</button>
          ))}
        </div>
      </fieldset>
      <div><label htmlFor="food-amt" className={labelCls}>Food cost (₹)</label><input id="food-amt" inputMode="numeric" className={input} value={amt} onChange={(e) => setAmt(e.target.value)} /></div>
      <label className="flex items-center gap-3 self-end py-2 text-base">
        <input type="checkbox" className="h-6 w-6" checked={payNow} onChange={(e) => setPayNow(e.target.checked)} />
        Paid now from the drawer
      </label>
      <p className="sm:col-span-2 text-xs text-slate-500">Food is paid from the employees&apos; commission, not from shop expenses.</p>
      <div className="sm:col-span-2 flex justify-end"><button className={btnPrimary} disabled={!meal || !amount}>Save food</button></div>
    </form>
  );
}
