/*
 * 頑張ろうニッポン！ Service Worker
 *
 * 【運用ルール】ゲーム本体(index.html)や音源・画像を更新してデプロイするときは、
 * 下の CACHE_VER を必ず上げること(例: 'lg-v1' → 'lg-v2')。
 * activate 時に古いバージョンのキャッシュは自動で削除される。
 *
 * キャッシュ戦略:
 *  - HTML(ナビゲーション / index.html): Network First
 *      取得できたらキャッシュを更新、オフライン時のみキャッシュを返す
 *  - 静的アセット(mp3 / png / jpg / manifest.json / アイコン / Google Fonts): Cache First
 *      mp3 の Range リクエスト(<audio> のストリーミング)は、未キャッシュならネットワークへ素通しし、
 *      裏で全体を1回だけ取得してキャッシュ。キャッシュ済みなら切り出して 206 で返す
 *  - Supabase(*.supabase.co)への通信と GET 以外: 一切介入しない(素通し)
 */
const CACHE_VER = 'lg-v1';
const CACHE = 'lg-cache-' + CACHE_VER;
const STATIC_RE = /\.(mp3|png|jpe?g|webp|gif|svg|ico)$|\/manifest\.json$/i;
const FONT_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(['./', './index.html', './manifest.json'])).catch(() => {}));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k.startsWith('lg-cache-') && k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  let url;
  try { url = new URL(req.url); } catch (_) { return; }
  if (/(^|\.)supabase\.co$/i.test(url.hostname)) return;

  const sameOrigin = url.origin === self.location.origin;
  const isHtml = req.mode === 'navigate' || (sameOrigin && (/\/$/.test(url.pathname) || /\.html$/i.test(url.pathname)));
  if (sameOrigin && isHtml) { e.respondWith(networkFirst(req)); return; }
  if (sameOrigin && STATIC_RE.test(url.pathname)) {
    if (req.headers.has('range')) { e.respondWith(rangeFromCache(req, e)); return; }
    e.respondWith(cacheFirst(req)); return;
  }
  if (FONT_HOSTS.includes(url.hostname)) { e.respondWith(cacheFirst(req)); return; }
  // それ以外は介入しない
});

async function networkFirst(req) {
  const c = await caches.open(CACHE);
  try {
    const res = await fetch(req, { cache: 'no-store' });
    if (res && res.ok) c.put(req, res.clone()).catch(() => {});
    return res;
  } catch (err) {
    const hit = await c.match(req, { ignoreSearch: true }) || await c.match('./index.html') || await c.match('./');
    if (hit) return hit;
    throw err;
  }
}

async function cacheFirst(req) {
  const c = await caches.open(CACHE);
  const hit = await c.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res && (res.ok || res.type === 'opaque')) c.put(req, res.clone()).catch(() => {});
  return res;
}

const filling = new Set();
async function rangeFromCache(req, e) {
  const c = await caches.open(CACHE);
  const full = await c.match(req.url);
  if (!full) {
    // 未キャッシュ: そのままネットワークで再生させ、裏で全体を1回だけキャッシュ
    if (!filling.has(req.url)) {
      filling.add(req.url);
      e.waitUntil(fetch(req.url).then(r => { if (r.ok && r.status === 200) return c.put(req.url, r); }).catch(() => {}).finally(() => filling.delete(req.url)));
    }
    return fetch(req);
  }
  const buf = await full.arrayBuffer();
  const m = /bytes=(\d*)-(\d*)/.exec(req.headers.get('range') || '');
  const size = buf.byteLength;
  let start = m && m[1] ? parseInt(m[1], 10) : 0;
  let end = m && m[2] ? parseInt(m[2], 10) : size - 1;
  if (m && !m[1] && m[2]) { start = Math.max(0, size - parseInt(m[2], 10)); end = size - 1; }
  if (start >= size) return new Response(null, { status: 416, headers: { 'Content-Range': 'bytes */' + size } });
  end = Math.min(end, size - 1);
  return new Response(buf.slice(start, end + 1), {
    status: 206,
    headers: {
      'Content-Type': full.headers.get('Content-Type') || 'audio/mpeg',
      'Content-Range': 'bytes ' + start + '-' + end + '/' + size,
      'Content-Length': String(end - start + 1),
      'Accept-Ranges': 'bytes'
    }
  });
}
