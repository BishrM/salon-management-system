import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Table, fmtTime, input, btnSecondary } from "@/components/ui";

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
          l.server_seq, fmtTime(l.at), name(l.actor), `${l.table_name.replace(/_/g, " ")} ${l.row_id?.slice(0, 8) ?? ""}`, l.action, l.reason ?? "",
          <Diff key="d" oldData={l.old_data} newData={l.new_data} />,
        ])} empty="No audit records." />
      </Card>
    </Page>
  );
}

function Diff({ oldData, newData }: { oldData: Record<string, unknown> | null; newData: Record<string, unknown> | null }) {
  const skip = new Set(["updated_at", "created_at", "server_seq", "version"]);
  if (!oldData) return <span className="text-xs text-slate-500">created</span>;
  const changed = Object.keys(newData ?? {}).filter((k) => !skip.has(k) && JSON.stringify(oldData[k]) !== JSON.stringify(newData?.[k]));
  return (
    <ul className="text-xs">
      {changed.map((k) => <li key={k}><b>{k}</b>: {JSON.stringify(oldData[k])} → {JSON.stringify(newData?.[k])}</li>)}
    </ul>
  );
}
