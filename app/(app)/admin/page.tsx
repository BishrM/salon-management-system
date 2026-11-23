import type { Metadata } from "next";
import Link from "next/link";
import { getContext } from "@/lib/session";
import { redirect } from "next/navigation";
import { Page, Card } from "@/components/ui";
import { rupees } from "@/lib/money";

export const metadata: Metadata = { title: "Admin" };

// Production setup gate (Rev 6 §8, §10.1): cutoff, denominations, staff, catalogue, users, initial float.
export default async function Admin() {
  const ctx = await getContext();
  if (!ctx.outlet) redirect("/no-outlet");
  const { supabase, outlet, can } = ctx;
  const [{ count: staff }, { count: products }, { count: members }, { data: init }, { count: unassigned }, { count: issues }] = await Promise.all([
    supabase.from("staff_assignments").select("id", { count: "exact", head: true }).eq("outlet_id", outlet.id).is("end_date", null),
    supabase.from("product_catalog").select("id", { count: "exact", head: true }).eq("outlet_id", outlet.id).eq("active", true),
    supabase.from("outlet_memberships").select("id", { count: "exact", head: true }).eq("outlet_id", outlet.id).is("revoked_at", null),
    supabase.from("float_movements").select("amount, effective_business_date").eq("outlet_id", outlet.id).eq("type", "initial_float").maybeSingle(),
    supabase.from("entries").select("id", { count: "exact", head: true }).eq("outlet_id", outlet.id).is("business_date", null).eq("status", "active"),
    supabase.from("sync_ops").select("id", { count: "exact", head: true }).eq("outlet_id", outlet.id).neq("status", "applied").is("resolved_at", null),
  ]);
  const steps = [
    { done: !!outlet.day_cutoff, label: "Business-day cutoff", detail: outlet.day_cutoff ? `Sales before ${outlet.day_cutoff.slice(0, 5)} count for the previous day` : "Not set — entries are disabled", href: "/admin/setup" },
    { done: outlet.denominations.length > 0, label: "Cash denominations", detail: outlet.denominations.map((d) => `₹${d / 100}`).join(", "), href: "/admin/setup" },
    { done: (staff ?? 0) > 0, label: "Employees", detail: `${staff ?? 0} working here`, href: "/staff" },
    { done: (products ?? 0) > 0, label: "Product catalogue", detail: `${products ?? 0} active products`, href: "/admin/catalog" },
    { done: (members ?? 0) > 1, label: "User logins", detail: `${members ?? 0} logins with a role`, href: "/admin/users" },
    { done: !!init, label: "Starting cash float", detail: init ? `${rupees(init.amount)} from ${init.effective_business_date}` : "Owner counts the float once", href: "/admin/float" },
  ];
  const links = [
    { href: "/admin/setup", label: "Outlet settings", show: can("outlet.denominations") },
    { href: "/admin/catalog", label: "Product catalogue", show: can("catalog.manage") },
    { href: "/admin/float", label: "Cash float", show: can("float.manage") },
    { href: "/admin/users", label: "Logins", show: can("members.read") },
    { href: "/admin/review", label: `Undated entries & sync issues${(unassigned ?? 0) + (issues ?? 0) ? ` (${(unassigned ?? 0) + (issues ?? 0)})` : ""}`, show: can("date.assign") },
    { href: "/admin/paytm", label: "Paytm import", show: can("paytm.enter") },
    { href: "/admin/audit", label: "Audit history", show: can("audit.read") },
  ].filter((l) => l.show);

  return (
    <Page title="Admin">
      <Card title="Setup checklist">
        <ol className="space-y-2">
          {steps.map((s) => (
            <li key={s.label} className="flex items-start gap-3">
              <span aria-hidden className={`mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-sm font-bold ${s.done ? "bg-emerald-600 text-white" : "bg-slate-200 text-slate-600"}`}>{s.done ? "✓" : "·"}</span>
              <div>
                <Link href={s.href} className="font-semibold text-brand-800 underline">{s.label}</Link>
                <span className="sr-only">{s.done ? " (done)" : " (to do)"}</span>
                <p className="text-sm text-slate-600">{s.detail}</p>
              </div>
            </li>
          ))}
        </ol>
      </Card>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {links.map((l) => (
          <Link key={l.href} href={l.href} className="rounded-xl border border-slate-200 bg-white p-4 font-semibold shadow-sm hover:border-brand-600">{l.label}</Link>
        ))}
      </div>
    </Page>
  );
}
