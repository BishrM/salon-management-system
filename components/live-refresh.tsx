"use client";
import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { createBrowserClient } from "@supabase/ssr";
import type { RealtimeChannel } from "@supabase/supabase-js";

/**
 * Live refresh when entries, closing events or employees change (Supabase Realtime, RLS-filtered: a session only
 * hears about rows it can already read). The server re-renders the page, so what is shown is always fresh data,
 * never the event payload. supabase-js re-joins after a dropped connection and renews the token itself.
 */
export function LiveRefresh({ outletId }: { outletId: string }) {
  const router = useRouter();
  useEffect(() => {
    const supabase = createBrowserClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!);
    let timer: ReturnType<typeof setTimeout> | undefined;
    let channel: RealtimeChannel | undefined;
    let cancelled = false;
    let joined = false;
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
      const topic = `outlet-${outletId}`;
      // The browser client is shared and channel() returns an existing channel of the same topic, which cannot
      // take new listeners once joined: drop any leftover so there is exactly one subscription.
      for (const c of supabase.getChannels()) if (c.topic === `realtime:${topic}`) await supabase.removeChannel(c);
      if (cancelled) return;
      channel = supabase
        .channel(topic)
        .on("postgres_changes", { event: "*", schema: "public", table: "entries", filter: `outlet_id=eq.${outletId}` }, bump)
        .on("postgres_changes", { event: "INSERT", schema: "public", table: "closing_events", filter: `outlet_id=eq.${outletId}` }, bump)
        // Employees: staff rows have no outlet column and the Owner's list spans outlets, so no filter; RLS limits it.
        .on("postgres_changes", { event: "*", schema: "public", table: "staff" }, bump)
        .on("postgres_changes", { event: "*", schema: "public", table: "staff_assignments" }, bump)
        .on("postgres_changes", { event: "*", schema: "public", table: "staff_day_visibility", filter: `outlet_id=eq.${outletId}` }, bump)
        .subscribe((status) => {
          if (status !== "SUBSCRIBED") return;
          if (joined) bump();   // re-joined after a drop: catch up on anything missed meanwhile
          joined = true;
        });
    })();
    // Back online or back on the tab: catch up. Fallback poll in case Realtime is unavailable.
    const wake = () => { if (document.visibilityState === "visible") bump(); };
    window.addEventListener("online", wake);
    document.addEventListener("visibilitychange", wake);
    const poll = setInterval(() => router.refresh(), 60_000);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      clearInterval(poll);
      window.removeEventListener("online", wake);
      document.removeEventListener("visibilitychange", wake);
      if (channel) supabase.removeChannel(channel);
    };
  }, [outletId, router]);
  return null;
}
