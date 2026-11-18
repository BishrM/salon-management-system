import type { Metadata } from "next";
import { requirePermission } from "@/lib/session";
import { Page, Card, Table, input, labelCls, fmtTime } from "@/components/ui";
import { ActionForm } from "@/components/action-form";
import { createUser, addMembership, grantActingHead, revokeMembership } from "../../actions";

export const metadata: Metadata = { title: "Users" };

const ROLE: Record<string, string> = { owner: "Owner", manager: "Management (owner's son)", head: "Head employee", counter: "Counter operator" };

export default async function Users() {
  const ctx = await requirePermission("delegation.manage");
  const { supabase, outlet, can, userId } = ctx;
  const { data: rows } = await supabase.from("outlet_memberships")
    .select("id, profile_id, role, is_acting, valid_from, valid_to, revoked_at, revoke_reason, reason, granted_by, profiles:profile_id(full_name)")
    .eq("outlet_id", outlet.id).order("created_at", { ascending: false });
  const all = (rows ?? []).map((r) => ({ ...r, who: (r.profiles as unknown as { full_name: string } | null)?.full_name ?? "—" }));
  const permanent = all.filter((r) => !r.is_acting && !r.revoked_at);
  const acting = all.filter((r) => r.is_acting);
  const name = (id: string | null) => all.find((r) => r.profile_id === id)?.who ?? "—";

  return (
    <Page title="Users and acting head">
      {can("users.manage") && (
        <Card title="Create a login">
          <p className="mb-3 text-sm text-slate-600">General employees do not need logins. Give the password to the person directly; they can change it later.</p>
          <ActionForm action={createUser} submit="Create login">
            <input type="hidden" name="outlet" value={outlet.id} />
            <div className="grid gap-3 sm:grid-cols-2">
              <div><label className={labelCls} htmlFor="fn">Full name</label><input id="fn" name="full_name" className={input} required /></div>
              <div><label className={labelCls} htmlFor="em">Email</label><input id="em" name="email" type="email" className={input} required /></div>
              <div><label className={labelCls} htmlFor="pw">Temporary password (8+ characters, a letter and a digit)</label><input id="pw" name="password" type="text" autoComplete="new-password" className={input} required minLength={8} /></div>
              <div><label className={labelCls} htmlFor="rl">Role</label>
                <select id="rl" name="role" className={input}>{Object.entries(ROLE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></div>
            </div>
          </ActionForm>
        </Card>
      )}

      <Card title="People with a role here">
        <Table head={["Name", "Role", "Since", ""]} rows={permanent.map((m) => [
          m.who, ROLE[m.role], fmtTime(m.valid_from),
          can("users.manage") && m.profile_id !== userId ? (
            <ActionForm key="r" action={revokeMembership} submit="Remove role" inline danger confirm={`Remove ${m.who}'s ${ROLE[m.role]} role? Their history is kept.`}>
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
              <div><label className={labelCls} htmlFor="ar">Role</label><select id="ar" name="role" className={input}>{Object.entries(ROLE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></div>
              <div><label className={labelCls} htmlFor="aw">Reason</label><input id="aw" name="reason" className={input} required /></div>
            </ActionForm></div>
          </details>
        )}
      </Card>

      <Card title="Acting head employee">
        <p className="mb-3 text-sm text-slate-600">When the head employee is away, give someone head access for a fixed time. It ends automatically.</p>
        <ActionForm action={grantActingHead} submit="Grant acting head" confirm="Grant temporary head access?">
          <input type="hidden" name="outlet" value={outlet.id} />
          <div className="grid gap-3 sm:grid-cols-4">
            <div><label className={labelCls} htmlFor="gp">Person</label>
              <select id="gp" name="profile" className={input} required>
                {permanent.filter((m) => m.profile_id !== userId && m.role !== "owner").map((m) => <option key={m.id} value={m.profile_id}>{m.who}</option>)}
              </select></div>
            <div><label className={labelCls} htmlFor="gf">From (blank = now)</label><input id="gf" name="from" type="datetime-local" className={input} /></div>
            <div><label className={labelCls} htmlFor="gt">Until</label><input id="gt" name="to" type="datetime-local" className={input} required /></div>
            <div><label className={labelCls} htmlFor="gr">Reason</label><input id="gr" name="reason" className={input} required /></div>
          </div>
        </ActionForm>
        <div className="mt-4">
          <Table head={["Person", "From", "Until", "Granted by", "Status", ""]} rows={acting.map((a) => {
            const status = delegationStatus(a);
            return [a.who, fmtTime(a.valid_from), fmtTime(a.valid_to), name(a.granted_by), status,
              !a.revoked_at && status !== "Expired" ? (
                <ActionForm key="r" action={revokeMembership} submit="End now" inline danger>
                  <input type="hidden" name="membership" value={a.id} />
                  <input name="reason" placeholder="Reason" className={input} required aria-label="Reason" />
                </ActionForm>
              ) : ""];
          })} empty="No delegations." />
        </div>
      </Card>
    </Page>
  );
}

function delegationStatus(a: { revoked_at: string | null; revoke_reason: string | null; valid_from: string; valid_to: string | null }) {
  const now = Date.now();
  if (a.revoked_at) return `Revoked (${a.revoke_reason})`;
  if (new Date(a.valid_to!).getTime() <= now) return "Expired";
  return new Date(a.valid_from).getTime() > now ? "Scheduled" : "Active";
}
