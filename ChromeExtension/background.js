importScripts('dark-fixes.js');

// Talks to Focus.app's BrowserBridge on 127.0.0.1:47821.
// MV3 workers are killed after ~30s idle, so every bit of state lives in
// chrome.storage (session = until Chrome quits, local = durable event queue).

const API = 'http://127.0.0.1:47821';
const BLOCK_PAGE = chrome.runtime.getURL('blocked.html');
const STATE_TTL_MS = 5_000;
// Keep the last known state through brief app restarts (e.g. ./deploy.sh).
const STALE_MS = 3 * 60_000;
const IDLE_SECS = 120;
const CHECKPOINT_MS = 60_000;
const BYPASS_MS = 5 * 60_000;
const RULE_ID = 1;

const local = chrome.storage.local;
const session = chrome.storage.session;

let chain = Promise.resolve();
function serial(fn) {
  const run = chain.then(fn);
  chain = run.catch(() => {});
  return run;
}

function domainOf(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    if (u.hostname === '127.0.0.1' || u.hostname === 'localhost') return null;
    return u.hostname.replace(/^www\./, '');
  } catch {
    return null;
  }
}

const matches = (host, d) => host === d || host.endsWith('.' + d);

// MARK: - State from the app

async function refreshState(force = false) {
  const { state, fetchedAt = 0, lastOk = 0 } = await session.get(['state', 'fetchedAt', 'lastOk']);
  if (!force && state && Date.now() - fetchedAt < STATE_TTL_MS) return state;

  let next;
  let ok = lastOk;
  const asked = Date.now();
  try {
    const r = await fetch(API + '/state', { cache: 'no-store', signal: AbortSignal.timeout(3000) });
    next = { ...(await r.json()), connected: true };
    ok = Date.now();
    if (next.darkPages && !darkWatching) await takeAppDark(next.darkPages, asked);
  } catch {
    next = state && Date.now() - lastOk < STALE_MS
      ? { ...state, connected: false }
      : { blocking: false, domains: [], label: '', bypassAllowed: true, connected: false };
  }
  await session.set({ state: next, fetchedAt: Date.now(), lastOk: ok });
  await applyRules(next);
  await syncDark();
  return next;
}

async function applyRules(state) {
  return serial(async () => {
    const now = Date.now();
    let { bypass = {}, ruleSig = null } = await session.get(['bypass', 'ruleSig']);
    if (!state.blocking || !state.bypassAllowed) bypass = {};
    for (const d of Object.keys(bypass)) if (bypass[d] <= now) delete bypass[d];
    await session.set({ bypass });

    const domains = state.blocking ? (state.domains || []).filter((d) => !bypass[d]) : [];
    const sig = [...domains].sort().join(',');
    if (sig === ruleSig) return;

    const existing = await chrome.declarativeNetRequest.getDynamicRules();
    await chrome.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: existing.map((r) => r.id),
      addRules: domains.length
        ? [{
            id: RULE_ID,
            priority: 1,
            action: { type: 'redirect', redirect: { regexSubstitution: BLOCK_PAGE + '#\\0' } },
            condition: { regexFilter: '^.*$', requestDomains: domains, resourceTypes: ['main_frame'] },
          }]
        : [],
    });
    await session.set({ ruleSig: sig });

    const before = new Set(ruleSig ? ruleSig.split(',') : []);
    const added = domains.filter((d) => !before.has(d));
    if (added.length) await sweep(added);
  });
}

// Tabs already open on a newly blocked site get covered too, but that isn't
// an attempt, so the block page is told not to count it.
async function sweep(domains) {
  for (const tab of await chrome.tabs.query({})) {
    const host = tab.url && domainOf(tab.url);
    if (host && domains.some((d) => matches(host, d))) {
      chrome.tabs.update(tab.id, { url: BLOCK_PAGE + '?auto=1#' + tab.url }).catch(() => {});
    }
  }
}

function isBlocked(url, state) {
  const host = domainOf(url);
  return !!(host && state.blocking && (state.domains || []).some((d) => matches(host, d)));
}

// MARK: - Dark pages

