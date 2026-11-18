"use server";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { createClient, createAdminClient } from "@/lib/supabase/server";
import { rpcAction, uuid, date, reason, rupeesToPaise, optionalRupeesToPaise, type ActionResult } from "@/lib/action";
import { friendlyError } from "@/lib/labels";
import { OUTLET_COOKIE } from "@/lib/session";

const obj = (fd: FormData) => Object.fromEntries(fd.entries());
const optText = z.string().trim().max(500).optional().transform((v) => (v ? v : null));

/** Denomination counts from fields named den_<paise>. */
function denominations(fd: FormData): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [k, v] of fd.entries()) {
    if (!k.startsWith("den_") || String(v).trim() === "") continue;
    const n = Number(v);
    if (!Number.isInteger(n) || n < 0 || n > 100000) throw new Error(`Invalid count for ₹${Number(k.slice(4)) / 100}`);
    out[k.slice(4)] = n;
  }
  return out;
}

// Session ------------------------------------------------------------------------------------------
export async function selectOutlet(fd: FormData) {
  const id = uuid.safeParse(fd.get("outlet_id"));
  if (id.success) (await cookies()).set(OUTLET_COOKIE, id.data, { httpOnly: true, sameSite: "lax", secure: true, path: "/", maxAge: 60 * 60 * 24 * 365 });
  revalidatePath("/", "layout");
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

// Outlet setup (setup checklist) ---------------------------------------------------------------------
export async function setCutoff(fd: FormData) {
  return rpcAction(z.object({ outlet: uuid, cutoff: z.string().regex(/^\d{2}:\d{2}$/, "Choose a time"), reason }), obj(fd),
    "set_outlet_cutoff", (v) => ({ p_outlet: v.outlet, p_cutoff: v.cutoff, p_reason: v.reason }), "Cutoff saved.");
}

export async function setDenominations(fd: FormData) {
  return rpcAction(
    z.object({ outlet: uuid, list: z.string().regex(/^\s*\d+(\s*,\s*\d+)*\s*$/, "Enter rupee notes separated by commas"), reason }),
    obj(fd), "set_outlet_denominations",
    (v) => ({ p_outlet: v.outlet, p_denominations: v.list.split(",").map((s) => Number(s.trim()) * 100), p_reason: v.reason }),
    "Denominations saved.");
}

export async function setThresholds(fd: FormData) {
  const n = z.coerce.number().int().positive("Must be a positive whole number");
  return rpcAction(z.object({ outlet: uuid, online: n, clock: n, gap: n, reason }), obj(fd), "set_offline_thresholds",
    (v) => ({ p_outlet: v.outlet, p_online_window_s: v.online, p_clock_warn_s: v.clock, p_gap_flag_h: v.gap, p_reason: v.reason }),
    "Thresholds saved.");
}

export async function setOutletDetails(fd: FormData) {
  return rpcAction(
    z.object({ outlet: uuid, name: z.string().trim().min(1, "Name is required").max(120), address: optText,
      go_live: z.union([date, z.literal("")]).transform((v) => v || null), reason }),
    obj(fd), "set_outlet_details",
    (v) => ({ p_outlet: v.outlet, p_name: v.name, p_address: v.address, p_go_live_date: v.go_live, p_reason: v.reason }),
    "Outlet details saved.");
}

// Staff --------------------------------------------------------------------------------------------
export async function createStaff(fd: FormData) {
  return rpcAction(
    z.object({ outlet: uuid, name: z.string().trim().min(1, "Name is required").max(120), start: date,
      profile: z.union([uuid, z.literal("")]).transform((v) => v || null) }),
    obj(fd), "create_staff",
    (v) => ({ p_outlet: v.outlet, p_full_name: v.name, p_start_date: v.start, p_profile_id: v.profile }), "Employee added.");
}

export async function assignStaff(fd: FormData) {
  const s = z.object({ staff: uuid, outlet: uuid, start: date, end: z.union([date, z.literal("")]).optional(), temporary: z.string().optional(), reason });
  const parsed = s.safeParse(obj(fd));
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0].message } as ActionResult;
  if (parsed.data.temporary) {
    return rpcAction(s, obj(fd), "assign_staff_temporary",
      (v) => ({ p_staff: v.staff, p_outlet: v.outlet, p_start_date: v.start, p_end_date: v.end || null, p_reason: v.reason }),
      "Temporary assignment saved.");
  }
  return rpcAction(s, obj(fd), "assign_staff",
    (v) => ({ p_staff: v.staff, p_outlet: v.outlet, p_start_date: v.start, p_reason: v.reason }), "Assignment saved.");
}

