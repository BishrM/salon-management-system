"use client";
import { useTransition } from "react";
import { signOut } from "@/app/(app)/actions";
import { listOps } from "@/lib/offline/outbox";

/** Sign-out is blocked while this user has unsynced entries on this device (Rev 6 §6.1). */
export function SignOutButton({ userId }: { userId: string }) {
  const [pending, start] = useTransition();
  return (
    <button
      disabled={pending}
      className="min-h-9 rounded-md px-2 text-sm font-medium text-slate-700 hover:bg-slate-100"
      onClick={async () => {
        const waiting = (await listOps().catch(() => [])).filter((r) => r.user_id === userId && r.status === "pending").length;
        if (waiting) {
          window.alert(`${waiting} entr${waiting === 1 ? "y has" : "ies have"} not reached the server yet. Connect to the internet and wait for "Synced" before signing out.`);
          return;
        }
        // Cached pages may contain this user's data: clear them on sign-out (shared tablets).
        await caches?.keys().then((keys) => Promise.all(keys.map((k) => caches.delete(k)))).catch(() => {});
        start(() => signOut());
      }}
    >
      Sign out
    </button>
  );
}
