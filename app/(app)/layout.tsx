import Link from "next/link";
import { getContext } from "@/lib/session";
import { selectOutlet } from "./actions";
import { NavLinks } from "@/components/nav-links";
import { SyncBadge } from "@/components/sync-badge";
import { SignOutButton } from "@/components/sign-out-button";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const ctx = await getContext();
  const links = [
    { href: "/register", label: "Register", show: ctx.can("entries.record") },
    { href: "/dashboard", label: "Dashboard", show: ctx.can("closing.prepare") || ctx.can("reports.read") },
    { href: "/closing", label: "Closing", show: ctx.can("outlet.read") },
    { href: "/approvals", label: "Approvals", show: ctx.can("closing.approve") },
    { href: "/reports", label: "Reports", show: ctx.can("reports.read") },
    { href: "/sheet-changes", label: "Sheet changes", show: ctx.can("audit.read") },
    { href: "/staff", label: "Employees", show: ctx.can("staff.manage") },
    { href: "/admin", label: "Admin", show: ctx.can("float.manage") || ctx.can("users.manage") || ctx.can("catalog.manage") },
  ].filter((l) => l.show);

  return (
    <div className="min-h-dvh">
      <header className="no-print sticky top-0 z-20 border-b border-slate-200 bg-white/95 backdrop-blur">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-x-4 gap-y-2 px-4 py-2">
          <Link href="/" className="text-lg font-bold text-brand-800">SalonOps</Link>
          {ctx.outlets.length > 1 ? (
            <form action={selectOutlet} className="flex items-center gap-1">
              <label htmlFor="outlet" className="sr-only">Outlet</label>
              <select id="outlet" name="outlet_id" defaultValue={ctx.outlet?.id} className="min-h-9 rounded-md border border-slate-300 bg-white px-2 text-sm">
                {ctx.outlets.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
              </select>
              <button className="min-h-9 rounded-md border border-slate-300 px-2 text-sm">Switch</button>
            </form>
          ) : (
            <span className="text-sm font-medium text-slate-600">{ctx.outlet?.name}</span>
          )}
          <div className="ml-auto flex items-center gap-3">
            <SyncBadge userId={ctx.userId} />
            <span className="hidden text-sm text-slate-600 sm:inline">{ctx.userName}</span>
            <SignOutButton userId={ctx.userId} />
          </div>
          <NavLinks links={links.map(({ href, label }) => ({ href, label }))} />
        </div>
      </header>
      <main>{children}</main>
    </div>
  );
}
