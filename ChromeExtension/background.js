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
  try {
    const r = await fetch(API + '/state', { cache: 'no-store', signal: AbortSignal.timeout(3000) });
    next = { ...(await r.json()), connected: true };
    ok = Date.now();
  } catch {
    next = state && Date.now() - lastOk < STALE_MS
      ? { ...state, connected: false }
      : { blocking: false, domains: [], label: '', bypassAllowed: true, connected: false };
  }
  await session.set({ state: next, fetchedAt: Date.now(), lastOk: ok });
  await applyRules(next);
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

chrome.tabs.onActivated.addListener(() => { track(); refreshState(); });
chrome.tabs.onUpdated.addListener((_id, info, tab) => { if (tab.active && (info.url || info.audible !== undefined)) track(); });
chrome.windows.onFocusChanged.addListener(() => track());
chrome.idle.onStateChanged.addListener(() => track());

function ensureAlarm() {
  chrome.idle.setDetectionInterval(IDLE_SECS);
  chrome.alarms.get('tick', (a) => { if (!a) chrome.alarms.create('tick', { periodInMinutes: 0.5 }); });
}
chrome.runtime.onInstalled.addListener(() => { ensureAlarm(); refreshState(true); });
chrome.runtime.onStartup.addListener(() => { ensureAlarm(); refreshState(true); });
chrome.alarms.onAlarm.addListener(async (a) => {
  if (a.name !== 'tick') return;
  await refreshState(true);
  await track();
  await flush();
});
ensureAlarm();
