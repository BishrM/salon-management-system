"use client";
import { useTransition } from "react";
import { signOut } from "@/app/(app)/actions";
import { listOps, storageIsDurable } from "@/lib/offline/outbox";
import { signOutDecision } from "@/lib/offline/signout";

/**
 * Sign-out keeps unsent ops safe (Rev 6 §6.1): fully synced → sign out; pending → warn; problems → typed
 * confirmation; if the queue cannot be kept safely on this device → blocked with the reason.
 */
export function SignOutButton({ userId }: { userId: string }) {
  const [pending, start] = useTransition();
  return (
    <button
      disabled={pending}
      className="min-h-9 rounded-md px-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
      onClick={async () => {
        const rows = await listOps(userId).catch(() => null);
        const d = signOutDecision(rows, rows?.some((r) => r.status !== "synced") ? await storageIsDurable() : true);
        if (d.kind === "block") return window.alert(d.message);
        if (d.kind === "confirm" && !window.confirm(d.message)) return;
        if (d.kind === "type_to_confirm" && window.prompt(d.message)?.trim().toUpperCase() !== d.word) return;
        // Cached pages may contain this user's data: clear them on sign-out (shared tablets). The IndexedDB
        // queue is kept: its rows are scoped to this user and never used by another account.
        await caches?.keys().then((keys) => Promise.all(keys.map((k) => caches.delete(k)))).catch(() => {});
        start(() => signOut());
      }}
    >
      Sign out
    </button>
  );
}
