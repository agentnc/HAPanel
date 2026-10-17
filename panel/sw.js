// HAPanel service worker: keeps the app shell available offline.
// Live data (/hapanel/live, stats) always goes to the network and is never cached.
const CACHE = "hapanel-shell-v1";
const SHELL = ["/hapanel/", "/hapanel/manifest.webmanifest", "/hapanel/icon-192.png", "/hapanel/icon-512.png"];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(() => {}).then(() => self.skipWaiting()));
});

self.addEventListener("activate", event => {
  event.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", event => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== location.origin) return;
  if (!SHELL.includes(url.pathname)) return;           // live stream and data: straight to network
  // Network first (so updates show immediately), cached copy when offline
  event.respondWith(fetch(event.request)
    .then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(url.pathname, copy)); }
      return res;
    })
    .catch(() => caches.match(url.pathname)));
});
