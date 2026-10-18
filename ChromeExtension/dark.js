// Dark pages: Dark Reader's engine (vendor/darkreader.js, MIT) on bright sites,
// on the schedule set in Focus → Settings → Dark pages. background.js keeps
// `dark` (the app's setting) and `darkNight` (inside the hours) current.
(() => {
  if (globalThis.focusDarkLoaded) return;
  globalThis.focusDarkLoaded = true;

  const { send, listen } = globalThis.focusRuntime;
  const DarkReader = globalThis.DarkReader;
  const VERDICT_MS = 7 * 24 * 3600_000;
  const scheme = matchMedia('(prefers-color-scheme: dark)');

  const top = location.ancestorOrigins?.length
    ? location.ancestorOrigins[location.ancestorOrigins.length - 1]
    : location.origin;
  let host = '';
  try { host = new URL(top).hostname.replace(/^www\./, ''); } catch {}
  const verdictKey = () => `darkSeen:${location.hostname}:${scheme.matches ? 'd' : 'l'}`;

  let status = 'off';

  DarkReader.setFetchMethod(async (url) => {
    const r = await send({ type: 'darkFetch', url });
    if (!r || !r.ok) throw new Error(`Focus dark pages: couldn't load ${url}`);
    const body = r.b64 ? Uint8Array.from(atob(r.b64), (c) => c.charCodeAt(0)) : r.text;
    return new Response(body, { headers: { 'Content-Type': r.type || '' } });
  });

  // The page's own background where the reader looks; transparent all the way down is white.
  function looksDark() {
    const stack = document.elementsFromPoint(innerWidth / 2, innerHeight / 2);
    for (const el of [...stack, document.body, document.documentElement]) {
      if (!el) continue;
      const m = getComputedStyle(el).backgroundColor.match(/[\d.]+/g);
      if (!m || (m.length > 3 && +m[3] < 0.5)) continue;
      const [r, g, b] = m.slice(0, 3).map((v) => {
        const c = v / 255;
        return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
      });
      return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.2;
    }
    return false;
  }

  const ready = () => new Promise((resolve) => {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', resolve, { once: true });
    else resolve();
  });

  let theme = { brightness: 100, contrast: 100, sepia: 0 };
  let applied = '';
  function set(next) {
    status = next;
    if (next === 'on') {
      const sig = JSON.stringify(theme);
      if (!DarkReader.isEnabled() || sig !== applied) DarkReader.enable(theme);
      applied = sig;
    } else if (DarkReader.isEnabled()) {
      DarkReader.disable();
    }
  }

  let run = 0;
  async function evaluate() {
    const id = ++run;
    const key = verdictKey();
    const s = await chrome.storage.local.get(['dark', 'darkNight', 'darkSites', key]);
    if (id !== run) return;
    const mode = s.dark?.mode || 'off';
    theme = { brightness: s.dark?.brightness ?? 100, contrast: s.dark?.contrast ?? 100, sepia: 0 };
    const scheduled = mode === 'always' || (mode === 'night' && s.darkNight) || (mode === 'system' && scheme.matches);
    const site = (s.darkSites || {})[host];
    if (!scheduled) return set('off');
    if (site === 'off') return set('excluded');
    if (site === 'on') return set('on');

    const seen = s[key];
    if (seen && Date.now() - seen.at < VERDICT_MS) return set(seen.dark ? 'native' : 'on');
    set('off');
    await ready();
    if (id !== run) return;
    const dark = looksDark();
    chrome.storage.local.set({ [key]: { dark, at: Date.now() } }).catch(() => {});
    set(dark ? 'native' : 'on');
  }

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && (changes.dark || changes.darkNight || changes.darkSites)) evaluate();
  });
  scheme.addEventListener('change', evaluate);
  if (window === window.top) {
    listen((msg, _sender, reply) => {
      if (msg?.type !== 'darkStatus') return;
      reply({ status, host });
    });
  }
  evaluate();
})();
