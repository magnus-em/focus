const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');

function worker() {
  const local = { dark: { mode: 'off', from: 1140, to: 420, brightness: 100, contrast: 100 } };
  const session = {};
  const sent = [];
  const tabs = [
    { id: 7, url: 'https://www.youtube.com/' },
    { id: 8, url: 'https://m.youtube.com/watch?v=lesson' },
  ];
  const area = (data) => ({
    get: async (keys) => {
      if (typeof keys === 'string') keys = [keys];
      return structuredClone(Object.fromEntries(keys.map((key) => [key, data[key]])));
    },
    set: async (patch) => Object.assign(data, structuredClone(patch)),
  });
  const event = () => ({ addListener() {} });
  const context = vm.createContext({
    console,
    URL,
    Date,
    crypto: require('node:crypto').webcrypto,
    AbortSignal,
    Response,
    TextDecoder,
    btoa: (value) => Buffer.from(value, 'binary').toString('base64'),
    setTimeout: () => 0,
    clearTimeout() {},
    fetch: () => new Promise(() => {}),
    chrome: {
      runtime: { getURL: (value) => 'chrome-extension://test/' + value, onMessage: event(), onInstalled: event(), onStartup: event() },
      storage: { local: area(local), session: area(session) },
      scripting: { getRegisteredContentScripts: async () => [], registerContentScripts: async () => {}, unregisterContentScripts: async () => {} },
      tabs: {
        query: async ({ url } = {}) => url ? tabs : [],
        sendMessage: async (id, message) => sent.push({ id, message }),
        onActivated: event(),
        onUpdated: event(),
      },
      declarativeNetRequest: { getDynamicRules: async () => [], updateDynamicRules: async () => {} },
      windows: { onFocusChanged: event() },
      idle: { setDetectionInterval() {}, onStateChanged: event() },
      alarms: { get: (_name, reply) => reply ? reply(null) : Promise.resolve(null), create: async () => {}, clear: async () => {}, onAlarm: event() },
      webNavigation: { onBeforeNavigate: event() },
    },
  });
  context.importScripts = (file) => vm.runInContext(fs.readFileSync(path.join(root, file), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(root, 'background.js'), 'utf8'), context);
  return { local, session, sent, run: (source) => vm.runInContext(source, context) };
}

test('YouTube settings use focus-safe defaults and ignore malformed values', () => {
  const w = worker();
  const settings = w.run("normalizeYouTube({mode:'sometimes', hideHome:false, hideRelated:'no', hideComments:true})");
  assert.deepEqual(structuredClone(settings), {
    mode: 'focus',
    hideHome: false,
    hideRelated: true,
    hideShorts: true,
    hideEndScreens: true,
    disableAutoplay: true,
    hideComments: true,
  });
});

test('During focus follows isFocus, while Off and Always are explicit', () => {
  const w = worker();
  assert.equal(w.run("isYouTubeActive({mode:'focus'}, {isFocus:true, blocking:false})"), true);
  assert.equal(w.run("isYouTubeActive({mode:'focus'}, {isFocus:false, blocking:true})"), false);
  assert.equal(w.run("isYouTubeActive({mode:'focus'}, {blocking:true})"), true);
  assert.equal(w.run("isYouTubeActive({mode:'off'}, {isFocus:true})"), false);
  assert.equal(w.run("isYouTubeActive({mode:'always'}, {isFocus:false})"), true);
});

test('saving settings persists them and updates every open YouTube tab', async () => {
  const w = worker();
  w.session.state = { isFocus: true, blocking: false };
  const result = await w.run("setYouTube({mode:'focus', hideHome:true, hideRelated:false, hideShorts:true, hideEndScreens:true, disableAutoplay:true, hideComments:true})");
  assert.equal(result.active, true);
  assert.equal(w.local.youtubeFocus.hideRelated, false);
  assert.equal(w.sent.length, 2);
  assert.deepEqual(w.sent.map(({ id }) => id), [7, 8]);
  assert.ok(w.sent.every(({ message }) => message.type === 'youtubeFocusChanged' && message.active));
});

test('manifest installs the YouTube guard at document start', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
  const script = manifest.content_scripts.find((entry) => entry.js?.includes('youtube.js'));
  assert.deepEqual(script.matches, ['*://www.youtube.com/*', '*://m.youtube.com/*']);
  assert.deepEqual(script.css, ['youtube.css']);
  assert.equal(script.run_at, 'document_start');
});
