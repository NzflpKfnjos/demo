const REDIRECT_HOSTS = new Set([
  'raw.githubusercontent.com',
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
]);

function error(message, status) {
  return new Response(`${message}\n`, {
    status,
    headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' },
  });
}

function ttl(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? Math.min(number, 31536000) : fallback;
}

export function resolveUpstream(url, env = {}) {
  let path = url.pathname;
  // Accept a complete GitHub download URL appended after the Worker origin.
  if (path.startsWith('/https://')) {
    const raw = path.match(/^\/https:\/\/raw\.githubusercontent\.com\/(.+)$/);
    const release = path.match(/^\/https:\/\/github\.com\/([^/]+)\/([^/]+)\/releases\/(?:download\/([^/]+)|latest\/(download))\/([^/]+)$/);
    if (raw) path = `/raw/${raw[1]}`;
    else if (release) path = `/release/${release[1]}/${release[2]}/${release[3] || 'latest'}/${release[5]}`;
    else return null;
  }
  const parts = path.split('/').slice(1);
  let decoded;
  try {
    decoded = parts.map(decodeURIComponent);
  } catch {
    return null;
  }
  // Reject encoded separators and control characters before building an upstream URL.
  if (decoded.some(part => !part || /[/\\\u0000-\u001f\u007f]/u.test(part) || part === '.' || part === '..')) return null;
  const [kind, owner, repo, ref, ...file] = decoded;
  if (!/^[a-z\d-]+$/i.test(owner || '') || !/^[\w.-]+$/.test(repo || '') || !ref || !file.length) return null;
  const encode = value => encodeURIComponent(value);
  const base = `${encode(owner)}/${encode(repo)}`;
  if (kind === 'raw') {
    return {
      url: `https://raw.githubusercontent.com/${base}/${encode(ref)}/${file.map(encode).join('/')}`,
      ttl: ttl(env.RAW_CACHE_TTL, 3600),
    };
  }
  if (kind === 'release' && file.length === 1) {
    const releasePath = ref === 'latest' ? 'latest/download' : `download/${encode(ref)}`;
    return {
      url: `https://github.com/${base}/releases/${releasePath}/${encode(file[0])}`,
      ttl: ttl(env.RELEASE_CACHE_TTL, 86400),
    };
  }
  return null;
}

async function fetchUpstream(url, request) {
  const headers = new Headers({ 'User-Agent': 'github-cdn-worker', 'Accept': '*/*' });
  // Never forward user credentials or cookies to GitHub.
  for (const name of ['Range', 'If-Range']) {
    if (request.headers.has(name)) headers.set(name, request.headers.get(name));
  }
  for (let redirects = 0; redirects <= 5; redirects++) {
    const response = await fetch(url, { method: request.method, headers, redirect: 'manual' });
    if (![301, 302, 303, 307, 308].includes(response.status)) return response;
    const location = response.headers.get('Location');
    await response.body?.cancel();
    if (!location) throw new Error('Missing redirect location');
    const next = new URL(location, url);
    if (next.protocol !== 'https:' || next.port || next.username || next.password || !REDIRECT_HOSTS.has(next.hostname)) {
      throw new Error('Blocked upstream redirect');
    }
    url = next.href;
  }
  throw new Error('Too many upstream redirects');
}

export default {
  async fetch(request, env, ctx) {
    if (!['GET', 'HEAD'].includes(request.method)) {
      const response = error('Only GET and HEAD are supported', 405);
      response.headers.set('Allow', 'GET, HEAD');
      return response;
    }
    const url = new URL(request.url);
    if (url.pathname === '/') {
      return new Response(request.method === 'HEAD' ? null : 'GitHub CDN — append the original URL:\n/https://raw.githubusercontent.com/OWNER/REPO/REF/FILE\n/https://github.com/OWNER/REPO/releases/download/TAG/ASSET\n/https://github.com/OWNER/REPO/releases/latest/download/ASSET\n', {
        headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
      });
    }
    const target = resolveUpstream(url, env);
    if (!target) return error('Append an HTTPS raw.githubusercontent.com file URL or a github.com Release download URL after the Worker domain', 400);

    // Query parameters are not forwarded and do not create duplicate cache entries.
    url.search = '';
    const key = new Request(url.href, { method: 'GET' });
    const ranged = request.headers.has('Range');
    const cache = caches.default;
    if (!ranged) {
      try {
        const cached = await cache.match(key);
        if (cached) {
          const response = new Response(request.method === 'HEAD' ? null : cached.body, cached);
          response.headers.set('X-Cache', 'HIT');
          return response;
        }
      } catch {
        // Cache availability must not prevent downloads.
      }
    }

    let upstream;
    try {
      upstream = await fetchUpstream(target.url, request);
    } catch {
      return error('Unable to fetch the GitHub upstream', 502);
    }
    const response = new Response(request.method === 'HEAD' ? null : upstream.body, upstream);
    response.headers.delete('Set-Cookie');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('X-Cache', ranged || request.method === 'HEAD' ? 'BYPASS' : 'MISS');
    if (upstream.status === 200 && !ranged) {
      response.headers.set('Cache-Control', `public, max-age=${Math.min(target.ttl, 300)}, s-maxage=${target.ttl}`);
      if (request.method === 'GET') {
        ctx.waitUntil(cache.put(key, response.clone()).catch(() => {}));
      }
    } else {
      response.headers.set('Cache-Control', 'no-store');
    }
    return response;
  },
};
