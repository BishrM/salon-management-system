import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Database clock (the clock that dates entries), for device offset tracking (Rev 6 §6.3).
export async function GET() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("server_time");
  if (error) return NextResponse.json({ error: "unavailable" }, { status: 503 });
  return NextResponse.json({ server_time: data }, { headers: { "cache-control": "no-store" } });
}
