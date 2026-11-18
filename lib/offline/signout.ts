// Sign-out with unsent register ops on this device (Rev 6 §6.1). The guard exists so no sale is lost;
// it must not trap a user in an account. Ops stay in IndexedDB scoped to their user and outlet, are never
// shown, sent, exported or cleared for another account (lib/offline/outbox.ts), and sync again when
// their owner signs back in. Leaving them is only allowed when the browser has granted persistent
// storage; otherwise the browser could evict them, so sign-out stays blocked.
import type { OutboxRow } from "./outbox";

export type SignOutDecision =
  | { kind: "sign_out" }
  | { kind: "confirm"; message: string }
  | { kind: "type_to_confirm"; word: string; message: string }
  | { kind: "block"; message: string };

export function signOutDecision(rows: OutboxRow[] | null, durable: boolean): SignOutDecision {
  if (rows == null) {
    return { kind: "block", message: "This device's saved entries could not be read, so signing out could lose them. Reload the page and try again." };
  }
  const n = (s: string) => rows.filter((r) => r.status === s).length;
  const pending = n("pending");
  const problems = n("failed") + n("conflict") + n("blocked");
  if (!pending && !problems) return { kind: "sign_out" };

  const lines: string[] = [];
  if (pending) lines.push(`${pending} entr${pending === 1 ? "y has" : "ies have"} not reached the server yet.`);
  if (problems) lines.push(`${problems} change${problems === 1 ? " has" : "s have"} a sync problem (see Register → This device).`);

  if (!durable) {
    return {
      kind: "block",
      message: `${lines.join(" ")}\n\nThis browser has not granted permanent storage, so it could delete them after you sign out. ` +
        `Sync or resolve them first, or use "Save pending entries" and give the file to the manager.`,
    };
  }
  const keep = "They stay on this device for your account only: no other login can see, send or clear them, " +
    "and they continue when you sign in here again.";
  if (!problems) return { kind: "confirm", message: `${lines.join(" ")}\n\n${keep}\n\nSign out anyway?` };
  return {
    kind: "type_to_confirm",
    word: "KEEP",
    message: `${lines.join(" ")}\n\nChanges with a sync problem will NOT be sent by themselves: you (or a manager) must resolve them after signing back in. ${keep}\n\nType KEEP to sign out and keep them.`,
  };
}