// The app's setting is kept in local storage and the schedule runs here, so
// pages keep following it while Focus is quit. dark.js reads `dark`/`darkNight`.
const DARK_SCRIPT = {
  id: 'dark',
  js: ['dark-pre.js', 'vendor/darkreader.js', 'dark.js'],
  matches: ['<all_urls>'],
  allFrames: true,
  runAt: 'document_start',
};

const sameDark = (a, b) => !!a && !!b && ['mode', 'from', 'to', 'brightness', 'contrast'].every((key) => a[key] === b[key]);

// The popup and Focus's Settings both edit it. A popup edit wins until the app
// has it (`darkPending`), so a /state read that raced the edit can't undo it.
async function takeAppDark(dark, asked) {
  await writeDark(async () => {
    const { dark: old, darkPending = false, darkEditedAt = 0 } = await local.get(['dark', 'darkPending', 'darkEditedAt']);
    if (darkPending || asked < darkEditedAt) return;
    if (!sameDark(old, dark)) await local.set({ dark, darkNight: inHours(dark.from, dark.to) });
  });
  void pushDark();
}

let darkWrites = Promise.resolve();
function writeDark(fn) {
  const next = darkWrites.then(fn);
  darkWrites = next.catch(() => {});
  return next;
}

async function setDark(dark) {
  const d = {
    mode: ['off', 'night', 'system', 'always'].includes(dark.mode) ? dark.mode : 'night',
    from: clampInt(dark.from, 0, 1439),
    to: clampInt(dark.to, 0, 1439),
    brightness: clampInt(dark.brightness, 50, 150),
    contrast: clampInt(dark.contrast, 50, 150),
  };
  await writeDark(async () => {
    const { darkAppRevision = null } = await local.get('darkAppRevision');
    await local.set({ dark: d, darkNight: inHours(d.from, d.to), darkPending: true, darkBaseRevision: darkAppRevision, darkEditID: crypto.randomUUID(), darkEditedAt: Date.now() });
  });
  await syncDark();
  void pushDark();
}

const clampInt = (v, lo, hi) => Math.min(hi, Math.max(lo, Math.round(Number(v) || 0)));

let pushingDark = null;
function pushDark() {
  if (pushingDark) return pushingDark;
  pushingDark = (async () => {
    while (true) {
      const { dark, darkPending, darkEditID, darkBaseRevision } = await local.get(['dark', 'darkPending', 'darkEditID', 'darkBaseRevision']);
      if (!dark || !darkPending) return;
      try {
        const r = await fetch(API + '/dark', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ...dark, baseRevision: darkBaseRevision }),
          signal: AbortSignal.timeout(3000),
        });
        if (!r.ok && r.status !== 409) return;
        const update = await r.json();
        await writeDark(async () => {
          const current = await local.get('darkEditID');
          if (current.darkEditID !== darkEditID) {
            if (r.ok && update.revision) await local.set({ darkBaseRevision: update.revision, darkAppRevision: update.revision });
            return;
          }
          await local.set({ dark: update.dark || dark, darkNight: inHours((update.dark || dark).from, (update.dark || dark).to), darkPending: false,
            darkBaseRevision: update.revision || null, darkAppRevision: update.revision || null, darkEditedAt: Date.now() });
        });
      } catch { return; }
    }
  })().finally(() => { pushingDark = null; });
  return pushingDark;
}

let darkWatching = false;
let darkWatchRetry;
async function watchDark() {
  if (darkWatching) return;
  clearTimeout(darkWatchRetry);
  darkWatching = true;
  try {
    let revision = '';
    while (true) {
      const r = await fetch(API + '/dark?since=' + encodeURIComponent(revision), {
        cache: 'no-store', signal: AbortSignal.timeout(25000),
      });
      if (!r.ok) throw new Error('Dark settings unavailable');
      const update = await r.json();
      if (!update.dark || !update.revision) throw new Error('Missing dark settings');
      revision = update.revision;
      await writeDark(async () => {
        const { darkPending, darkEditedAt = 0, dark: old } = await local.get(['darkPending', 'darkEditedAt', 'dark']);
        if (darkPending) return;
        if (!sameDark(old, update.dark)) {
          await local.set({ dark: update.dark, darkNight: inHours(update.dark.from, update.dark.to), darkAppRevision: revision, darkEditedAt: Math.max(Date.now(), darkEditedAt) });
        } else await local.set({ darkAppRevision: revision });
      });
      await syncDark();
      void pushDark();
    }
  } catch {
    darkWatching = false;
    darkWatchRetry = setTimeout(watchDark, 5000);
  }
}