export async function endAssignment(fd: FormData) {
  return rpcAction(z.object({ assignment: uuid, end: date, reason }), obj(fd), "end_staff_assignment",
    (v) => ({ p_assignment: v.assignment, p_end_date: v.end, p_reason: v.reason }), "Assignment ended.");
}

export async function updateStaff(fd: FormData) {
  return rpcAction(
    z.object({ staff: uuid, name: z.string().trim().min(1).max(120), active: z.enum(["true", "false"]), reason }),
    obj(fd), "update_staff",
    (v) => ({ p_staff: v.staff, p_full_name: v.name, p_active: v.active === "true", p_reason: v.reason }), "Employee updated.");
}

// Catalogue ------------------------------------------------------------------------------------------
export async function upsertProduct(fd: FormData) {
  return rpcAction(
    z.object({ outlet: uuid, product: z.union([uuid, z.literal("")]).transform((v) => v || null),
      name: z.string().trim().min(1, "Name is required").max(120), price: rupeesToPaise("Price"),
      active: z.enum(["true", "false"]).default("true") }),
    obj(fd), "upsert_product",
    (v) => ({ p_outlet: v.outlet, p_product: v.product, p_name: v.name, p_default_price: v.price, p_active: v.active === "true" }),
    "Product saved.");
}

// Users and delegation ----------------------------------------------------------------------------------
export async function createUser(fd: FormData): Promise<ActionResult> {
  const parsed = z.object({
    outlet: uuid,
    full_name: z.string().trim().min(1, "Name is required").max(120),
    email: z.string().trim().email("Enter a valid email"),
    password: z.string().min(8, "Password must be at least 8 characters").regex(/[A-Za-z]/, "Password needs a letter").regex(/\d/, "Password needs a digit"),
    role: z.enum(["owner", "manager", "head", "counter"]),
  }).safeParse(obj(fd));
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0].message };
  const v = parsed.data;
  const supabase = await createClient();
  // Verify users.manage with the caller's own session BEFORE touching the service role.
  const { data: perms } = await supabase.rpc("my_permissions", { p_outlet: v.outlet });
  if (!(perms as string[] | null)?.includes("users.manage")) return { ok: false, error: "You do not have permission to do this." };
  const admin = createAdminClient();
  const { data: created, error } = await admin.auth.admin.createUser({
    email: v.email, password: v.password, email_confirm: true, user_metadata: { full_name: v.full_name },
  });
  if (error || !created.user) return { ok: false, error: error?.message ?? "Could not create the login." };
  const { error: mErr } = await supabase.rpc("add_membership", {
    p_outlet: v.outlet, p_profile: created.user.id, p_role: v.role, p_reason: "new user created by owner",
  });
  if (mErr) return { ok: false, error: `Login created but role not added: ${friendlyError(mErr)}` };
  revalidatePath("/", "layout");
  return { ok: true, message: `Login created for ${v.email}. Give them the password in person.` };
}

export async function addMembership(fd: FormData) {
  return rpcAction(z.object({ outlet: uuid, profile: uuid, role: z.enum(["owner", "manager", "head", "counter"]), reason }), obj(fd),
    "add_membership", (v) => ({ p_outlet: v.outlet, p_profile: v.profile, p_role: v.role, p_reason: v.reason }), "Role added.");
}

export async function grantActingHead(fd: FormData) {
  return rpcAction(
    z.object({ outlet: uuid, profile: uuid, from: z.string().optional(), to: z.string().min(1, "End time is required"), reason }),
    obj(fd), "grant_acting_head",
    (v) => ({ p_outlet: v.outlet, p_profile: v.profile, p_valid_to: new Date(v.to).toISOString(), p_reason: v.reason,
      p_valid_from: v.from ? new Date(v.from).toISOString() : null }),
    "Acting head granted.");
}

export async function revokeMembership(fd: FormData) {
  return rpcAction(z.object({ membership: uuid, reason }), obj(fd), "revoke_membership",
    (v) => ({ p_membership: v.membership, p_reason: v.reason }), "Revoked.");
}

// Float ----------------------------------------------------------------------------------------------
export async function establishInitialFloat(fd: FormData): Promise<ActionResult> {
  let den: Record<string, number>;
  try { den = denominations(fd); } catch (e) { return { ok: false, error: (e as Error).message }; }
  return rpcAction(z.object({ outlet: uuid, effective: date, retyped: rupeesToPaise("Re-typed total") }), obj(fd),
    "establish_initial_float",
    (v) => ({ p_outlet: v.outlet, p_effective_date: v.effective, p_denominations: den, p_retyped_total: v.retyped }),
    "Initial float established.");
}

