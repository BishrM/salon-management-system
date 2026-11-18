// SalonOps service worker: cached app shell for offline use (SRS §10, Rev 6 §6).
// - Static build assets: cache-first (they are content-hashed).
// - Page navigations: network-first; on failure serve the last cached copy of that page, else offline.html.
// - API calls and non-GET requests are never cached (financial data goes through the IndexedDB outbox).
const VERSION = "salonops-v1";
const SHELL = ["/offline.html", "/icon.svg", "/manifest.webmanifest"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/api/")) return;

  if (url.pathname.startsWith("/_next/static/")) {
    e.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        if (res.ok) caches.open(VERSION).then((c) => c.put(req, res.clone()));
        return res;
      })),
    );
    return;
  }

  if (req.mode === "navigate") {
    e.respondWith(
      fetch(req)
        .then((res) => {
          // Only cache successful, non-redirected pages (never the login redirect).
          if (res.ok && !res.redirected) caches.open(VERSION).then((c) => c.put(url.pathname, res.clone()));
          return res;
        })
        .catch(() => caches.match(url.pathname).then((hit) => hit || caches.match("/offline.html"))),
    );
  }
});