function inHours(from, to) {
  const d = new Date();
  const m = d.getHours() * 60 + d.getMinutes();
  return from <= to ? m >= from && m < to : m >= from || m < to;
}

let darkChain = Promise.resolve();
function syncDark(ensureOpen = false) {
  const next = darkChain.then(async () => {
    const { dark = null, darkNight = null } = await local.get(['dark', 'darkNight']);
    const night = !!dark && inHours(dark.from, dark.to);
    if (night !== darkNight) await local.set({ darkNight: night });
    if (dark?.mode === 'night') {
      const nextTime = (minutes) => {
        const date = new Date();
        date.setHours(Math.floor(minutes / 60), minutes % 60, 0, 0);
        if (date.getTime() <= Date.now()) date.setDate(date.getDate() + 1);
        return date.getTime();
      };
      const when = Math.min(nextTime(dark.from), nextTime(dark.to));
      const alarm = await chrome.alarms.get('darkBoundary');
      if (!alarm || alarm.scheduledTime !== when) await chrome.alarms.create('darkBoundary', { when });
    } else await chrome.alarms.clear('darkBoundary');

    const want = !!dark && dark.mode !== 'off';
    const have = (await chrome.scripting.getRegisteredContentScripts({ ids: [DARK_SCRIPT.id] })).length > 0;
    if (want && (!have || ensureOpen)) {
      if (!have) await chrome.scripting.registerContentScripts([DARK_SCRIPT]);
      const tabs = await chrome.tabs.query({ url: ['http://*/*', 'https://*/*'] });
      await Promise.all(tabs.filter((t) => t.active).map((t) => injectDark(t.id)));
      for (const tab of tabs.filter((t) => !t.active)) void injectDark(tab.id);
    } else if (!want && have) {
      await chrome.scripting.unregisterContentScripts({ ids: [DARK_SCRIPT.id] });
    }
  });
  darkChain = next.catch(() => {});
  return darkChain;
}

// Open tabs only; a second copy of darkreader.js would orphan the first.
async function injectDark(tabId) {
  try {
    const found = await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      func: () => !!globalThis.focusDarkLoaded,
    });
    const frameIds = found.filter((f) => !f.result).map((f) => f.frameId);
    if (frameIds.length) {
      await chrome.scripting.executeScript({ target: { tabId, frameIds }, world: 'MAIN', files: ['vendor/darkreader-proxy.js'] });
      await chrome.scripting.executeScript({ target: { tabId, frameIds }, files: DARK_SCRIPT.js });
    }
  } catch {}
}

// Dark Reader reads cross-origin stylesheets and images to recolor them; a
// content script can't (page CORS), the worker can.
const failedDarkFetches = new Map();
const activeDarkFetches = new Map();
async function darkFetch(url) {
  if ((failedDarkFetches.get(url) || 0) > Date.now()) return { ok: false };
  if (activeDarkFetches.has(url)) return activeDarkFetches.get(url);
  const request = fetchDarkResource(url).then((result) => {
    if (!result.ok) {
      if (failedDarkFetches.size >= 128) failedDarkFetches.delete(failedDarkFetches.keys().next().value);
      failedDarkFetches.set(url, Date.now() + 60_000);
    } else failedDarkFetches.delete(url);
    return result;
  }).finally(() => activeDarkFetches.delete(url));
  activeDarkFetches.set(url, request);
  return request;
}

async function fetchDarkResource(url) {
  if (!/^https?:/.test(url)) return { ok: false };
  try {
    const r = await fetch(url, { cache: 'force-cache', credentials: 'omit', signal: AbortSignal.timeout(15000) });
    if (!r.ok) return { ok: false };
    const type = r.headers.get('content-type') || '';
    const buf = new Uint8Array(await r.arrayBuffer());
    if (buf.length > 8 << 20) return { ok: false };
    if (/^text\/|css|svg|xml|json|javascript/.test(type)) return { ok: true, type, text: new TextDecoder().decode(buf) };
    let bin = '';
    for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
    return { ok: true, type, b64: btoa(bin) };
  } catch {
    return { ok: false };
  }
}

