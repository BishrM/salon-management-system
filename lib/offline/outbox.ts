// IndexedDB outbox for offline-capable register ops (Rev 6 §6.1, §6.4). Browser only.
//   * device_seq is incremented in the SAME readwrite transaction that stores the op, so two tabs
//     can never take the same number (IndexedDB serialises overlapping readwrite transactions);
//   * every op keeps its original device time, offset and last-sync time as evidence;
//   * nothing is deleted on failure: failed/conflict ops stay until the user clears them after the
//     server has recorded them (they are then visible in management's Sync issues screen).

export type OpType = "create_entry" | "correct_entry" | "void_entry" | "food_payment" | "reverse_food_payment";
export type OpStatus = "pending" | "synced" | "failed" | "conflict" | "blocked";

export type Op = {
  op_id: string;
  device_seq: number;
  type: OpType;
  record_id: string;
  base_version?: number;
  reason?: string;
  device_time: string;
  device_offset_ms: number | null;
  device_last_sync_at: string | null;
  data: Record<string, unknown>;
};

export type OutboxRow = {
  op_id: string;
  seq: number;
  outlet_id: string;
  user_id: string;
  op: Op;
  status: OpStatus;
  error?: string;
  result?: Record<string, unknown>;
  created_at: string;
};

type Meta = { device_id: string; seq: number; offset_ms: number | null; last_sync_at: string | null };

const DB = "salonops";
let dbp: Promise<IDBDatabase> | null = null;

function db(): Promise<IDBDatabase> {
  dbp ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => {
      const d = req.result;
      d.createObjectStore("meta");
      const ops = d.createObjectStore("ops", { keyPath: "op_id" });
      ops.createIndex("seq", "seq", { unique: true });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbp;
}

const done = (tx: IDBTransaction) =>
  new Promise<void>((res, rej) => {
    tx.oncomplete = () => res();
    tx.onerror = () => rej(tx.error);
    tx.onabort = () => rej(tx.error ?? new Error("transaction aborted"));
  });
const val = <T>(r: IDBRequest<T>) =>
  new Promise<T>((res, rej) => {
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });

async function readMeta(store: IDBObjectStore): Promise<Meta> {
  const m = (await val(store.get("meta"))) as Meta | undefined;
  return m ?? { device_id: crypto.randomUUID(), seq: 0, offset_ms: null, last_sync_at: null };
}

export async function getMeta(): Promise<Meta> {
  const tx = (await db()).transaction("meta", "readwrite");
  const store = tx.objectStore("meta");
  const m = await readMeta(store);
  store.put(m, "meta");
  await done(tx);
  return m;
}

export async function setClock(offset_ms: number, last_sync_at: string) {
  const tx = (await db()).transaction("meta", "readwrite");
  const store = tx.objectStore("meta");
  const m = await readMeta(store);
  store.put({ ...m, offset_ms, last_sync_at }, "meta");
  await done(tx);
}

/** Store a new op with the next device_seq, atomically. */
export async function enqueue(
  outletId: string,
  userId: string,
  op: Omit<Op, "op_id" | "device_seq" | "device_time" | "device_offset_ms" | "device_last_sync_at">,
): Promise<OutboxRow> {
  const tx = (await db()).transaction(["meta", "ops"], "readwrite");
  const meta = tx.objectStore("meta");
  const m = await readMeta(meta);
  const seq = m.seq + 1;
  meta.put({ ...m, seq }, "meta");
  const row: OutboxRow = {
    op_id: crypto.randomUUID(),
    seq,
    outlet_id: outletId,
    user_id: userId,
    status: "pending",
    created_at: new Date().toISOString(),
    op: {
      ...op,
      op_id: "",
      device_seq: seq,
      device_time: new Date().toISOString(),
      device_offset_ms: m.offset_ms,
      device_last_sync_at: m.last_sync_at,
    },
  };
  row.op.op_id = row.op_id;
  tx.objectStore("ops").put(row);
  await done(tx);
  return row;
}

export async function listOps(): Promise<OutboxRow[]> {
  const tx = (await db()).transaction("ops", "readonly");
  const rows = (await val(tx.objectStore("ops").index("seq").getAll())) as OutboxRow[];
  return rows;
}

export async function updateOps(updates: { op_id: string; status: OpStatus; error?: string; result?: Record<string, unknown> }[]) {
  const tx = (await db()).transaction("ops", "readwrite");
  const store = tx.objectStore("ops");
  for (const u of updates) {
    const row = (await val(store.get(u.op_id))) as OutboxRow | undefined;
    if (row) store.put({ ...row, status: u.status, error: u.error, result: u.result });
  }
  await done(tx);
}

/** Remove synced ops older than a day, and failed ops the user cleared (server keeps its copy). */
export async function removeOps(opIds: string[]) {
  const tx = (await db()).transaction("ops", "readwrite");
  opIds.forEach((id) => tx.objectStore("ops").delete(id));
  await done(tx);
}

/** "Save pending entries" export (§6.2 step 4): everything not yet synced, with the device id. */
export async function exportPending(): Promise<string> {
  const meta = await getMeta();
  const rows = (await listOps()).filter((r) => r.status !== "synced");
  return JSON.stringify({ format: "salonops-pending-v1", device_id: meta.device_id, exported_at: new Date().toISOString(), rows }, null, 2);
}
