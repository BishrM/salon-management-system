import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Table, fmtTime, input, btnSecondary } from "@/components/ui";
import { rupees } from "@/lib/money";
import { PAID_BY } from "@/lib/labels";

export const metadata: Metadata = { title: "Audit history" };

const TABLES = ["entries", "food_payments", "closing_drafts", "closing_revisions", "closing_events", "float_movements",
  "commission_handovers", "late_entry_reviews", "outlet_memberships", "staff", "staff_assignments", "outlets", "product_catalog", "sync_ops"];

// Owner-only (SRS §5.1, §6.2): every change with old value, new value, user, time and reason.
export default async function Audit({ searchParams }: { searchParams: Promise<{ table?: string; row?: string }> }) {
  const { supabase, outlet } = await requirePermission("audit.read");
  const { table, row } = await searchParams;
  let q = supabase.from("audit_logs").select("*").eq("outlet_id", outlet.id).order("server_seq", { ascending: false }).limit(200);
  if (table && TABLES.includes(table)) q = q.eq("table_name", table);
  if (row && /^[0-9a-f-]{36}$/i.test(row)) q = q.eq("row_id", row);
  const [{ data: logs }, { data: profiles }] = await Promise.all([q, supabase.from("profiles").select("id, full_name")]);
  const name = (id: string | null) => (id ? profiles?.find((p) => p.id === id)?.full_name ?? id.slice(0, 8) : "system");
  // A register change made offline reaches the server later: show when it was made on the device too.
  const opIds = [...new Set((logs ?? []).map((l) => l.op_id).filter(Boolean))];
  const { data: ops } = opIds.length
    ? await supabase.from("sync_ops").select("op_id, device_time").eq("outlet_id", outlet.id).in("op_id", opIds)
    : { data: [] };
  const madeAt = new Map((ops ?? []).map((o) => [o.op_id, o.device_time as string | null]));

  return (
    <Page title="Audit history">
      <form className="flex flex-wrap gap-2">
        <label htmlFor="t" className="sr-only">Table</label>
        <select id="t" name="table" defaultValue={table ?? ""} className={`${input} w-auto`}>
          <option value="">All records</option>
          {TABLES.map((t) => <option key={t} value={t}>{t.replace(/_/g, " ")}</option>)}
        </select>
        <label htmlFor="r" className="sr-only">Record id</label>
        <input id="r" name="row" defaultValue={row ?? ""} placeholder="Record id (optional)" className={`${input} w-auto`} />
        <button className={btnSecondary}>Filter</button>
      </form>
      <Card>
        <Table head={["#", "When", "Who", "Record", "Action", "Reason", "Changes"]} rows={(logs ?? []).map((l) => [
          l.server_seq,
          <span key="w">{fmtTime(l.at)}{madeAt.get(l.op_id) && <span className="block text-xs text-slate-500">made on device {fmtTime(madeAt.get(l.op_id))}</span>}</span>,
          name(l.actor),
          `${l.table_name === "entries" ? `${(l.new_data ?? l.old_data)?.kind ?? ""} entry` : l.table_name.replace(/_/g, " ")} ${l.row_id?.slice(0, 8) ?? ""}`,
          l.table_name === "entries" && l.action === "UPDATE" ? (l.new_data?.status === "voided" && l.old_data?.status !== "voided" ? "VOIDED" : "EDITED") : l.action,
          l.reason ?? "",
          <Diff key="d" oldData={l.old_data} newData={l.new_data} />,
        ])} empty="No audit records." />
      </Card>
    </Page>
  );
}

const MONEY = new Set(["amount", "unit_price"]);
const show = (k: string, v: unknown) =>
  MONEY.has(k) && typeof v === "number" ? rupees(v)
  : k === "payment_method" ? (v == null ? "not recorded" : PAID_BY[String(v)] ?? String(v))
  : JSON.stringify(v);

// Original (struck through) → corrected value, for every field that changed.
function Diff({ oldData, newData }: { oldData: Record<string, unknown> | null; newData: Record<string, unknown> | null }) {
  const skip = new Set(["updated_at", "updated_by", "created_at", "server_seq", "version"]);
  if (!oldData) {
    const amt = newData?.amount;
    return <span className="text-xs text-slate-500">created{typeof amt === "number" ? ` · ${rupees(amt)}` : ""}</span>;
  }
  const changed = Object.keys(newData ?? {}).filter((k) => !skip.has(k) && JSON.stringify(oldData[k]) !== JSON.stringify(newData?.[k]));
  return (
    <ul className="text-xs">
      {changed.map((k) => (
        <li key={k}><b>{k.replace(/_/g, " ")}</b>: <s className="text-slate-500">{show(k, oldData[k])}</s> → <b>{show(k, newData?.[k])}</b></li>
      ))}
    </ul>
  );
}
