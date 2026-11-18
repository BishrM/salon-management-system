import "fake-indexeddb/auto";
import { describe, it, expect, beforeEach, vi } from "vitest";

// Offline outbox + sync runner (Rev 6 §6.1, §6.4) against an in-memory IndexedDB and a fake server
// that mimics sync_ops idempotency (same op → duplicate success; same seq, other content → conflict).

type Op = { op_id: string; device_seq: number; record_id: string; type: string; data: Record<string, unknown>; device_time: string };

function fakeServer() {
  const seen = new Map<string, string>(); // device:seq → op json
  const failedByRecord = new Map<string, string>(); // record → op_id of an unresolved failure (sync_ops blocking rule)
  const sentSeqs: number[] = [];
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
      sentSeqs.push(op.device_seq);
      if (seen.has(key)) return seen.get(key) === json ? { op_id: op.op_id, status: "applied", duplicate: true } : { op_id: op.op_id, status: "conflict", error: "seq reused" };
      const blocker = failedByRecord.get(op.record_id);
      if (blocker && blocker !== op.op_id) return { op_id: op.op_id, status: "blocked", error: "waiting for an earlier operation on this record (missing or unresolved)", blocked_by: blocker };
      if (op.data.amount === 1) {
        failedByRecord.set(op.record_id, op.op_id);
        seen.set(key, json);
        return { op_id: op.op_id, status: "failed", error: "invalid amount" };
      }
      seen.set(key, json);
      return { op_id: op.op_id, status: "applied", result: { id: op.record_id } };
    });
    return new Response(JSON.stringify({ results, server_time: new Date(Date.now() + 90_000).toISOString() }), { status: 200 });
  });
  return {
    fetchMock, seen, sentSeqs, get calls() { return calls; }, dropNext: () => { failNext = true; },
    // withdraw_sync_op / resolve_sync_issue: the failure stays recorded, but stops blocking.
    resolve: (record: string) => failedByRecord.delete(record),
  };
}

const OUTLET = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const USER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";

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
    expect((await mod.listOps(USER))[0].status).toBe("synced");
  });

  it("server rejections are kept on the device as failed (never silently discarded)", async () => {
    await create(1);
    const s = await sync.syncNow(USER);
    expect(s.failed).toBe(1);
    const rows = await mod.listOps(USER);
    expect(rows[0]).toMatchObject({ status: "failed", error: "invalid amount" });
  });

  it("export contains unsynced ops with the device id for recovery import", async () => {
    await create(10000);
    const file = JSON.parse(await mod.exportPending(USER));
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

const op = (user: string, record: string, amount: number, type = "correct_entry") =>
  mod.enqueue(OUTLET, user, { type: type as "correct_entry", record_id: record, data: { amount } });

describe("unresolved dependencies (blocked ops)", () => {
  it("a failed op holds later ops on the same record; they stay on the device as blocked and name the blocker", async () => {
    const rec = crypto.randomUUID();
    const bad = await op(USER, rec, 1);
    await op(USER, rec, 20000);
    const s = await sync.syncNow(USER);
    expect(s).toMatchObject({ failed: 1, blocked: 1, synced: 0 });
    const rows = await mod.listOps(USER);
    expect(rows[1]).toMatchObject({ status: "blocked", result: { blocked_by: bad.op_id } });
  });

  it("after the failure is resolved the blocked op is retried, in device_seq order, and applies", async () => {
    const rec = crypto.randomUUID();
    await op(USER, rec, 1);
    await op(USER, rec, 20000);
    await op(USER, crypto.randomUUID(), 30000);
    await sync.syncNow(USER);
    server.resolve(rec);
    server.sentSeqs.length = 0;
    const s = await sync.syncNow(USER);
    expect(server.sentSeqs).toEqual([2]); // only the blocked op is re-sent; the failed one is not replayed
    expect(s).toMatchObject({ blocked: 0, failed: 1, synced: 2 });
  });

  it("ops are always sent in device_seq order", async () => {
    for (let i = 0; i < 5; i++) await create(10000 + i * 100);
    await sync.syncNow(USER);
    expect(server.sentSeqs).toEqual([1, 2, 3, 4, 5]);
  });
});

describe("account isolation on a shared device", () => {
  it("another account cannot read, send, export or clear this user's queued ops", async () => {
    const mine = await create(10000);
    expect(await mod.listOps(OTHER)).toEqual([]);
    await sync.syncNow(OTHER);
    expect(server.calls).toBe(0);
    expect(JSON.parse(await mod.exportPending(OTHER)).rows).toEqual([]);
    await mod.removeOps(OTHER, [mine.op_id]);
    expect(await mod.listOps(USER)).toHaveLength(1);
  });

  it("pending and failed ops survive another account's session and recover when their owner signs back in", async () => {
    await create(1); // will fail
    await sync.syncNow(USER);
    await create(10000); // pending: "signed out" before it synced
    vi.stubGlobal("navigator", { onLine: true, userAgent: "test", locks: undefined });
    await mod.enqueue(OUTLET, OTHER, { type: "create_entry", record_id: crypto.randomUUID(), data: { kind: "service", amount: 50000 } });
    const other = await sync.syncNow(OTHER);
    expect(other).toMatchObject({ synced: 1, failed: 0, pending: 0 }); // only OTHER's own op
    const back = await sync.syncNow(USER);
    expect(back).toMatchObject({ synced: 1, failed: 1, pending: 0 });
    expect((await mod.listOps(USER)).map((r) => r.user_id)).toEqual([USER, USER]);
  });
});

describe("sign-out decision", () => {
  it("synced → sign out; pending → confirm; problems → typed KEEP; not durable or unreadable → blocked", async () => {
    const { signOutDecision } = await import("@/lib/offline/signout");
    const row = (status: string) => ({ status }) as unknown as import("@/lib/offline/outbox").OutboxRow;
    expect(signOutDecision([], true)).toEqual({ kind: "sign_out" });
    expect(signOutDecision([row("synced")], false)).toEqual({ kind: "sign_out" });
    expect(signOutDecision([row("pending")], true).kind).toBe("confirm");
    const typed = signOutDecision([row("pending"), row("blocked")], true);
    expect(typed).toMatchObject({ kind: "type_to_confirm", word: "KEEP" });
    expect(signOutDecision([row("failed")], true).kind).toBe("type_to_confirm");
    expect(signOutDecision([row("pending")], false).kind).toBe("block");
    expect(signOutDecision([row("failed")], false).kind).toBe("block");
    expect(signOutDecision(null, true).kind).toBe("block");
  });

  it("storage counts as durable only when the browser grants persistence", async () => {
    vi.stubGlobal("navigator", { onLine: true, storage: { persisted: async () => false, persist: async () => false } });
    expect(await mod.storageIsDurable()).toBe(false);
    vi.stubGlobal("navigator", { onLine: true, storage: { persisted: async () => false, persist: async () => true } });
    expect(await mod.storageIsDurable()).toBe(true);
    vi.stubGlobal("navigator", { onLine: true });
    expect(await mod.storageIsDurable()).toBe(false);
  });
});

