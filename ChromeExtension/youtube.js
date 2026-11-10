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
    hideEndScreens: true, disableAutoplay: true, hideComments: false, filter: 'manual' };
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
  // By hand (11/10): every pick shows, the user hides what they don't want, and Focus logs what was
  // on screen, opened and hidden, so a model can learn the filter from it.
  const verdicts = new Map();
  const justHidden = new Map();
  let justPath = '';
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

  const manual = () => settings.filter === 'manual';

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
    const just = !v.keep && justHidden.has(info.id);
    const key = `${v.keep}:${v.source}:${v.why || ''}:${info.channel}:${just}:${manual()}`;
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
      why.textContent = just ? 'Hidden' : !manual() ? `Hidden · ${whyText(v)}`
        : v.why === 'channel' ? 'Hidden · you hid the channel' : 'Hidden by you';
      box.append(why);
    }
    if (just) {
      box.append(action('Undo', `Show this again: ${info.title}`, () => undo(info.id)));
    } else if (v.keep) {
      box.append(action(manual() ? 'Hide' : 'Hide video', `Hide this video: ${info.title}`, () => hideVideo(info)));
      if (info.channel) box.append(action('Hide channel', `Always hide ${info.channel}`, () => hideChannel(info)));
    } else if (manual() && v.why === 'channel' && info.channel) {
      box.append(action('Show channel', `Show ${info.channel} again`, () => showChannel(info)));
    } else {
      box.append(action('Show video', `Show this video: ${info.title}`, () => showVideo(info)));
      if (!manual() && info.channel) box.append(action('Show channel', `Always show ${info.channel}`, () => showChannel(info)));
    }
    el.append(box);
  }

  // A hidden tile stays in place, dimmed with Undo, until you leave the page.
  function hideVideo(info) {
    justHidden.set(info.id, { kind: 'video', info, prev: verdicts.get(info.id) });
    verdicts.set(info.id, { keep: false, source: 'you', channel: info.channel });
    send({ type: 'ytVideo', video: info, keep: false }).catch(() => {});
    log('hide', info);
    scan();
  }

  function showVideo(info) {
    send({ type: 'ytVideo', video: info, keep: manual() ? null : true }).catch(() => {});
    verdicts.set(info.id, { keep: true, source: manual() ? 'unfiltered' : 'you', channel: info.channel });
    log('unhide', info);
    scan();
  }

  function hideChannel(info) {
    send({ type: 'ytChannel', channel: info.channel, allow: false }).catch(() => {});
    for (const [id, v] of verdicts) {
      if (v.channel !== info.channel || !v.keep) continue;
      justHidden.set(id, { kind: 'channel', info, prev: v });
      verdicts.set(id, { ...v, keep: false, source: 'you', why: 'channel' });
    }
    log('hideChannel', info);
    scan();
  }

  function showChannel(info) {
    send({ type: 'ytChannel', channel: info.channel, allow: manual() ? null : true }).catch(() => {});
    for (const [id, v] of verdicts) {
      if (v.channel !== info.channel) continue;
      if (!manual()) verdicts.set(id, { ...v, keep: true, source: 'you', why: undefined });
      else if (v.why === 'channel') verdicts.set(id, { keep: true, source: 'unfiltered', channel: v.channel });
    }
    log('unhideChannel', info);
    scan();
  }

  function undo(id) {
    const hid = justHidden.get(id);
    if (!hid) return;
    const restore = (key, j) => {
      verdicts.set(key, j.prev || { keep: true, source: 'unfiltered', channel: j.info.channel });
      justHidden.delete(key);
    };
    if (hid.kind === 'video') {
      send({ type: 'ytVideo', video: hid.info, keep: null }).catch(() => {});
      restore(id, hid);
      log('unhide', hid.info);
    } else {
      send({ type: 'ytChannel', channel: hid.info.channel, allow: null }).catch(() => {});
      for (const [key, j] of [...justHidden]) if (j.kind === 'channel' && j.info.channel === hid.info.channel) restore(key, j);
      log('unhideChannel', hid.info);
    }
    scan();
  }

  // MARK: Feed log: what stayed on screen for a second, what you opened, what you hid.
  const logQueue = [];
  let logTimer = 0;
  const seenSent = new Set();
  const seenTimers = new Map();
  const observed = new WeakSet();

  function log(event, info) {
    const where = page();
    const entry = { event, id: info.id, title: info.title, channel: info.channel, page: where, mode: manual() ? 'manual' : 'ai' };
    if (where === 'watch') entry.watching = document.title.replace(/^\(\d+\)\s*/, '').replace(/ - YouTube$/, '');
    logQueue.push(entry);
    if (!logTimer) logTimer = setTimeout(flushLog, event === 'seen' ? 3000 : 500);
  }

  function flushLog() {
    clearTimeout(logTimer);
    logTimer = 0;
    if (!logQueue.length) return;
    const events = logQueue.splice(0, 500);
    send({ type: 'ytLog', events }).then((r) => {
      if (r?.ok) { if (logQueue.length) logTimer = setTimeout(flushLog, 500); return; }
      throw new Error('not saved');
    }).catch(() => {
      logQueue.unshift(...events);
      logQueue.splice(1000);
      logTimer = setTimeout(flushLog, 15_000);
    });
  }

  const seer = new IntersectionObserver((entries) => {
    for (const e of entries) {
      const el = e.target;
      if (e.isIntersecting && e.intersectionRatio >= 0.5) {
        if (seenTimers.has(el)) continue;
        seenTimers.set(el, setTimeout(() => {
          seenTimers.delete(el);
          if (document.hidden || !filtering()) return;
          const info = tileInfo(el);
          if (!info || seenSent.has(info.id) || verdicts.get(info.id)?.keep === false) return;
          seenSent.add(info.id);
          log('seen', info);
        }, 1000));
      } else {
        clearTimeout(seenTimers.get(el));
        seenTimers.delete(el);
      }
    }
  }, { threshold: [0, 0.5] });

  function opened(e) {
    if (!filtering() || !(e.target instanceof Element) || e.target.closest('.focus-edu-actions')) return;
    const el = e.target.closest('[data-focus-edu-id]');
    if (!el || !e.target.closest('a[href*="/watch?v="], a[href^="/shorts/"]')) return;
    const info = tileInfo(el);
    if (info) log('open', info);
  }
  document.addEventListener('click', opened, true);
  document.addEventListener('auxclick', (e) => { if (e.button === 1) opened(e); }, true);
  window.addEventListener('pagehide', flushLog);

  // Just hidden counts as kept for the page's CSS: it stays in place, dimmed, with Undo.
  function stateOf(id) {
    const v = verdicts.get(id);
    return v ? (v.keep || justHidden.has(id) ? 'keep' : 'hide') : 'pending';
  }

  function apply(el, info) {
    const v = verdicts.get(info.id);
    el.setAttribute('data-focus-edu', stateOf(info.id));
    el.setAttribute('data-focus-edu-id', info.id);
    if (!observed.has(el)) { observed.add(el); seer.observe(el); }
    if (v) actions(el, info, v);
    else el.querySelector(':scope > .focus-edu-actions')?.remove();
  }

  function scan() {
    const where = filtering();
    const root = document.documentElement;
    if (where) { if (root.getAttribute('data-focus-edu') !== where) root.setAttribute('data-focus-edu', where); }
    else root.removeAttribute('data-focus-edu');
    root.toggleAttribute('data-focus-edu-peek', !!where && peek);
    root.toggleAttribute('data-focus-edu-manual', !!where && manual());
    if (!where) { root.removeAttribute('data-focus-edu-busy'); return status(null); }
    const path = location.pathname + location.search;
    if (path !== justPath) { justPath = path; justHidden.clear(); }
    let shown = 0, hidden = 0, pending = 0, added = false;
    for (const el of document.querySelectorAll(TILE[where])) {
      if (where === 'watch' && el.parentElement?.closest('ytd-compact-video-renderer, yt-lockup-view-model')) continue;
      const info = tileInfo(el);
      if (!info) { pending += el.querySelector('ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer') ? 0 : 1; continue; }
      if (el.getAttribute('data-focus-edu-id') !== info.id || el.getAttribute('data-focus-edu') !== stateOf(info.id)
        || (verdicts.has(info.id) && !el.querySelector(':scope > .focus-edu-actions'))) apply(el, info);
      else if (verdicts.has(info.id)) actions(el, info, verdicts.get(info.id));
      el.toggleAttribute('data-focus-edu-just', justHidden.has(info.id) && verdicts.get(info.id)?.keep === false);
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
    const page = { where, mode: manual() ? 'manual' : 'ai', shown, hidden, pending, queued: queued.size, inFlight, loads, unreachable,
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
    try { result = await send({ type: 'ytClassify', videos: batch, judge: manual() ? 'manual' : 'ai' }); } catch {}
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
    let text;
    if (manual()) {
      const lead = unreachable ? 'Focus isn’t reachable, so what you hide isn’t saved'
        : peek ? 'Videos you hid, shown dimmed' : 'YouTube’s picks · hover a video and press Hide to log what you don’t want';
      text = hidden && !unreachable ? `${lead} · ${hidden} hidden` : lead;
    } else {
      const parts = [`${shown} shown`];
      if (hidden) parts.push(peek ? `${hidden} hidden shown dimmed, each says why` : `${hidden} hidden`);
      if (pending) parts.push(unreachable ? `${pending} waiting for Focus` : `checking ${pending}`);
      const lead = unreachable ? 'Focus isn’t reachable' : peek ? 'Reviewing hidden videos' : 'Filtered for you';
      text = `${lead} · ${parts.join(' · ')}`;
    }
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

  let judgedBy = null;

  function render() {
    const root = document.documentElement;
    if (!root) return;
    if (judgedBy !== settings.filter) {
      if (judgedBy !== null) {
        verdicts.clear();
        queued.clear();
        justHidden.clear();
        for (const el of document.querySelectorAll('[data-focus-edu-id]')) el.removeAttribute('data-focus-edu-id');
      }
      judgedBy = settings.filter;
    }
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
