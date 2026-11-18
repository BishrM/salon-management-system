import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Notice, Table, fmtTime } from "@/components/ui";
import { PaytmImport } from "./paytm-import";
import { rupees } from "@/lib/money";

export const metadata: Metadata = { title: "Paytm import" };

export default async function Paytm() {
  const { supabase, outlet } = await requirePermission("paytm.enter");
  const { data: recent } = await supabase.from("paytm_transactions").select("*").eq("outlet_id", outlet.id)
    .order("txn_time", { ascending: false }).limit(50);
  return (
    <Page title="Paytm reconciliation">
      <Notice>
        Paytm does not offer a documented API that lists payments received on a static QR or Soundbox account, so SalonOps does not
        connect to Paytm directly. Enter the daily Paytm total on the closing screen, and optionally import the statement you download
        from the Paytm for Business app here to compare it transaction by transaction. Re-importing the same file never creates duplicates.
      </Notice>
      <Card title="Import a Paytm statement (CSV)">
        <PaytmImport outletId={outlet.id} />
      </Card>
      <Card title="Recently imported">
        <Table head={["Time", "Reference", "Day", "Amount", "Status", "Method"]} rows={(recent ?? []).map((t) => [
          fmtTime(t.txn_time), t.txn_ref, t.business_date, rupees(t.amount), t.status, t.method,
        ])} empty="Nothing imported yet." />
      </Card>
    </Page>
  );
}
