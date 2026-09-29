// Minimal, conservative PWA service worker.
//
// Scope is intentionally the whole site ("/"), served from the root so it can control
// navigations to client-routed pages like /media/123 and /users/alice -- a service
// worker's scope can never exceed the directory it's served from, so this file must be
// served at the site root, not under /static/react/.
//
// It never touches API requests or cross-origin requests (media/API can live on a
// different tunnel/CDN origin than the page) — it only helps the app shell and its
// built JS/CSS/image assets load instantly and survive brief offline blips.
const CACHE_VERSION = "gallery-shell-v1";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(
      keys.filter((key) => key !== CACHE_VERSION).map((key) => caches.delete(key)),
    )).then(() => self.clients.claim()),
  );
});

// Each deploy produces new hashed filenames, so without pruning the cache
// keeps every build's bundles forever. Oldest entries go first.
const MAX_HASHED_ASSETS = 60;

function isHashedAsset(url) {
  return url.pathname.startsWith("/static/react/assets/") && !url.pathname.endsWith(".map");
}

async function pruneAssets(cache) {
  const keys = await cache.keys();
  const hashed = keys.filter((request) => isHashedAsset(new URL(request.url)));
  const excess = hashed.length - MAX_HASHED_ASSETS;
  for (let index = 0; index < excess; index += 1) {
    await cache.delete(hashed[index]);
  }
}

function isCacheableAsset(url) {
  return url.pathname.startsWith("/static/react/assets/")
    || url.pathname.startsWith("/static/react/pwa-")
    || url.pathname === "/static/react/apple-touch-icon.png"
    || url.pathname === "/favicon.ico";
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(() => caches.match("/").then((cached) => cached || Response.error())),
    );
    return;
  }

  if (isHashedAsset(url)) {
    // Content-hashed build files never change under a given name: serve
    // straight from cache and only touch the network on a miss. (This used
    // to re-download every asset in the background on every page load.)
    event.respondWith(
      caches.open(CACHE_VERSION).then(async (cache) => {
        const cached = await cache.match(request);
        if (cached) return cached;
        const response = await fetch(request);
        if (response.ok) {
          event.waitUntil(cache.put(request, response.clone()).then(() => pruneAssets(cache)));
        }
        return response;
      }),
    );
    return;
  }

  if (isCacheableAsset(url)) {
    event.respondWith(
      caches.open(CACHE_VERSION).then(async (cache) => {
        const cached = await cache.match(request);
        const networkFetch = fetch(request).then((response) => {
          if (response.ok) cache.put(request, response.clone());
          return response;
        }).catch(() => cached);
        return cached || networkFetch;
      }),
    );
  }
});
