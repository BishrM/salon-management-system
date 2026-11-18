"use client";
import { useEffect } from "react";

/** Registers /sw.js (cached app shell for offline use, SRS §10). */
export function ServiceWorker() {
  useEffect(() => {
    if ("serviceWorker" in navigator && process.env.NODE_ENV === "production") {
      navigator.serviceWorker.register("/sw.js").catch(() => {});
      // Ask the browser not to evict our IndexedDB outbox under storage pressure (§6.2).
      navigator.storage?.persist?.().catch(() => {});
    }
  }, []);
  return null;
}
