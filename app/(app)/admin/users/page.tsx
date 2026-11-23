import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Table, input, labelCls, fmtTime } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { createUser, addMembership, revokeMembership } from "../../actions";

export const metadata: Metadata = { title: "Users" };

// Two account types (D-28): Owner side (owner, manager = owner's son) and one shared Shop/Staff login per outlet.
const ROLE: Record<string, string> = { owner: "Owner", manager: "Management (owner's son)", shop: "Shop/Staff (shared salon login)" };
const LEGACY: Record<string, string> = { head: "Head employee (retired, no access)", counter: "Counter operator (retired, no access)" };

export default async function Users() {
  const ctx = await requirePermission("members.read");
  const { supabase, outlet, can, userId } = ctx;
  const { data: rows } = await supabase.from("outlet_memberships")
    .select("id, profile_id, role, is_acting, valid_from, valid_to, revoked_at, revoke_reason, reason, granted_by, profiles:profile_id(full_name)")
    .eq("outlet_id", outlet.id).order("created_at", { ascending: false });
  const all = (rows ?? []).map((r) => ({ ...r, who: (r.profiles as unknown as { full_name: string } | null)?.full_name ?? "—" }));
  const permanent = all.filter((r) => !r.is_acting && !r.revoked_at);

  return (
    <Page title="Logins">
      {can("users.manage") && (
        <Card title="Create a login">
          <p className="mb-3 text-sm text-slate-600">Employees do not get their own logins: everyone at the salon uses the outlet&apos;s one Shop/Staff login. Create a Shop/Staff login only if this outlet has none. Give the password in person.</p>
          <ActionForm action={createUser} submit="Create login">
            <input type="hidden" name="outlet" value={outlet.id} />
            <div className="grid gap-3 sm:grid-cols-2">
              <div><label className={labelCls} htmlFor="fn">Full name</label><input id="fn" name="full_name" className={input} required /></div>
              <div><label className={labelCls} htmlFor="em">Email</label><input id="em" name="email" type="email" className={input} required /></div>
              <div><label className={labelCls} htmlFor="pw">Temporary password (8+ characters, a letter and a digit)</label><input id="pw" name="password" type="text" autoComplete="new-password" className={input} required minLength={8} /></div>
              <div><label className={labelCls} htmlFor="rl">Role</label>
                <select id="rl" name="role" className={input} defaultValue="shop">{Object.entries(ROLE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></div>
            </div>
          </ActionForm>
        </Card>
      )}

      <Card title="People with a role here">
        <Table head={["Name", "Role", "Since", ""]} rows={permanent.map((m) => [
          m.who, ROLE[m.role] ?? LEGACY[m.role] ?? m.role, fmtTime(m.valid_from),
          can("users.manage") && m.profile_id !== userId ? (
            <ActionForm key="r" action={revokeMembership} submit="Remove role" inline danger confirm={`Remove ${m.who}'s ${ROLE[m.role] ?? LEGACY[m.role] ?? m.role} role? Their history is kept.`}>
              <input type="hidden" name="membership" value={m.id} />
              <input name="reason" placeholder="Reason" className={input} required aria-label="Reason" />
            </ActionForm>
          ) : "",
        ])} />
        {can("users.manage") && (
          <details className="mt-3">
            <summary className="cursor-pointer text-sm font-semibold text-brand-700">Give an existing login a role here</summary>
            <div className="mt-2"><ActionForm action={addMembership} submit="Add role" inline>
              <input type="hidden" name="outlet" value={outlet.id} />
              <div><label className={labelCls} htmlFor="ap">User id</label><input id="ap" name="profile" className={input} required placeholder="uuid" /></div>
              <div><label className={labelCls} htmlFor="ar">Role</label><select id="ar" name="role" className={input} defaultValue="shop">{Object.entries(ROLE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></div>
              <div><label className={labelCls} htmlFor="aw">Reason</label><input id="aw" name="reason" className={input} required /></div>
            </ActionForm></div>
          </details>
        )}
      </Card>

    </Page>
  );
}
