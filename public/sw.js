// Service worker simples: rede primeiro, cache como reserva para abrir sem conexão.
const CACHE = 'oqgci-v3';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin || url.pathname.endsWith('config.js')) return;
  // Páginas e scripts do próprio site sempre conferem a versão no servidor, para cada publicação aparecer na hora.
  const fresco = e.request.mode === 'navigate' || /\.(html|js|webmanifest)$/.test(url.pathname) || url.pathname.endsWith('/');
  e.respondWith((fresco ? fetch(e.request.url, { cache: 'no-cache', credentials: 'same-origin' }).then(r => r.redirected ? fetch(e.request) : r) : fetch(e.request)).then(r => { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r; }).catch(() => caches.match(e.request).then(m => m || caches.match('./index.html'))));
});
