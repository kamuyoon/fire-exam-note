// 소방 기출노트 오프라인 캐시
// 앱 본체·데이터: 네트워크 우선(업데이트 즉시 반영), 실패 시 캐시
// 문제 이미지·아이콘·폰트: 캐시 우선
const CACHE = 'fx-v23';
const SHELL = ['./', './index.html', './config.js', './manifest.json', './icon-192.png', './icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return; // 서버 요청(로그인·문제·이미지)은 캐시하지 않음
  const cacheFirst = /\/images\/|\.png$|pretendard/.test(url.href);
  if (cacheFirst) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(res => {
      if (res.ok || res.type === 'opaque') { const cp = res.clone(); caches.open(CACHE).then(c => c.put(req, cp)); }
      return res;
    })));
    return;
  }
  e.respondWith(fetch(req).then(res => {
    if (res.ok && url.origin === location.origin) { const cp = res.clone(); caches.open(CACHE).then(c => c.put(req, cp)); }
    return res;
  }).catch(() => caches.match(req).then(hit => hit || caches.match('./index.html'))));
});
