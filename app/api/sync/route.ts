import { NextResponse } from "next/server";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { friendlyError } from "@/lib/labels";

// Single write path for register data (online and offline). The database re-validates every op,
// enforces permissions, idempotency and conflicts; this layer only checks shape and size.
const op = z.object({
  op_id: z.string().uuid(),
  device_seq: z.number().int().positive(),
  type: z.enum(["create_entry", "correct_entry", "void_entry", "food_payment", "reverse_food_payment"]),
  record_id: z.string().uuid(),
  base_version: z.number().int().positive().optional(),
  reason: z.string().max(500).optional(),
  device_time: z.string().datetime({ offset: true }),
  device_offset_ms: z.number().int().nullable(),
  device_last_sync_at: z.string().datetime({ offset: true }).nullable(),
  data: z.record(z.string(), z.unknown()),
});
const body = z.object({
  outlet_id: z.string().uuid(),
  device_id: z.string().uuid(),
  device_label: z.string().max(80).optional(),
  ops: z.array(op).max(200),
});

export async function POST(req: Request) {
  const parsed = body.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return NextResponse.json({ error: "Invalid sync request" }, { status: 400 });
  const supabase = await createClient();
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) return NextResponse.json({ error: "Signed out — sign in again to sync" }, { status: 401 });
  const { outlet_id, device_id, device_label, ops } = parsed.data;
  const { data, error } = await supabase.rpc("sync_ops", {
    p_outlet: outlet_id,
    p_device: device_id,
    p_device_label: device_label ?? null,
    p_ops: ops,
  });
  if (error) return NextResponse.json({ error: friendlyError(error) }, { status: error.code === "42501" ? 403 : 400 });
  return NextResponse.json(data);
}
