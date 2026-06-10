// pastehtml.dev service worker.
//
// Deliberately minimal: Turbo Drive already gives the app SPA-like navigation,
// so this worker only does what a cache-everything strategy would get wrong.
//
//   - Navigations  -> network-first, falling back to a cached offline page.
//   - /assets/*    -> cache-first (Propshaft fingerprints these, so they are
//                     immutable and safe to cache forever).
//   - Everything else is left to the network. Paste pages are never cached:
//     a stale paste is worse than an honest offline page.
//
// Bump VERSION whenever the precache list or caching logic changes; the
// activate handler purges every cache that does not match, which keeps users
// from getting stuck on a stale worker.

const VERSION = 'v1'
const CACHE_NAME = `pastehtml-${VERSION}`
const OFFLINE_URL = '/offline.html'

// Only what the offline page actually needs. Bump VERSION above whenever
// this list changes.
const PRECACHE_URLS = [OFFLINE_URL, '/icon.svg']

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(
        // `cache: 'reload'` bypasses the HTTP cache so bumping VERSION truly re-pulls
        // these unversioned files (production serves public/ with a 1-year header).
        PRECACHE_URLS.map(async (url) => {
          const response = await fetch(url, { cache: 'reload' })
          if (!response.ok) throw new Error(`Precache failed (${response.status}): ${url}`)
          await cache.put(url, response)
        })
      )
    )
  )
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  )
})

self.addEventListener('fetch', (event) => {
  const { request } = event

  // Only ever touch same-origin GETs; let the network handle the rest.
  if (request.method !== 'GET' || new URL(request.url).origin !== self.location.origin) {
    return
  }

  // Page navigations: try the network, fall back to the offline page.
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).catch(() => caches.match(OFFLINE_URL)))
    return
  }

  // Fingerprinted, immutable assets: serve from cache, populate on first miss.
  if (new URL(request.url).pathname.startsWith('/assets/')) {
    event.respondWith(
      caches.match(request).then((cached) => {
        if (cached) return cached

        return fetch(request).then((response) => {
          if (response.ok) {
            const copy = response.clone()
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy))
          }
          return response
        })
      })
    )
  }
})
