const REDIRECT_HOSTS = new Set([
  'raw.githubusercontent.com',
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
]);

function error(message, status) {
  return new Response(`${message}\n`, {
    status,
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}

export function resolveUpstream(url) {
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
    };
  }
  if (kind === 'release' && file.length === 1) {
    const releasePath = ref === 'latest' ? 'latest/download' : `download/${encode(ref)}`;
    return {
      url: `https://github.com/${base}/releases/${releasePath}/${encode(file[0])}`,
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
  async fetch(request) {
    if (!['GET', 'HEAD'].includes(request.method)) {
      const response = error('Only GET and HEAD are supported', 405);
      response.headers.set('Allow', 'GET, HEAD');
      return response;
    }
    const url = new URL(request.url);
    if (url.pathname === '/') {
      return new Response(request.method === 'HEAD' ? null : 'GitHub CDN — append the original URL:\n/https://raw.githubusercontent.com/OWNER/REPO/REF/FILE\n/https://github.com/OWNER/REPO/releases/download/TAG/ASSET\n/https://github.com/OWNER/REPO/releases/latest/download/ASSET\n', {
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }
    const target = resolveUpstream(url);
    if (!target) return error('Append an HTTPS raw.githubusercontent.com file URL or a github.com Release download URL after the Worker domain', 400);

    let upstream;
    try {
      upstream = await fetchUpstream(target.url, request);
    } catch {
      return error('Unable to fetch the GitHub upstream', 502);
    }
    const response = new Response(request.method === 'HEAD' ? null : upstream.body, upstream);
    response.headers.delete('Set-Cookie');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    // Let the downstream CDN choose its own caching policy.
    for (const name of [
      'Cache-Control', 'CDN-Cache-Control', 'Cloudflare-CDN-Cache-Control',
      'Surrogate-Control', 'Expires', 'Age', 'X-Cache', 'CF-Cache-Status',
    ]) {
      response.headers.delete(name);
    }
    return response;
  },
};
