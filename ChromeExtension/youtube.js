(() => {
  if (globalThis.focusYouTubeLoaded) return;
  globalThis.focusYouTubeLoaded = true;

  const DEFAULT = { mode: 'focus', hideHome: true, hideRelated: true, hideShorts: true,
    hideEndScreens: true, disableAutoplay: true, hideComments: false };
  const attributes = ['hideHome', 'hideRelated', 'hideShorts', 'hideEndScreens', 'hideComments'];
  let settings = DEFAULT;
  let active = false;
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

  function render() {
    const root = document.documentElement;
    if (!root) return;
    root.toggleAttribute('data-focus-youtube-active', active && settings.mode !== 'off');
    root.setAttribute('data-focus-youtube-page', page());
    for (const key of attributes) root.toggleAttribute(`data-focus-youtube-${key.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())}`, !!settings[key]);
    ensureHomeMessage();
    ensureShortsBlock();
    turnOffAutoplay();
  }

  function schedule() {
    timers.forEach(clearTimeout);
    timers = [0, 100, 500, 1500, 4000].map((delay) => setTimeout(render, delay));
  }

  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== 'youtubeFocusChanged') return;
    settings = { ...DEFAULT, ...message.settings };
    active = !!message.active;
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
    schedule();
  }).catch(() => schedule());
  schedule();
})();
