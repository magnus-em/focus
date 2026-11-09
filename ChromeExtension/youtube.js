(() => {
  if (globalThis.focusYouTubeLoaded) return;
  globalThis.focusYouTubeLoaded = true;

  // darkreader.js shares this world and wraps sendMessage, dropping its reply (dark-pre.js keeps the
  // real ones). After 7 PM every answer from Focus came back empty and the feed said Focus wasn't reachable.
  globalThis.focusRuntime ??= {
    send: chrome.runtime.sendMessage.bind(chrome.runtime),
    listen: chrome.runtime.onMessage.addListener.bind(chrome.runtime.onMessage),
  };
  const send = (message) => globalThis.focusRuntime.send(message);

  const DEFAULT = { mode: 'focus', hideHome: true, hideRelated: true, hideShorts: true,
    hideEndScreens: true, disableAutoplay: true, hideComments: false, filter: 'always' };
  const attributes = ['hideHome', 'hideRelated', 'hideShorts', 'hideEndScreens', 'hideComments'];
  let settings = DEFAULT;
  let active = false;
  let filterActive = false;
  let timers = [];

  function page() {
    if (location.pathname.startsWith('/shorts/')) return 'shorts';
    if (location.pathname === '/' || location.pathname === '') return 'home';
    if (location.pathname === '/watch') return 'watch';
    return 'other';
  }

  function ensureHomeMessage() {
    if (!active || !settings.hideHome || page() !== 'home' || filtering()) return;
    const host = document.querySelector('ytd-browse[page-subtype="home"], ytd-browse[browse-id="FEwhat_to_watch"], ytm-browse');
    if (!host || host.querySelector('#focus-youtube-home-message')) return;
    const message = document.createElement('div');
    message.id = 'focus-youtube-home-message';
    message.setAttribute('role', 'status');
    message.innerHTML = '<strong>Choose what to watch</strong><p>Recommendations are hidden while Focus is running. Search above, open Subscriptions, or use a saved link.</p><a href="/feed/subscriptions">Open Subscriptions</a>';
    host.append(message);
  }

  function ensureShortsBlock() {
    let block = document.getElementById('focus-youtube-shorts-block');
    if (!active || !settings.hideShorts || page() !== 'shorts') {
      block?.remove();
      return;
    }
    for (const video of document.querySelectorAll('video')) video.pause();
    if (block || !document.body) return;
    const id = location.pathname.split('/')[2] || '';
    block = document.createElement('div');
    block.id = 'focus-youtube-shorts-block';
    block.setAttribute('role', 'dialog');
    block.setAttribute('aria-modal', 'true');
    block.setAttribute('aria-label', 'Shorts are hidden during focus');
    block.tabIndex = -1;
    block.innerHTML = `<strong>Shorts are paused during focus</strong><p>You can watch this clip in the regular player without opening the Shorts feed.</p><div id="focus-youtube-shorts-actions"><a href="/watch?v=${encodeURIComponent(id)}">Use regular player</a><button type="button">Go back</button></div>`;
    block.querySelector('button').onclick = () => history.length > 1 ? history.back() : location.assign('/');
    document.body.append(block);
    block.focus({ preventScroll: true });
  }

  function turnOffAutoplay() {
    if (!active || !settings.disableAutoplay || page() !== 'watch') return;
    for (const toggle of document.querySelectorAll('.ytp-autonav-toggle-button[aria-checked="true"], [aria-label*="Autoplay"][aria-checked="true"]')) {
      toggle.click();
    }
  }


  // MARK: Feed filter: YouTube's own picks, minus what isn't good for you (politics, news, drama,
  // empty entertainment). Focus.app decides; unknown tiles stay hidden.
  const verdicts = new Map();
  const queued = new Map();
  let peek = false;
  let unreachable = false;
  let inFlight = false;
  let observer = null;
  let scanTimer = 0;
  let flushTimer = 0;
  let loads = 0;
  let lastLoad = 0;
  let loadPath = '';
  let lastReport = '';
  let reportTimer = 0;
  const WANT = { home: 12, watch: 8 };

  const TILE = {
    home: 'ytd-browse[page-subtype="home"] ytd-rich-item-renderer',
    watch: '#related yt-lockup-view-model, #related ytd-compact-video-renderer',
  };

  function filtering() {
    if (!filterActive) return null;
    const p = page();
    // The filtered feed replaces focus mode's blank Home and hidden related videos (user, 11/8).
    if (p === 'home') return 'home';
    if (p === 'watch') return 'watch';
    return null;
  }

  function tileInfo(el) {
    const link = el.querySelector('a[href*="/watch?v="], a[href*="/shorts/"]');
    if (!link) return null;
    const href = link.getAttribute('href') || '';
    const id = href.startsWith('/shorts/') ? 'shorts:' + href.split('/')[2]
      : new URLSearchParams(href.split('?')[1] || '').get('v');
    const title = (el.querySelector('h3[title]')?.getAttribute('title')
      || el.querySelector('#video-title')?.textContent || '').trim();
    const avatar = el.querySelector('[aria-label^="Go to channel "]')?.getAttribute('aria-label')?.slice(14);
    const channel = (avatar || el.querySelector('a[href^="/@"], ytd-channel-name a, ytd-channel-name #text')?.textContent
      || el.querySelector('.ytContentMetadataViewModelMetadataRow')?.textContent || '').trim();
    return id && title ? { id, title, channel } : null;
  }

  const WHY = {
    you: 'your choice',
    known: 'channel',
    title: 'title',
    model: 'on-device AI',
    cloud: 'AI',
    fallback: 'keyword guess, AI unavailable',
  };

  function whyText(v) {
    if (v.source === 'you' || !v.why) return WHY[v.source] || 'not worth your time';
    return v.source === 'fallback' ? WHY.fallback : `${v.why} (${WHY[v.source] || v.source})`;
  }

  function action(text, label, run) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = text;
    b.title = label;
    b.setAttribute('aria-label', label);
    b.onclick = (e) => {
      e.preventDefault();
      e.stopPropagation();
      run();
    };
    return b;
  }

  function actions(el, info, v) {
    const key = `${v.keep}:${v.source}:${v.why || ''}:${info.channel}`;
    let box = el.querySelector(':scope > .focus-edu-actions');
    if (box?.dataset.key === key) return;
    box?.remove();
    box = document.createElement('div');
    box.className = 'focus-edu-actions';
    box.dataset.key = key;
    box.addEventListener('click', (e) => e.stopPropagation());
    if (!v.keep) {
      const why = document.createElement('span');
      why.className = 'focus-edu-why';
      why.textContent = `Hidden · ${whyText(v)}`;
      box.append(why);
    }
    box.append(action(v.keep ? 'Hide video' : 'Show video',
      v.keep ? `Hide this video: ${info.title}` : `Show this video: ${info.title}`, () => setVideo(info, !v.keep)));
    if (info.channel) {
      box.append(action(v.keep ? 'Hide channel' : 'Show channel',
        v.keep ? `Always hide ${info.channel}` : `Always show ${info.channel}`, () => setChannel(info.channel, !v.keep)));
    }
    el.append(box);
  }

  function setVideo(info, keep) {
    send({ type: 'ytVideo', video: info, keep }).catch(() => {});
    verdicts.set(info.id, { keep, source: 'you', channel: info.channel });
    scan();
  }

  function setChannel(channel, allow) {
    if (!channel) return;
    send({ type: 'ytChannel', channel, allow }).catch(() => {});
    for (const [id, v] of verdicts) if (v.channel === channel) verdicts.set(id, { ...v, keep: allow, source: 'you' });
    for (const el of document.querySelectorAll('[data-focus-edu-id]')) el.removeAttribute('data-focus-edu-id');
    scan();
  }

  function stateOf(id) {
    const v = verdicts.get(id);
    return v ? (v.keep ? 'keep' : 'hide') : 'pending';
  }

  function apply(el, info) {
    const v = verdicts.get(info.id);
    el.setAttribute('data-focus-edu', stateOf(info.id));
    el.setAttribute('data-focus-edu-id', info.id);
    if (v) actions(el, info, v);
    else el.querySelector(':scope > .focus-edu-actions')?.remove();
  }

  function scan() {
    const where = filtering();
    const root = document.documentElement;
    if (where) { if (root.getAttribute('data-focus-edu') !== where) root.setAttribute('data-focus-edu', where); }
    else root.removeAttribute('data-focus-edu');
    root.toggleAttribute('data-focus-edu-peek', !!where && peek);
    if (!where) { root.removeAttribute('data-focus-edu-busy'); return status(null); }
    let shown = 0, hidden = 0, pending = 0, added = false;
    for (const el of document.querySelectorAll(TILE[where])) {
      if (where === 'watch' && el.parentElement?.closest('ytd-compact-video-renderer, yt-lockup-view-model')) continue;
      const info = tileInfo(el);
      if (!info) { pending += el.querySelector('ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer') ? 0 : 1; continue; }
      if (el.getAttribute('data-focus-edu-id') !== info.id || el.getAttribute('data-focus-edu') !== stateOf(info.id)
        || (verdicts.has(info.id) && !el.querySelector(':scope > .focus-edu-actions'))) apply(el, info);
      else if (verdicts.has(info.id)) actions(el, info, verdicts.get(info.id));
      const v = verdicts.get(info.id);
      if (!v) { pending++; if (!queued.has(info.id)) { queued.set(info.id, info); added = true; } }
      else if (v.keep) shown++; else hidden++;
    }
    const busy = queued.size > 0 || inFlight;
    root.toggleAttribute('data-focus-edu-busy', busy);
    status(where, shown, hidden, pending);
    loadMore(where, shown, busy);
    report(where, shown, hidden, pending);
    if (added) { clearTimeout(flushTimer); flushTimer = setTimeout(flush, 120); }
  }

  // With most tiles hidden the page can't scroll, and YouTube only loads more on scroll.
  function loadMore(where, shown, busy) {
    const path = location.pathname + location.search;
    if (path !== loadPath) { loadPath = path; loads = 0; }
    if (busy || document.hidden || shown >= WANT[where] || loads >= 12 || Date.now() - lastLoad < 3000) return;
    if (!document.querySelector('ytd-continuation-item-renderer')) return;
    loads++;
    lastLoad = Date.now();
    document.dispatchEvent(new CustomEvent('focus-edu-more', { detail: where }));
    setTimeout(scan, 3100);
  }

  function report(where, shown, hidden, pending) {
    const page = { where, shown, hidden, pending, queued: queued.size, inFlight, loads, unreachable,
      continuation: !!document.querySelector('ytd-continuation-item-renderer'),
      tiles: document.querySelectorAll(TILE[where]).length };
    const text = JSON.stringify(page);
    if (text === lastReport || reportTimer) return;
    reportTimer = setTimeout(() => {
      reportTimer = 0;
      lastReport = text;
      send({ type: 'ytReport', page }).catch(() => {});
    }, 2000);
  }

  async function flush() {
    if (inFlight || !queued.size || !filtering()) return;
    inFlight = true;
    const batch = [...queued.values()].slice(0, 60);
    let result = null;
    try { result = await send({ type: 'ytClassify', videos: batch }); } catch {}
    inFlight = false;
    unreachable = !result;
    if (result) {
      for (const info of batch) {
        const v = result[info.id];
        if (!v) continue;
        queued.delete(info.id);
        verdicts.set(info.id, { keep: !!v.keep, source: v.source, why: v.why, channel: info.channel });
      }
    }
    scan();
    if (queued.size) setTimeout(flush, result ? 1500 : 10_000);
  }

  function status(where, shown = 0, hidden = 0, pending = 0) {
    let bar = document.getElementById('focus-edu-status');
    if (!where) { bar?.remove(); return; }
    // On Home the bar goes right above the videos: the top of the grid sits under YouTube's sticky
    // topic chips when signed in, which hid it (11/8).
    const anchor = where === 'home'
      ? document.querySelector('ytd-browse[page-subtype="home"] ytd-rich-grid-renderer > #contents')
      : [...(document.querySelector('#related')?.children || [])].find((c) => c.id !== 'focus-edu-status');
    if (!anchor) return;
    if (!bar || bar.nextElementSibling !== anchor) {
      bar?.remove();
      bar = document.createElement('div');
      bar.id = 'focus-edu-status';
      bar.setAttribute('role', 'status');
      const toggle = document.createElement('button');
      toggle.type = 'button';
      toggle.onclick = () => { peek = !peek; scan(); };
      bar.append(document.createElement('span'), toggle);
      anchor.before(bar);
    }
    const parts = [`${shown} shown`];
    if (hidden) parts.push(peek ? `${hidden} hidden shown dimmed, each says why` : `${hidden} hidden`);
    if (pending) parts.push(unreachable ? `${pending} waiting for Focus` : `checking ${pending}`);
    const lead = unreachable ? 'Focus isn’t reachable' : peek ? 'Reviewing hidden videos' : 'Filtered for you';
    const text = `${lead} · ${parts.join(' · ')}`;
    const span = bar.querySelector('span');
    if (span.textContent !== text) span.textContent = text;
    const b = bar.querySelector('button');
    const label = peek ? 'Done reviewing' : `Review ${hidden} hidden`;
    if (b.textContent !== label) b.textContent = label;
    b.hidden = !hidden && !peek;
  }

  function watchFeed() {
    if (filterActive && !observer && document.body) {
      observer = new MutationObserver(() => {
        if (scanTimer) return;
        scanTimer = setTimeout(() => { scanTimer = 0; scan(); }, 250);
      });
      observer.observe(document.body, { childList: true, subtree: true });
    } else if (!filterActive && observer) {
      observer.disconnect();
      observer = null;
    }
  }

  function render() {
    const root = document.documentElement;
    if (!root) return;
    root.toggleAttribute('data-focus-youtube-active', active && settings.mode !== 'off');
    root.setAttribute('data-focus-youtube-page', page());
    for (const key of attributes) root.toggleAttribute(`data-focus-youtube-${key.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())}`, !!settings[key]);
    ensureHomeMessage();
    ensureShortsBlock();
    turnOffAutoplay();
    watchFeed();
    scan();
  }

  function schedule() {
    timers.forEach(clearTimeout);
    timers = [0, 100, 500, 1500, 4000].map((delay) => setTimeout(render, delay));
  }

  globalThis.focusRuntime.listen((message) => {
    if (message?.type !== 'youtubeFocusChanged') return;
    settings = { ...DEFAULT, ...message.settings };
    active = !!message.active;
    filterActive = !!message.filter;
    schedule();
  });
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !changes.youtubeFocus) return;
    settings = { ...DEFAULT, ...(changes.youtubeFocus.newValue || {}) };
    schedule();
  });
  for (const event of ['DOMContentLoaded', 'load', 'popstate', 'yt-navigate-finish', 'yt-page-data-updated']) {
    window.addEventListener(event, schedule);
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) schedule(); });

  send({ type: 'youtubeState' }).then((state) => {
    settings = { ...DEFAULT, ...state?.settings };
    active = !!state?.active;
    filterActive = !!state?.filter;
    schedule();
  }).catch(() => schedule());
  schedule();
})();
