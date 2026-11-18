import "fake-indexeddb/auto";
import { describe, it, expect, beforeEach, vi } from "vitest";

// Offline outbox + sync runner (Rev 6 §6.1, §6.4) against an in-memory IndexedDB and a fake server
// that mimics sync_ops idempotency (same op → duplicate success; same seq, other content → conflict).

type Op = { op_id: string; device_seq: number; record_id: string; type: string; data: Record<string, unknown>; device_time: string };

function fakeServer() {
  const seen = new Map<string, string>(); // device:seq → op json
  let calls = 0;
  let failNext = false;
  const fetchMock = vi.fn(async (_url: string, init: { body: string }) => {
    calls++;
    if (failNext) {
      failNext = false;
      throw new TypeError("Failed to fetch"); // network drop
    }
    const body = JSON.parse(init.body) as { device_id: string; ops: Op[] };
    const results = body.ops.map((op) => {
      const key = `${body.device_id}:${op.device_seq}`;
      const json = JSON.stringify(op);
      if (seen.has(key)) return seen.get(key) === json ? { op_id: op.op_id, status: "applied", duplicate: true } : { op_id: op.op_id, status: "conflict", error: "seq reused" };
      if (op.data.amount === 1) return { op_id: op.op_id, status: "failed", error: "invalid amount" };
      seen.set(key, json);
      return { op_id: op.op_id, status: "applied", result: { id: op.record_id } };
    });
    return new Response(JSON.stringify({ results, server_time: new Date(Date.now() + 90_000).toISOString() }), { status: 200 });
  });
  return { fetchMock, seen, get calls() { return calls; }, dropNext: () => { failNext = true; } };
}

const OUTLET = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const USER = "11111111-1111-4111-8111-111111111111";

let mod: typeof import("@/lib/offline/outbox");
let sync: typeof import("@/lib/offline/sync");
let server: ReturnType<typeof fakeServer>;

beforeEach(async () => {
  vi.resetModules();
  // fresh database per test
  globalThis.indexedDB = new (await import("fake-indexeddb")).IDBFactory();
  server = fakeServer();
  vi.stubGlobal("fetch", server.fetchMock);
  vi.stubGlobal("navigator", { onLine: true, userAgent: "test", locks: undefined });
  mod = await import("@/lib/offline/outbox");
  sync = await import("@/lib/offline/sync");
});

const create = (amount: number) => mod.enqueue(OUTLET, USER, { type: "create_entry", record_id: crypto.randomUUID(), data: { kind: "service", amount } });

describe("outbox", () => {
  it("assigns unique, gap-free device_seq even with concurrent enqueues (one IndexedDB transaction each)", async () => {
    const rows = await Promise.all(Array.from({ length: 40 }, () => create(10000)));
    const seqs = rows.map((r) => r.seq).sort((a, b) => a - b);
    expect(seqs).toEqual(Array.from({ length: 40 }, (_, i) => i + 1));
    expect(new Set(rows.map((r) => r.op_id)).size).toBe(40);
  });

  it("keeps the original device time and the clock evidence known at capture", async () => {
    await mod.setClock(-120_000, "2026-11-18T10:00:00.000Z");
    const r = await create(10000);
    expect(r.op.device_offset_ms).toBe(-120_000);
    expect(r.op.device_last_sync_at).toBe("2026-11-18T10:00:00.000Z");
    expect(Date.parse(r.op.device_time)).toBeGreaterThan(0);
    expect(r.status).toBe("pending");
  });
});

describe("sync runner", () => {
  it("does nothing while offline and keeps entries pending", async () => {
    vi.stubGlobal("navigator", { onLine: false, userAgent: "test" });
    await create(10000);
    const s = await sync.syncNow(USER);
    expect(server.calls).toBe(0);
    expect(s.pending).toBe(1);
  });

  it("syncs on reconnect, marks synced and records the server clock offset", async () => {
    await create(10000);
    await create(20000);
    const s = await sync.syncNow(USER);
    expect(s).toMatchObject({ pending: 0, synced: 2, failed: 0 });
    const meta = await mod.getMeta();
    expect(meta.offset_ms).toBeGreaterThan(80_000); // fake server is 90 s ahead
    expect(meta.last_sync_at).not.toBeNull();
  });

  it("a network drop leaves ops pending; the retry is idempotent (no duplicates)", async () => {
    await create(10000);
    server.dropNext();
    const first = await sync.syncNow(USER);
    expect(first.pending).toBe(1);
    expect(first.error).toMatch(/Failed to fetch/);
    const second = await sync.syncNow(USER);
    expect(second).toMatchObject({ pending: 0, synced: 1 });
    expect(server.seen.size).toBe(1);
  });

  it("re-sending an already-applied op does not create a second record", async () => {
    const r = await create(10000);
    await sync.syncNow(USER);
    await mod.updateOps([{ op_id: r.op_id, status: "pending" }]); // simulate lost response
    await sync.syncNow(USER);
    expect(server.seen.size).toBe(1);
    expect((await mod.listOps())[0].status).toBe("synced");
  });

  it("server rejections are kept on the device as failed (never silently discarded)", async () => {
    await create(1);
    const s = await sync.syncNow(USER);
    expect(s.failed).toBe(1);
    const rows = await mod.listOps();
    expect(rows[0]).toMatchObject({ status: "failed", error: "invalid amount" });
  });

  it("export contains unsynced ops with the device id for recovery import", async () => {
    await create(10000);
    const file = JSON.parse(await mod.exportPending());
    expect(file.format).toBe("salonops-pending-v1");
    expect(file.device_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(file.rows).toHaveLength(1);
    expect(file.rows[0].op.device_seq).toBe(1);
  });

  it("only sends the signed-in user's ops", async () => {
    await mod.enqueue(OUTLET, "someone-else", { type: "create_entry", record_id: crypto.randomUUID(), data: { kind: "service", amount: 10000 } });
    await sync.syncNow(USER);
    expect(server.calls).toBe(0);
  });
});