// MARK: - Event queue

async function enqueue(event) {
  await serial(async () => {
    const { queue = [] } = await local.get('queue');
    queue.push({ eid: crypto.randomUUID(), ...event });
    if (queue.length > 5000) queue.splice(0, queue.length - 5000);
    await local.set({ queue });
  });
  return flush();
}

function flush() {
  return serial(async () => {
    const { queue = [] } = await local.get('queue');
    if (!queue.length) return;
    const batch = queue.slice(0, 500);
    try {
      const r = await fetch(API + '/events', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ events: batch }),
        signal: AbortSignal.timeout(5000),
      });
      if (!r.ok) return;
    } catch {
      return;
    }
    const sent = new Set(batch.map((e) => e.eid));
    const { queue: latest = [] } = await local.get('queue');
    await local.set({ queue: latest.filter((e) => !sent.has(e.eid)) });
  });
}

// MARK: - Time on sites

async function currentDomain() {
  const win = await chrome.windows.getLastFocused().catch(() => null);
  if (!win || !win.focused) return null;
  const [tab] = await chrome.tabs.query({ active: true, windowId: win.id });
  if (!tab) return null;
  const idle = await chrome.idle.queryState(IDLE_SECS);
  // Watching a video produces no input; don't count that as idle.
  if (idle !== 'active' && !(idle === 'idle' && tab.audible)) return { idle: true };
  return { domain: domainOf(tab.url || '') };
}

function track() {
  return serial(async () => {
    const now = Date.now();
    const { cur = null } = await session.get('cur');
    const seen = await currentDomain();
    const domain = seen && !seen.idle ? seen.domain : null;

    if (cur && cur.domain !== domain) {
      const end = seen && seen.idle ? Math.max(cur.start, now - IDLE_SECS * 1000) : now;
      if (end - cur.start >= 2000) await pushSpan(cur.domain, cur.start, end);
    }

    let next = null;
    if (domain) {
      next = cur && cur.domain === domain ? cur : { domain, start: now };
      // Checkpoint long visits so a Chrome quit loses at most a minute; the app stitches them.
      if (now - next.start >= CHECKPOINT_MS) {
        await pushSpan(domain, next.start, now);
        next = { domain, start: now };
      }
    }
    await session.set({ cur: next });
  });
}

// The focused tab's address for the app's screen watcher (a screenshot can't
// tell godbolt.org from a math PDF). Private/unavailable focus clears the tab;
// a fresh normal-window report is also required before coach uploads.
async function postTab(focusHint) {
  const started = Date.now();
  let payload = { focusedWindowId: chrome.windows.WINDOW_ID_NONE, incognito: false, url: '', title: '', ts: started };
  if (focusHint !== chrome.windows.WINDOW_ID_NONE) {
    const win = await chrome.windows.getLastFocused().catch(() => null);
    if (win && win.focused && !win.incognito) {
      const [tab] = await chrome.tabs.query({ active: true, windowId: win.id }).catch(() => []);
      const check = await chrome.windows.getLastFocused().catch(() => null);
      if (tab && tab.url && /^https?:/.test(tab.url) && check && check.id === win.id && check.focused && !check.incognito) {
        payload = { focusedWindowId: win.id, incognito: false, url: tab.url, title: tab.title || '', ts: started };
      }
    }
  }
  fetch(API + '/tab', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(2000),
  }).catch(() => {});
}

async function pushSpan(domain, start, end) {
  const { queue = [] } = await local.get('queue');
  queue.push({ eid: crypto.randomUUID(), kind: 'span', domain, start, end });
  await local.set({ queue });
}

// MARK: - Block page messages

