(() => {
  if (globalThis.focusYouTubeLoaded) return;
  globalThis.focusYouTubeLoaded = true;

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
    if (!active || !settings.hideHome || page() !== 'home') return;
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


  // MARK: Educational filter: YouTube's own picks, minus everything that isn't
  // science, math, tech or AI. Focus.app decides; unknown tiles stay hidden.
  const verdicts = new Map();
  const queued = new Map();
  let peek = false;
  let unreachable = false;
  let inFlight = false;
  let observer = null;
  let scanTimer = 0;
  let flushTimer = 0;

  const TILE = {
    home: 'ytd-browse[page-subtype="home"] ytd-rich-item-renderer',
    watch: '#related yt-lockup-view-model, #related ytd-compact-video-renderer',
  };

  function filtering() {
    if (!filterActive) return null;
    const p = page();
    if (p === 'home' && !(active && settings.hideHome)) return 'home';
    if (p === 'watch' && !(active && settings.hideRelated)) return 'watch';
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

  function button(el, info, keep) {
    let b = el.querySelector(':scope > .focus-edu-btn');
    const label = keep ? 'Hide this channel' : 'Always show this channel';
    if (b && b.dataset.keep === String(keep)) return;
    b?.remove();
    b = document.createElement('button');
    b.type = 'button';
    b.className = 'focus-edu-btn';
    b.dataset.keep = String(keep);
    b.textContent = keep ? 'Hide channel' : 'Show channel';
    b.title = label;
    b.setAttribute('aria-label', `${label}: ${info.channel}`);
    b.onclick = (e) => {
      e.preventDefault();
      e.stopPropagation();
      setChannel(info.channel, !keep);
    };
    el.append(b);
  }

  function setChannel(channel, allow) {
    if (!channel) return;
    chrome.runtime.sendMessage({ type: 'ytChannel', channel, allow }).catch(() => {});
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
    if (v && info.channel) button(el, info, v.keep);
    else el.querySelector(':scope > .focus-edu-btn')?.remove();
  }

  function scan() {
    const where = filtering();
    const root = document.documentElement;
    if (where) { if (root.getAttribute('data-focus-edu') !== where) root.setAttribute('data-focus-edu', where); }
    else root.removeAttribute('data-focus-edu');
    root.toggleAttribute('data-focus-edu-peek', !!where && peek);
    if (!where) { root.removeAttribute('data-focus-edu-busy'); return status(null); }
    let shown = 0, hidden = 0, pending = 0;
    for (const el of document.querySelectorAll(TILE[where])) {
      if (where === 'watch' && el.parentElement?.closest('ytd-compact-video-renderer, yt-lockup-view-model')) continue;
      const info = tileInfo(el);
      if (!info) { pending += el.querySelector('ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer') ? 0 : 1; continue; }
      if (el.getAttribute('data-focus-edu-id') !== info.id || el.getAttribute('data-focus-edu') !== stateOf(info.id)) apply(el, info);
      const v = verdicts.get(info.id);
      if (!v) { pending++; if (!queued.has(info.id)) queued.set(info.id, info); }
      else if (v.keep) shown++; else hidden++;
    }
    root.toggleAttribute('data-focus-edu-busy', queued.size > 0 || inFlight);
    status(where, shown, hidden, pending);
    if (queued.size) { clearTimeout(flushTimer); flushTimer = setTimeout(flush, 120); }
  }

  async function flush() {
    if (inFlight || !queued.size || !filtering()) return;
    inFlight = true;
    const batch = [...queued.values()].slice(0, 16);
    let result = null;
    try { result = await chrome.runtime.sendMessage({ type: 'ytClassify', videos: batch }); } catch {}
    inFlight = false;
    unreachable = !result;
    if (result) {
      for (const info of batch) {
        queued.delete(info.id);
        const v = result[info.id];
        if (v) verdicts.set(info.id, { keep: !!v.keep, source: v.source, channel: info.channel });
      }
    }
    scan();
    if (result && queued.size) flush();
    else if (!result) setTimeout(flush, 10_000);
  }

  function status(where, shown = 0, hidden = 0, pending = 0) {
    let bar = document.getElementById('focus-edu-status');
    if (!where) { bar?.remove(); return; }
    const host = where === 'home'
      ? document.querySelector('ytd-browse[page-subtype="home"] ytd-rich-grid-renderer')
      : document.querySelector('#related');
    if (!host) return;
    if (!bar || bar.parentElement !== host) {
      bar?.remove();
      bar = document.createElement('div');
      bar.id = 'focus-edu-status';
      bar.setAttribute('role', 'status');
      const toggle = document.createElement('button');
      toggle.type = 'button';
      toggle.onclick = () => { peek = !peek; scan(); };
      bar.append(document.createElement('span'), toggle);
      host.prepend(bar);
    }
    const parts = [`${shown} educational`];
    if (hidden) parts.push(`${hidden} hidden`);
    if (pending) parts.push(unreachable ? `${pending} waiting for Focus` : `checking ${pending}`);
    const text = (unreachable ? 'Focus isn’t reachable · ' : 'Educational only · ') + parts.join(' · ');
    const span = bar.querySelector('span');
    if (span.textContent !== text) span.textContent = text;
    const b = bar.querySelector('button');
    const label = peek ? 'Hide filtered' : 'Show filtered';
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

  chrome.runtime.onMessage.addListener((message) => {
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

  chrome.runtime.sendMessage({ type: 'youtubeState' }).then((state) => {
    settings = { ...DEFAULT, ...state?.settings };
    active = !!state?.active;
    filterActive = !!state?.filter;
    schedule();
  }).catch(() => schedule());
  schedule();
})();
