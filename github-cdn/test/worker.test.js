import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import worker, { resolveUpstream } from '../src/worker.js';

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

function harness() {
  return {
    run(path, options) {
      return worker.fetch(new Request(`https://cdn.example${path}`, options));
    },
  };
}

test('routes Raw, tagged releases and latest releases to fixed upstreams', () => {
  const resolve = path => resolveUpstream(new URL(`https://cdn.example${path}`));
  assert.equal(resolve('/raw/NzflpKfnjos/demo/main/README.md').url, 'https://raw.githubusercontent.com/NzflpKfnjos/demo/main/README.md');
  assert.equal(resolve('/release/owner/repo/v1.0/app.zip').url, 'https://github.com/owner/repo/releases/download/v1.0/app.zip');
  assert.equal(resolve('/release/owner/repo/latest/app.zip').url, 'https://github.com/owner/repo/releases/latest/download/app.zip');
  for (const path of ['/https://evil.example/a', '/raw/a/b/main/a%2Fb', '/raw/a/b/main/%5cfoo', '/raw/a/b/main/%00', '/raw/a/b/main/%ZZ', '/release/a/b/v1/a/b']) {
    assert.equal(resolve(path), null, path);
  }
});

test('accepts original direct links and rejects other URL forms', () => {
  for (const upstream of [
    'https://raw.githubusercontent.com/NzflpKfnjos/demo/main/README.md',
    'https://github.com/owner/repo/releases/download/v1.0/app%20arm.zip',
    'https://github.com/owner/repo/releases/latest/download/app.zip',
  ]) {
    assert.equal(resolveUpstream(new URL(`https://cdn.example/${upstream}`)).url, upstream);
  }
  for (const upstream of [
    'http://raw.githubusercontent.com/a/b/main/file',
    'https://raw.githubusercontent.com.evil.example/a/b/main/file',
    'https://raw.githubusercontent.com@evil.example/a/b/main/file',
    'https://github.com/a/b/blob/main/file',
    'https://github.com/a/b/releases/download/v1/file%2Fother',
    'https://evil.example/a/b/main/file',
  ]) {
    assert.equal(resolveUpstream(new URL(`https://cdn.example/${upstream}`)), null, upstream);
  }
});

test('proxies every request without cache policy and preserves file metadata', async () => {
  const h = harness();
  let calls = 0;
  const cacheHeaders = ['Cache-Control', 'CDN-Cache-Control', 'Cloudflare-CDN-Cache-Control', 'Surrogate-Control', 'Expires', 'Age', 'X-Cache', 'CF-Cache-Status'];
  globalThis.fetch = async (url, options) => {
    calls++;
    assert.equal(url, 'https://raw.githubusercontent.com/a/b/main/file');
    const headers = new Headers(cacheHeaders.map(name => [name, 'upstream-value']));
    headers.set('Set-Cookie', 'secret=1');
    headers.set('ETag', '"file-version"');
    headers.set('Last-Modified', 'Tue, 03 Nov 2026 00:00:00 GMT');
    return new Response(options.method === 'HEAD' ? null : 'file', { headers });
  };
  for (const method of ['GET', 'GET', 'HEAD']) {
    const response = await h.run('/https://raw.githubusercontent.com/a/b/main/file?ignored=1', { method });
    for (const name of cacheHeaders) assert.equal(response.headers.get(name), null, name);
    assert.equal(response.headers.get('Set-Cookie'), null);
    assert.equal(response.headers.get('ETag'), '"file-version"');
    assert.equal(response.headers.get('Last-Modified'), 'Tue, 03 Nov 2026 00:00:00 GMT');
    assert.equal(await response.text(), method === 'HEAD' ? '' : 'file');
  }
  assert.equal(calls, 3);
});

test('follows allowed release redirects without forwarding credentials', async () => {
  const h = harness();
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return calls.length === 1
      ? new Response(null, { status: 302, headers: { Location: 'https://release-assets.githubusercontent.com/file?signature=abc' } })
      : new Response('archive');
  };
  const result = await h.run('/release/a/b/v1/app.zip', { headers: { Authorization: 'Bearer secret', Cookie: 'session=secret' } });
  assert.equal(await result.text(), 'archive');
  assert.equal(calls.length, 2);
  assert.equal(calls[1].options.headers.has('Authorization'), false);
  assert.equal(calls[1].options.headers.has('Cookie'), false);
});

test('blocks external redirects and returns errors without cache policy', async () => {
  const h = harness();
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return new Response(null, { status: 302, headers: { Location: 'https://evil.example/file' } });
  };
  assert.equal((await h.run('/release/a/b/v1/app.zip')).status, 502);
  assert.equal(calls, 1);
  globalThis.fetch = async () => new Response('missing', { status: 404 });
  const missing = await h.run('/raw/a/b/main/missing');
  assert.equal(missing.status, 404);
  assert.equal(missing.headers.get('Cache-Control'), null);
});

test('range requests preserve partial response headers', async () => {
  const h = harness();
  globalThis.fetch = async (url, options) => {
    assert.equal(options.headers.get('Range'), 'bytes=0-3');
    return new Response('part', { status: 206, headers: { 'Content-Range': 'bytes 0-3/100' } });
  };
  const response = await h.run('/release/a/b/v1/app.zip', { headers: { Range: 'bytes=0-3' } });
  assert.equal(response.status, 206);
  assert.equal(response.headers.get('X-Cache'), null);
  assert.equal(response.headers.get('Content-Range'), 'bytes 0-3/100');
  assert.equal((await h.run('/raw/a/b/main/file', { method: 'POST' })).status, 405);
});
