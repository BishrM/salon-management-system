// Sync runner (Rev 6 §6.4): one sender per device via the Web Locks API, ops sent in device_seq order,
// clock offset measured on every round trip. Browser only.
import { getMeta, listOps, setClock, updateOps, type OutboxRow, type OpStatus } from "./outbox";

export type SyncSummary = { pending: number; failed: number; conflict: number; blocked: number; synced: number; error?: string };

type ServerResult = { op_id: string; status: string; error?: string; result?: Record<string, unknown> };

function label(): string {
  const ua = navigator.userAgent;
  return /iPad|Tablet|Android(?!.*Mobile)/i.test(ua) ? "Tablet" : /Mobile|iPhone|Android/i.test(ua) ? "Phone" : "Computer";
}

async function sendBatch(outletId: string, rows: OutboxRow[]): Promise<void> {
  const meta = await getMeta();
  const t0 = Date.now();
  const res = await fetch("/api/sync", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ outlet_id: outletId, device_id: meta.device_id, device_label: label(), ops: rows.map((r) => r.op) }),
  });
  const t1 = Date.now();
  if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error ?? `Sync failed (${res.status})`);
  const body = (await res.json()) as { results: ServerResult[]; server_time: string };
  // offset = server − device, measured at the midpoint of the round trip.
  await setClock(Math.round(Date.parse(body.server_time) - (t0 + t1) / 2), body.server_time);
  await updateOps(
    body.results.map((r) => ({
      op_id: r.op_id,
      status: (r.status === "applied" ? "synced" : r.status) as OpStatus,
      error: r.error,
      result: r.result,
    })),
  );
}

let running: Promise<SyncSummary> | null = null;

/** Send every pending/blocked op of the signed-in user, outlet by outlet. Safe to call often. */
export function syncNow(userId: string): Promise<SyncSummary> {
  running ??= (async () => {
    let error: string | undefined;
    const work = async () => {
      if (!navigator.onLine) return;
      const todo = (await listOps()).filter((r) => r.user_id === userId && (r.status === "pending" || r.status === "blocked"));
      const byOutlet = new Map<string, OutboxRow[]>();
      todo.forEach((r) => byOutlet.set(r.outlet_id, [...(byOutlet.get(r.outlet_id) ?? []), r]));
      for (const [outlet, rows] of byOutlet) {
        for (let i = 0; i < rows.length; i += 100) await sendBatch(outlet, rows.slice(i, i + 100));
      }
    };
    try {
      if (navigator.locks) await navigator.locks.request("salonops-sync", work);
      else await work();
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
    const all = (await listOps()).filter((r) => r.user_id === userId);
    const count = (s: OpStatus) => all.filter((r) => r.status === s).length;
    return { pending: count("pending"), failed: count("failed"), conflict: count("conflict"), blocked: count("blocked"), synced: count("synced"), error };
  })().finally(() => {
    running = null;
  });
  return running;
}

/** Measure the clock offset without sending ops (called on load when online). */
export async function measureClock(): Promise<number | null> {
  try {
    const t0 = Date.now();
    const res = await fetch("/api/time", { cache: "no-store" });
    const t1 = Date.now();
    if (!res.ok) return null;
    const { server_time } = (await res.json()) as { server_time: string };
    const offset = Math.round(Date.parse(server_time) - (t0 + t1) / 2);
    const meta = await getMeta();
    await setClock(offset, meta.last_sync_at ?? server_time);
    return offset;
  } catch {
    return null;
  }
}
