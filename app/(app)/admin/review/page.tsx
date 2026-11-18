import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Table, input, fmtTime } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { assignBusinessDate, resolveSyncIssue } from "../../actions";
import { RecoveryImport } from "./recovery-import";
import { rupees } from "@/lib/money";
import { KIND, FLAGS } from "@/lib/labels";

export const metadata: Metadata = { title: "Undated entries and sync issues" };

export default async function Review() {
  const ctx = await requirePermission("date.assign");
  const { supabase, outlet, can } = ctx;
  const [{ data: undated }, { data: undatedPays }, { data: issues }, { data: staff }, { data: devices }] = await Promise.all([
    supabase.from("entries").select("id, kind, amount, staff_id, description, device_time, device_offset_ms, received_at, bound_lower, bound_upper, timestamp_flags")
      .eq("outlet_id", outlet.id).is("business_date", null).eq("status", "active").order("server_seq"),
    supabase.from("food_payments").select("id, amount, paid_from, device_time, received_at, bound_lower, bound_upper, timestamp_flags")
      .eq("outlet_id", outlet.id).is("business_date", null).order("server_seq"),
    supabase.from("sync_ops").select("id, op_type, status, error_message, payload, received_at, device_id, device_seq, submitted_by")
      .eq("outlet_id", outlet.id).neq("status", "applied").is("resolved_at", null).order("id").limit(200),
    supabase.from("staff").select("id, full_name"),
    supabase.from("devices").select("id, label, last_contact_at, last_synced_seq").eq("outlet_id", outlet.id).order("last_contact_at", { ascending: false }),
  ]);
  const staffName = (id: string | null) => staff?.find((s) => s.id === id)?.full_name ?? "";
  const rows = [
    ...(undated ?? []).map((e) => ({ ...e, k: "entry" as const, label: `${KIND[e.kind]} ${e.kind === "service" ? staffName(e.staff_id) : e.description ?? ""}` })),
    ...(undatedPays ?? []).map((p) => ({ ...p, k: "food_payment" as const, label: `Food payment (${p.paid_from.replace("_", " ")})` })),
  ];

  return (
    <Page title="Undated entries and sync issues">
      <Card title="Entries that need a business date">
        <p className="mb-3 text-sm text-slate-600">These were recorded offline on a device whose clock could not be trusted. The device time is shown as reported; the true time is between the bounds.</p>
        <Table head={["Entry", "Amount", "Device said", "True time between", "Flags", "Assign"]} rows={rows.map((r) => [
          r.label, rupees(r.amount), fmtTime(r.device_time),
          `${r.bound_lower ? fmtTime(r.bound_lower) : "unknown"} – ${fmtTime(r.bound_upper)}`,
          r.timestamp_flags.map((f: string) => FLAGS[f] ?? f).join(", "),
          <ActionForm key="a" action={assignBusinessDate} submit="Assign" inline>
            <input type="hidden" name="kind" value={r.k} /><input type="hidden" name="id" value={r.id} />
            <input type="date" name="date" className={input} required aria-label="Business date" />
            <input name="reason" placeholder="Reason (e.g. paper register)" className={input} required aria-label="Reason" />
          </ActionForm>,
        ])} empty="Nothing to date." />
      </Card>

      {can("sync.manage") && (
        <Card title="Sync issues">
          <p className="mb-3 text-sm text-slate-600">Operations the server stored but could not apply. Nothing was lost: re-enter the entry correctly if needed, then mark the issue resolved with a note.</p>
          <Table head={["Received", "Type", "Status", "Problem", "Details", ""]} rows={(issues ?? []).map((i) => [
            fmtTime(i.received_at), i.op_type.replace(/_/g, " "), i.status, i.error_message ?? "",
            <code key="p" className="block max-w-xs truncate text-xs">{JSON.stringify(i.payload?.data ?? {})}</code>,
            <ActionForm key="r" action={resolveSyncIssue} submit="Resolve" inline>
              <input type="hidden" name="id" value={i.id} />
              <input name="reason" placeholder="What was done" className={input} required aria-label="Resolution note" />
            </ActionForm>,
          ])} empty="No open sync issues." />
        </Card>
      )}

      {can("sync.manage") && (
        <Card title="Devices">
          <Table head={["Device", "Last contact", "Synced up to"]} rows={(devices ?? []).map((d) => [d.label ?? d.id.slice(0, 8), fmtTime(d.last_contact_at), `#${d.last_synced_seq}`])} empty="No devices yet." />
        </Card>
      )}

      {can("sync.manage") && (
        <Card title="Recover pending entries from a file">
          <p className="mb-3 text-sm text-slate-600">If a tablet saved its pending entries to a file (“Save pending entries”), import it here. Entries already synced are skipped automatically.</p>
          <RecoveryImport />
        </Card>
      )}
    </Page>
  );
}