export async function recordTopUp(fd: FormData) {
  return rpcAction(
    z.object({ outlet: uuid, effective: date, timing: z.enum(["pre_opening", "intraday"]), amount: rupeesToPaise("Amount"),
      source: z.enum(["owner_funds", "previous_take_home", "other"]), note: optText, reason,
      relates: z.union([uuid, z.literal("")]).optional().transform((v) => v || null) }),
    obj(fd), "record_top_up",
    (v) => ({ p_outlet: v.outlet, p_effective_date: v.effective, p_timing: v.timing, p_amount: v.amount, p_source: v.source,
      p_source_note: v.note, p_reason: v.reason, p_relates_to_revision: v.relates }),
    "Top-up recorded.");
}

export async function changeRequiredFloat(fd: FormData) {
  return rpcAction(z.object({ outlet: uuid, effective: date, amount: rupeesToPaise("Required float", true), reason }), obj(fd),
    "change_required_float",
    (v) => ({ p_outlet: v.outlet, p_effective_date: v.effective, p_new_required_float: v.amount, p_reason: v.reason }),
    "Required float changed.");
}

export async function reverseFloatMovement(fd: FormData) {
  return rpcAction(z.object({ movement: uuid, reason }), obj(fd), "reverse_float_movement",
    (v) => ({ p_movement: v.movement, p_reason: v.reason }), "Movement reversed.");
}

// Closing ---------------------------------------------------------------------------------------------
export async function prepareClosing(fd: FormData): Promise<ActionResult> {
  const r = await rpcAction(z.object({ outlet: uuid, date }), obj(fd), "prepare_closing",
    (v) => ({ p_outlet: v.outlet, p_date: v.date }));
  if (r.ok) redirect(`/closing/${fd.get("date")}`);
  return r;
}

export async function updateDraft(fd: FormData): Promise<ActionResult> {
  let den: Record<string, number>;
  try { den = denominations(fd); } catch (e) { return { ok: false, error: (e as Error).message }; }
  const opt = optionalRupeesToPaise("Amount");
  return rpcAction(
    z.object({ closing: uuid, paytm_total: opt, paytm_upi: opt, paytm_card: opt, variance_reason: optText, take_home_by: optText }),
    obj(fd), "update_draft",
    (v) => ({ p_closing: v.closing, p_paytm_total: v.paytm_total, p_paytm_upi: v.paytm_upi, p_paytm_card: v.paytm_card,
      p_denominations: den, p_variance_reason: v.variance_reason, p_take_home_by: v.take_home_by }),
    "Saved.");
}

export async function allocateFoodExcess(fd: FormData) {
  return rpcAction(z.object({ closing: uuid, reason }), obj(fd), "allocate_food_excess",
    (v) => ({ p_closing: v.closing, p_reason: v.reason }), "Food excess allocated to the shop.");
}

export async function submitClosing(fd: FormData) {
  return rpcAction(z.object({ closing: uuid }), obj(fd), "submit_closing", (v) => ({ p_closing: v.closing }),
    "Submitted for approval.");
}

export async function approveClosing(fd: FormData) {
  const acks = fd.getAll("ack").map(String);
  return rpcAction(z.object({ revision: uuid }), obj(fd), "approve_closing",
    (v) => ({ p_revision: v.revision, p_acknowledgements: acks }), "Approved.");
}

export async function rejectClosing(fd: FormData) {
  return rpcAction(z.object({ revision: uuid, reason }), obj(fd), "reject_closing",
    (v) => ({ p_revision: v.revision, p_reason: v.reason }), "Rejected.");
}

export async function reopenClosing(fd: FormData) {
  return rpcAction(z.object({ closing: uuid, reason }), obj(fd), "reopen_closing",
    (v) => ({ p_closing: v.closing, p_reason: v.reason }), "Reopened.");
}

export async function acknowledgeReview(fd: FormData) {
  return rpcAction(z.object({ closing: uuid, flag: z.string().min(1), reason }), obj(fd), "acknowledge_review",
    (v) => ({ p_closing: v.closing, p_flag: v.flag, p_note: v.reason }), "Acknowledged.");
}

export async function recordHandover(fd: FormData) {
  return rpcAction(z.object({ closing: uuid, recipient: uuid, amount: rupeesToPaise("Amount"), source: z.enum(["drawer", "outside_drawer"]) }),
    obj(fd), "record_handover",
    (v) => ({ p_closing: v.closing, p_recipient_staff: v.recipient, p_amount: v.amount, p_source: v.source }), "Handover recorded.");
}

