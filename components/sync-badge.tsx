"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { syncNow, measureClock, type SyncSummary } from "@/lib/offline/sync";

/** Header badge: online/offline, pending count; syncs on load, on reconnect and every 30 s. */
export function SyncBadge({ userId }: { userId: string }) {
  const [online, setOnline] = useState(true);
  const [s, setS] = useState<SyncSummary | null>(null);
  const router = useRouter();

  useEffect(() => {
    let alive = true;
    const run = async () => {
      setOnline(navigator.onLine);
      const before = s?.pending ?? 0;
      const r = await syncNow(userId);
      if (!alive) return;
      setS(r);
      if (before > r.pending) router.refresh();
    };
    measureClock().finally(run);
    const onUp = () => run();
    const onDown = () => setOnline(false);
    const onQueued = () => run();
    window.addEventListener("online", onUp);
    window.addEventListener("offline", onDown);
    window.addEventListener("salonops:queued", onQueued);
    const t = setInterval(run, 30_000);
    return () => {
      alive = false;
      clearInterval(t);
      window.removeEventListener("online", onUp);
      window.removeEventListener("offline", onDown);
      window.removeEventListener("salonops:queued", onQueued);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId]);

  const issues = (s?.failed ?? 0) + (s?.conflict ?? 0) + (s?.blocked ?? 0);
  const text = !online ? `Offline · ${s?.pending ?? 0} waiting` : s?.pending ? `Syncing ${s.pending}…` : issues ? `${issues} sync issue(s)` : "Synced";
  const tone = !online ? "bg-amber-100 text-amber-900" : issues ? "bg-rose-100 text-rose-900" : s?.pending ? "bg-sky-100 text-sky-900" : "bg-emerald-100 text-emerald-900";
  return (
    <a href="/register#sync" className={`rounded-full px-2.5 py-1 text-xs font-semibold ${tone}`} aria-live="polite">
      {text}
    </a>
  );
}
