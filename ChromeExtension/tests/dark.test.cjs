const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const theme = (mode) => ({ mode, from: 1140, to: 420, brightness: 100, contrast: 100 });
const deferred = () => { let resolve; const promise = new Promise((r) => { resolve = r; }); return { promise, resolve }; };
const settle = async () => { for (let i = 0; i < 10; i++) await new Promise(setImmediate); };

function worker(fetcher) {
  const local = { dark: theme('night'), darkAppRevision: 'r0' };
  const session = {};
  const area = (data) => ({
    get: async (keys) => { if (typeof keys === 'string') keys = [keys]; return structuredClone(Object.fromEntries(keys.map((k) => [k, data[k]]))); },
    set: async (patch) => Object.assign(data, structuredClone(patch)),
  });
  const event = () => ({ addListener() {} });
  const context = vm.createContext({ console, URL, Date, crypto: require('node:crypto').webcrypto, AbortSignal, Response,
    setTimeout: () => 0, clearTimeout() {}, fetch: fetcher || (() => new Promise(() => {})),
    chrome: {
      runtime: { getURL: (p) => 'chrome-extension://test/' + p, onMessage: event(), onInstalled: event(), onStartup: event() },
      storage: { local: area(local), session: area(session) },
      scripting: { getRegisteredContentScripts: async () => [{ id: 'dark' }], registerContentScripts: async () => {}, unregisterContentScripts: async () => {} },
      tabs: { query: async () => [], onActivated: event(), onUpdated: event() },
      windows: { onFocusChanged: event() }, idle: { setDetectionInterval() {}, onStateChanged: event() },
      alarms: { get: (_n, fn) => fn ? fn({}) : Promise.resolve({}), create: async () => {}, clear: async () => {}, onAlarm: event() }, webNavigation: { onBeforeNavigate: event() },
    },
  });
  context.importScripts = (file) => vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(root, 'background.js'), 'utf8'), context);
  return { context, local, session, run: (s) => vm.runInContext(s, context) };
}

test('mode changes do not wait behind an unresponsive event upload', async () => {
  const w = worker();
  w.local.queue = [{ eid: 'event' }];
  w.run('flush()');
  await w.run("setDark({mode:'always',from:1140,to:420,brightness:100,contrast:100})");
  assert.equal(w.local.dark.mode, 'always');
});

test('a second edit in flight inherits our acknowledged native revision', async () => {
  const posts = [];
  const w = worker((url, options) => {
    if (!url.endsWith('/dark')) return new Promise(() => {});
    const reply = deferred(); posts.push({ body: JSON.parse(options.body), reply }); return reply.promise;
  });
  await w.run(`setDark(${JSON.stringify(theme('always'))})`); await settle();
  await w.run(`setDark(${JSON.stringify(theme('off'))})`); await settle();
  assert.equal(posts.length, 1);
  posts[0].reply.resolve(Response.json({ dark: theme('always'), revision: 'r1' })); await settle();
  assert.equal(posts.length, 2);
  assert.equal(posts[1].body.mode, 'off');
  assert.equal(posts[1].body.baseRevision, 'r1');
  posts[1].reply.resolve(Response.json({ dark: theme('off'), revision: 'r2' })); await settle();
  assert.equal(w.local.dark.mode, 'off'); assert.equal(w.local.darkPending, false);
});

test('newer Mac changes reject a stale offline popup edit', async () => {
  const w = worker((url) => url.endsWith('/dark') ? Promise.resolve(Response.json({ dark: theme('system'), revision: 'new-mac' }, { status: 409 })) : new Promise(() => {}));
  await w.run(`setDark(${JSON.stringify(theme('always'))})`); await settle();
  assert.equal(w.local.dark.mode, 'system'); assert.equal(w.local.darkPending, false);
});

test('live Mac update reaches storage without a popup or periodic alarm', async () => {
  const reply = deferred(); let first = true;
  const w = worker((url) => {
    if (url.includes('/dark?since=') && first) { first = false; return reply.promise; }
    return new Promise(() => {});
  });
  reply.resolve(Response.json({ dark: theme('always'), revision: 'native-update' })); await settle();
  assert.equal(w.local.dark.mode, 'always'); assert.equal(w.local.darkAppRevision, 'native-update');
});

test('a state request started before a popup edit cannot overwrite it', async () => {
  const w = worker(); w.local.darkEditedAt = Date.now() + 100;
  await w.run(`takeAppDark(${JSON.stringify(theme('off'))}, 0)`);
  assert.equal(w.local.dark.mode, 'night');
});

test('bundled fixes select domains and exact paths without leaking to unrelated sites', async () => {
  const w = worker();
  assert.equal(w.run("darkURLMatches(new URL('https://evilgithub.com'), 'github.com')"), false);
  assert.equal(w.run("darkURLMatches(new URL('https://www.github.com/issues'), 'github.com')"), true);
  assert.equal(w.run("darkURLMatches(new URL('https://sub.github.com'), 'github.com')"), false);
  assert.equal(w.run("darkURLMatches(new URL('https://sub.github.com'), '*.github.com')"), true);
  assert.equal(w.run("darkURLMatches(new URL('https://example.com/foo/bar'), 'example.com/foo$')"), false);
  const data = JSON.parse(fs.readFileSync(path.join(root, 'vendor/darkreader-fixes.json'), 'utf8'));
  assert.ok(data.length > 2900); assert.deepEqual(data[0].url, ['*']);
  w.context.fixtureFixes = data; w.run('darkFixesData = Promise.resolve(fixtureFixes)');
  const global = await w.run("darkFixesFor('https://focus-dark.test')");
  const github = await w.run("darkFixesFor('https://github.com/darkreader/darkreader')");
  assert.ok(global.css.includes('--darkreader-neutral-text'));
  assert.ok(github.css.length > global.css.length);
});

test('optional resource failures are deduplicated and cool down before retrying', async () => {
  let requests = 0;
  const w = worker((url) => {
    if (url === 'https://assets.test/missing.gif') { requests++; return Promise.resolve(new Response('', { status: 404 })); }
    return new Promise(() => {});
  });
  const results = await w.run("Promise.all([darkFetch('https://assets.test/missing.gif'), darkFetch('https://assets.test/missing.gif')])");
  assert.equal(results[0].ok, false); assert.equal(results[1].ok, false);
  await w.run("darkFetch('https://assets.test/missing.gif')");
  assert.equal(requests, 1);
});

test('MV3 proxy runs as a packaged MAIN script instead of an inline DOM script', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
  const proxy = manifest.content_scripts.find((s) => s.js.includes('vendor/darkreader-proxy.js'));
  assert.equal(proxy.world, 'MAIN'); assert.equal(proxy.run_at, 'document_start');
  const source = fs.readFileSync(path.join(root, 'vendor/darkreader.js'), 'utf8');
  assert.ok(source.includes('__focus_darkreader_proxy'));
  assert.ok(!source.includes('proxyScript.append('));
});