export async function recordReturn(fd: FormData) {
  return rpcAction(z.object({ closing: uuid, amount: rupeesToPaise("Amount"), source: z.enum(["drawer", "outside_drawer"]), reason }),
    obj(fd), "record_commission_return",
    (v) => ({ p_closing: v.closing, p_amount: v.amount, p_source: v.source, p_reason: v.reason }), "Return recorded.");
}

export async function acceptOverpayment(fd: FormData) {
  return rpcAction(z.object({ closing: uuid, amount: rupeesToPaise("Amount"), reason }), obj(fd), "accept_commission_overpayment",
    (v) => ({ p_closing: v.closing, p_amount: v.amount, p_reason: v.reason }), "Overpayment accepted.");
}

// Review queues --------------------------------------------------------------------------------------
export async function reviewLateEntry(fd: FormData) {
  return rpcAction(
    z.object({ kind: z.enum(["entry", "food_payment"]), id: uuid, decision: z.enum(["include", "exclude"]),
      reason: optText, reopen_reason: optText }),
    obj(fd), "review_late_entry",
    (v) => ({ p_kind: v.kind, p_id: v.id, p_decision: v.decision, p_reason: v.reason, p_reopen_reason: v.reopen_reason }),
    "Decision recorded.");
}

export async function assignBusinessDate(fd: FormData) {
  return rpcAction(z.object({ kind: z.enum(["entry", "food_payment"]), id: uuid, date, reason }), obj(fd),
    "assign_business_date", (v) => ({ p_kind: v.kind, p_id: v.id, p_date: v.date, p_reason: v.reason }), "Date assigned.");
}

export async function resolveSyncIssue(fd: FormData) {
  return rpcAction(z.object({ id: z.coerce.number().int().positive(), reason }), obj(fd), "resolve_sync_issue",
    (v) => ({ p_sync_op: v.id, p_note: v.reason }), "Resolved.");
}

// Paytm import and recovery import ---------------------------------------------------------------------
const paytmRow = z.object({
  txn_ref: z.string().trim().min(1).max(100),
  txn_time: z.string().datetime({ offset: true }),
  amount: z.number().int().positive(),
  status: z.enum(["success", "pending", "failed", "refunded"]),
  method: z.enum(["upi", "card", "unknown"]).default("unknown"),
});

export async function importPaytm(outlet: string, rows: unknown, sourceName: string): Promise<ActionResult> {
  const parsed = z.object({ outlet: uuid, rows: z.array(paytmRow).min(1).max(5000), source: z.string().max(200) })
    .safeParse({ outlet, rows, source: sourceName });
  if (!parsed.success) return { ok: false, error: parsed.error.issues[0].message };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("import_paytm_transactions", {
    p_outlet: parsed.data.outlet, p_rows: parsed.data.rows, p_source_name: parsed.data.source,
  });
  if (error) return { ok: false, error: friendlyError(error) };
  revalidatePath("/", "layout");
  const d = data as { inserted: number; duplicates: number };
  return { ok: true, message: `Imported ${d.inserted} transaction(s); skipped ${d.duplicates} already imported.` };
}

/** Management recovery import of a "Save pending entries" file (§6.2 step 5): idempotent replay. */
export async function importRecovery(json: string): Promise<ActionResult> {
  let file: { format?: string; device_id?: string; rows?: { outlet_id: string; op: unknown }[] };
  try { file = JSON.parse(json); } catch { return { ok: false, error: "Not a valid file." }; }
  if (file.format !== "salonops-pending-v1" || !uuid.safeParse(file.device_id).success || !Array.isArray(file.rows)) {
    return { ok: false, error: "This is not a SalonOps pending-entries file." };
  }
  const supabase = await createClient();
  const byOutlet = new Map<string, unknown[]>();
  for (const r of file.rows) {
    if (!uuid.safeParse(r.outlet_id).success) return { ok: false, error: "File contains an invalid outlet." };
    byOutlet.set(r.outlet_id, [...(byOutlet.get(r.outlet_id) ?? []), r.op]);
  }
  let applied = 0, duplicates = 0, problems = 0;
  for (const [outlet, ops] of byOutlet) {
    for (let i = 0; i < ops.length; i += 200) {
      const { data, error } = await supabase.rpc("sync_ops", {
        p_outlet: outlet, p_device: file.device_id, p_device_label: "Recovery import", p_ops: ops.slice(i, i + 200),
      });
      if (error) return { ok: false, error: friendlyError(error) };
      for (const r of (data as { results: { status: string; duplicate?: boolean }[] }).results) {
        if (r.duplicate) duplicates++;
        else if (r.status === "applied") applied++;
        else problems++;
      }
    }
  }
  revalidatePath("/", "layout");
  return { ok: true, message: `Recovered ${applied} new op(s); ${duplicates} were already synced; ${problems} need review in Sync issues.` };
}