async function recordBlock(url, auto) {
  const state = await refreshState();
  const domain = domainOf(url) || '';
  let id = null;
  if (!auto && domain) {
    const { lastBlock } = await session.get('lastBlock');
    if (lastBlock && lastBlock.domain === domain && Date.now() - lastBlock.at < 4000) {
      id = lastBlock.id;
    } else {
      id = crypto.randomUUID();
      await session.set({ lastBlock: { domain, at: Date.now(), id } });
      await enqueue({ kind: 'block', id, date: Date.now(), domain, label: state.label || '', isFocus: !!state.isFocus });
    }
  }
  const fresh = await refreshState(true);
  return { id, domain, state: fresh, blocked: isBlocked(url, fresh) };
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  (async () => {
    switch (msg.type) {
      case 'blocked':
        return recordBlock(msg.url, msg.auto);
      case 'status': {
        const state = await refreshState();
        return { state, blocked: isBlocked(msg.url, state) };
      }
      case 'reason':
        if (msg.id) await enqueue({ kind: 'reason', id: msg.id, reason: msg.reason });
        return { ok: true };
      case 'bypass': {
        const state = await refreshState(true);
        if (!state.bypassAllowed) return { ok: false };
        const domain = (state.domains || []).find((d) => matches(msg.domain, d)) || msg.domain;
        await serial(async () => {
          const { bypass = {} } = await session.get('bypass');
          bypass[domain] = Date.now() + BYPASS_MS;
          await session.set({ bypass });
        });
        if (msg.id) await enqueue({ kind: 'bypass', id: msg.id, reason: msg.reason || '' });
        await applyRules(state);
        return { ok: true };
      }
      case 'leave': {
        const tab = sender.tab;
        if (!tab) return { ok: false };
        const siblings = await chrome.tabs.query({ windowId: tab.windowId });
        if (siblings.length > 1) await chrome.tabs.remove(tab.id);
        else await chrome.tabs.update(tab.id, { url: 'chrome://newtab' });
        return { ok: true };
      }
      case 'setDark':
        await setDark(msg.dark || {});
        return { ok: true };
      case 'darkConfig':
        return darkFixesFor(sender.url || sender.tab?.url || '');
      case 'darkFetch':
        return darkFetch(msg.url);
      case 'popup': {
        const state = await refreshState(true);
        const { queue = [] } = await local.get('queue');
        return { state, pending: queue.length };
      }
    }
  })().then(reply, () => reply(null));
  return true;
});

// MARK: - Wiring

// DNR rules can lag a just-started session; catch the navigation directly.
chrome.webNavigation.onBeforeNavigate.addListener(async (d) => {
  if (d.frameId !== 0 || !domainOf(d.url)) return;
  const state = await refreshState();
  if (!isBlocked(d.url, state)) return;
  setTimeout(async () => {
    const tab = await chrome.tabs.get(d.tabId).catch(() => null);
    const pending = tab && (tab.pendingUrl || tab.url);
    if (pending && !pending.startsWith(BLOCK_PAGE) && isBlocked(pending, state)) {
      chrome.tabs.update(d.tabId, { url: BLOCK_PAGE + '#' + pending }).catch(() => {});
    }
  }, 400);
});

chrome.tabs.onActivated.addListener(() => { track(); refreshState(); postTab(); watchDark(); });
chrome.tabs.onUpdated.addListener((_id, info, tab) => {
  if (tab.active && (info.url || info.audible !== undefined)) track();
  if (tab.active && (info.url || info.title)) postTab();
  if (info.url) chrome.tabs.sendMessage(_id, { type: 'darkRecheck' }).catch(() => {});
});
chrome.windows.onFocusChanged.addListener((id) => { track(); postTab(id); });
chrome.idle.onStateChanged.addListener(() => track());

function ensureAlarm() {
  chrome.idle.setDetectionInterval(IDLE_SECS);
  chrome.alarms.get('tick', (a) => { if (!a) chrome.alarms.create('tick', { periodInMinutes: 0.5 }); });
}
chrome.runtime.onInstalled.addListener(() => { ensureAlarm(); refreshState(true); });
chrome.runtime.onStartup.addListener(() => { ensureAlarm(); refreshState(true); });
chrome.alarms.onAlarm.addListener(async (a) => {
  if (a.name === 'darkBoundary') { await syncDark(); return; }
  if (a.name !== 'tick') return;
  watchDark();
  await refreshState(true);
  await track();
  postTab();
  await flush();
});
ensureAlarm();

watchDark();
syncDark(true);
