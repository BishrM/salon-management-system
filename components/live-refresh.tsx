"use client";
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { createBrowserClient } from "@supabase/ssr";
import type { RealtimeChannel } from "@supabase/supabase-js";

/** Live refresh when entries or closing events change (Supabase Realtime, RLS-filtered). */
export function LiveRefresh({ outletId }: { outletId: string }) {
  const router = useRouter();
  useEffect(() => {
    const supabase = createBrowserClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!);
    let timer: ReturnType<typeof setTimeout> | undefined;
    let channel: RealtimeChannel | undefined;
    let cancelled = false;
    const bump = () => {
      clearTimeout(timer);
      timer = setTimeout(() => router.refresh(), 800);
    };
    (async () => {
      // Join with the user's JWT, not the publishable key: Realtime checks RLS and column
      // privileges as the joining role, and an anon join rejects every filter on the channel.
      const { data } = await supabase.auth.getSession();
      if (cancelled || !data.session) return;
      await supabase.realtime.setAuth(data.session.access_token);
      if (cancelled) return;
      channel = supabase
        .channel(`outlet-${outletId}`)
        .on("postgres_changes", { event: "*", schema: "public", table: "entries", filter: `outlet_id=eq.${outletId}` }, bump)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "closing_events", filter: `outlet_id=eq.${outletId}` }, bump)
        .subscribe();
    })();
    // Fallback poll in case Realtime is unavailable.
    const poll = setInterval(() => router.refresh(), 60_000);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      clearInterval(poll);
      if (channel) supabase.removeChannel(channel);
    };
  }, [outletId, router]);
  return null;
}
