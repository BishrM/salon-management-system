import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Notice } from "@/components/ui";
import { Register, type RegisterEntry } from "./register";
import { LiveRefresh } from "@/components/live-refresh";
import { foodPaid, type FoodPayment } from "@/lib/accounting";

export const metadata: Metadata = { title: "Register" };

export default async function RegisterPage() {
  const ctx = await requirePermission("entries.record");
  const { supabase, outlet, today } = ctx;
  if (!today) {
    return (
      <Page title="Register">
        <Notice tone="warn">The owner has not finished setup (business-day cutoff). Entries are disabled until then.</Notice>
      </Page>
    );
  }
  const [{ data: assigned }, { data: products }, { data: entries }, { data: food }, { data: outletRow }] = await Promise.all([
    supabase.from("staff_assignments").select("staff_id, is_temporary, staff:staff_id(id, full_name, active)")
      .eq("outlet_id", outlet.id).lte("start_date", today).or(`end_date.is.null,end_date.gte.${today}`),
    supabase.from("product_catalog").select("id, name, default_price").eq("outlet_id", outlet.id).eq("active", true).order("name"),
    supabase.from("entries")
      .select("id, kind, amount, staff_id, product_name, quantity, unit_price, payment_method, description, meal, expense_source, status, version, received_at, late, timestamp_flags, business_date")
      .eq("outlet_id", outlet.id).or(`business_date.eq.${today},business_date.is.null`).order("server_seq", { ascending: false }).limit(300),
    supabase.from("entries").select("id, amount, meal, business_date, food_payments(id, amount, reverses_payment_id)")
      .eq("outlet_id", outlet.id).eq("kind", "food").eq("status", "active").gte("business_date", addDays(today, -7)),
    supabase.from("outlets").select("clock_warn_s").eq("id", outlet.id).single(),
  ]);

  const staffMap = new Map<string, { id: string; name: string; temporary: boolean }>();
  for (const a of assigned ?? []) {
    const s = a.staff as unknown as { id: string; full_name: string; active: boolean } | null;
    if (s?.active) staffMap.set(s.id, { id: s.id, name: s.full_name, temporary: a.is_temporary });
  }
  const paidByFood = Object.fromEntries((food ?? []).map((f) => [f.id, foodPaid(f.food_payments as FoodPayment[])]));
  const unpaidFood = (food ?? [])
    .map((f) => ({ id: f.id, meal: f.meal as string, date: f.business_date as string, cost: f.amount, unpaid: f.amount - paidByFood[f.id].paid }))
    .filter((f) => f.unpaid > 0);

  return (
    <>
    <LiveRefresh outletId={outlet.id} />
    <Register
      outletId={outlet.id}
      userId={ctx.userId}
      today={today}
      clockWarnMs={(outletRow?.clock_warn_s ?? 300) * 1000}
      staff={[...staffMap.values()].sort((a, b) => a.name.localeCompare(b.name))}
      products={(products ?? []).map((p) => ({ id: p.id, name: p.name, price: p.default_price }))}
      entries={(entries ?? []) as RegisterEntry[]}
      unpaidFood={unpaidFood}
      paidByFood={paidByFood}
    />
    </>
  );
}

function addDays(d: string, n: number) {
  const t = new Date(d + "T00:00:00Z");
  t.setUTCDate(t.getUTCDate() + n);
  return t.toISOString().slice(0, 10);
}
