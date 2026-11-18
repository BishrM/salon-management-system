import "server-only";
import { revalidatePath } from "next/cache";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { friendlyError } from "@/lib/labels";

export type ActionResult<T = unknown> = { ok: true; data?: T; message?: string } | { ok: false; error: string };

/**
 * Validate with Zod, call one RPC as the signed-in user, revalidate the app.
 * The RPC re-checks permission and validates again in the database (defence in depth).
 */
export async function rpcAction<S extends z.ZodTypeAny>(
  schema: S,
  input: unknown,
  rpc: string,
  toArgs: (v: z.infer<S>) => Record<string, unknown>,
  message?: string,
): Promise<ActionResult> {
  const parsed = schema.safeParse(input);
  if (!parsed.success) {
    return { ok: false, error: parsed.error.issues.map((i) => i.message).join("; ") };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(rpc, toArgs(parsed.data));
  if (error) return { ok: false, error: friendlyError(error) };
  revalidatePath("/", "layout");
  return { ok: true, data, message };
}

// Shared field schemas -----------------------------------------------------------------------------
export const uuid = z.string().uuid("Invalid id");
/** An id that may be blank or absent (e.g. "new record" forms that omit the field) → null. */
export const optionalUuid = z.union([uuid, z.literal("")]).optional().transform((v) => v || null);
export const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Invalid date");
export const reason = z.string().trim().min(1, "A reason is required").max(500, "Reason is too long");
/** Whole rupees from a form, converted to paise. */
export const rupeesToPaise = (label: string, allowZero = false) =>
  z.coerce
    .number({ message: `${label} must be a number` })
    .int(`${label} must be whole rupees`)
    .min(allowZero ? 0 : 1, `${label} must be ${allowZero ? "0 or more" : "more than 0"}`)
    .max(100_000_000, `${label} is too large`)
    .transform((r) => r * 100);

/** Optional rupee field: blank → null (not entered). "" must be matched before the coercing
 *  branch, because z.coerce.number("") is 0 and would turn "not entered" into ₹0. */
export const optionalRupeesToPaise = (label: string) =>
  z.union([z.literal(""), rupeesToPaise(label, true)]).optional().transform((v) => (v === "" || v === undefined ? null : v));
