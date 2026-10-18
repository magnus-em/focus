(() => {
  if (globalThis.focusDarkLoaded) return;
  globalThis.focusDarkLoaded = true;

  const { send, listen } = globalThis.focusRuntime;
  const DarkReader = globalThis.DarkReader;
  const scheme = matchMedia('(prefers-color-scheme: dark)');
  const top = location.ancestorOrigins?.length
    ? location.ancestorOrigins[location.ancestorOrigins.length - 1] : location.origin;
  let host = '';
  try { host = new URL(top).hostname.replace(/^www\./, ''); } catch {}
  let status = 'off';
  let applied = '';
  let run = 0;
  let recheck;
  let fixURL = '';
  let fixes;

  DarkReader.setFetchMethod(async (url) => {
    const r = await send({ type: 'darkFetch', url });
    if (!r || !r.ok) throw new Error(`Focus dark pages: couldn't load ${url}`);
    const body = r.b64 ? Uint8Array.from(atob(r.b64), (c) => c.charCodeAt(0)) : r.text;
    return new Response(body, { headers: { 'Content-Type': r.type || '' } });
  });

  function color(value) {
    const context = new OffscreenCanvas(1, 1).getContext('2d', { willReadFrequently: true });
    context.fillStyle = value;
    context.fillRect(0, 0, 1, 1);
    return [...context.getImageData(0, 0, 1, 1).data];
  }

  function luminance(rgb) {
    const [r, g, b] = rgb.map((v) => { const c = v / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  // Read the site's original colors, never our own converted stylesheet.
  function looksDark() {
    if (!document.body) return false;
    const sheets = [...document.styleSheets].filter((s) => s.ownerNode?.classList?.contains('darkreader') && !s.disabled);
    sheets.forEach((s) => { s.disabled = true; });
    try {
      const root = getComputedStyle(document.documentElement);
      const canvasDark = root.colorScheme === 'dark' || (scheme.matches && root.colorScheme.split(/\s+/).includes('dark'));
      const colors = new Map();
      const background = (element) => {
        const layers = [];
        for (let el = element; el; el = el.parentElement) {
          const value = getComputedStyle(el).backgroundColor;
          if (!colors.has(value)) colors.set(value, color(value));
          layers.push(colors.get(value));
        }
        let rgb = canvasDark ? [18, 18, 18] : [255, 255, 255];
        for (const layer of layers.reverse()) rgb = rgb.map((v, i) => v * (1 - layer[3] / 255) + layer[i] * layer[3] / 255);
        return luminance(rgb);
      };
      let dark = 0;
      let samples = 0;
      for (const y of [0.15, 0.4, 0.65, 0.85]) {
        for (const x of [0.15, 0.4, 0.65, 0.85]) {
          let el = document.elementFromPoint(innerWidth * x, innerHeight * y);
          if (!el) continue;
          while (el && /^(IMG|VIDEO|CANVAS|SVG|IFRAME)$/.test(el.tagName)) el = el.parentElement;
          if (!el) continue;
          samples++;
          if (background(el) < 0.3) dark++;
        }
      }
      return samples > 0 && dark / samples >= 0.8;
    } finally {
      sheets.forEach((s) => { s.disabled = false; });
    }
  }

  function set(next, theme, siteFixes) {
    const changed = status !== next;
    status = next;
    if (next === 'on') {
      const signature = JSON.stringify([theme, siteFixes]);
      if (!DarkReader.isEnabled() || signature !== applied) DarkReader.enable(theme, siteFixes);
      applied = signature;
    } else if (DarkReader.isEnabled()) DarkReader.disable();
    if (changed && window === window.top) send({ type: 'darkStatusChanged' }).catch(() => {});
  }

  async function evaluate() {
    const id = ++run;
    if (fixURL !== location.href) {
      fixURL = location.href;
      fixes = send({ type: 'darkConfig' }).catch(() => null);
    }
    const [s, siteFixes] = await Promise.all([chrome.storage.local.get(['dark', 'darkNight', 'darkSites']), fixes]);
    if (id !== run) return;
    const mode = s.dark?.mode || 'off';
    const theme = { brightness: s.dark?.brightness ?? 100, contrast: s.dark?.contrast ?? 100, sepia: 0, immediateModify: true };
    const scheduled = mode === 'always' || (mode === 'night' && s.darkNight) || (mode === 'system' && scheme.matches);
    const site = (s.darkSites || {})[host];
    if (!scheduled) return set('off', theme);
    if (site === 'off') return set('excluded', theme);
    if (site === 'on') return set('on', theme, siteFixes);
    set(looksDark() ? 'native' : 'on', theme, siteFixes);
  }

  function schedule() {
    clearTimeout(recheck);
    recheck = setTimeout(evaluate, 80);
  }

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'local' && (changes.dark || changes.darkNight || changes.darkSites)) evaluate();
  });
  scheme.addEventListener('change', schedule);
  for (const event of ['DOMContentLoaded', 'load']) window.addEventListener(event, schedule, { once: true });
  window.addEventListener('popstate', schedule);
  window.addEventListener('hashchange', schedule);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) schedule(); });

  const themeObserver = new MutationObserver((mutations) => {
    if (mutations.some((m) => {
      if (m.type === 'attributes') {
        if (m.attributeName !== 'style') return true;
        const clean = (value) => (value || '').replace(/--darkreader-[^;]+;?/g, '').trim();
        return clean(m.oldValue) !== clean(m.target.getAttribute('style'));
      }
      return [...m.addedNodes, ...m.removedNodes].some((n) => n.nodeType === 1 && !n.classList?.contains('darkreader')
        && (n.tagName === 'BODY' || n.tagName === 'HEAD'));
    })) {
      observeTheme();
      schedule();
    }
  });
  function observeTheme() {
    const options = { attributes: true, attributeOldValue: true, attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'data-bs-theme'], childList: true };
    themeObserver.observe(document.documentElement, options);
    if (document.body) themeObserver.observe(document.body, options);
  }
  observeTheme();
  const styleObserver = new MutationObserver((mutations) => {
    if (mutations.some((m) => {
      const parent = m.target.nodeType === 1 ? m.target : m.target.parentElement;
      if (parent?.closest('.darkreader')) return false;
      if (parent?.matches('style:not(.darkreader), link[rel="stylesheet"], meta[name="color-scheme"]')) return true;
      return [...m.addedNodes, ...m.removedNodes].some((n) => n.nodeType === 1
        && n.matches('style:not(.darkreader), link[rel="stylesheet"], meta[name="color-scheme"]'));
    })) schedule();
  });
  if (document.head) styleObserver.observe(document.head, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['content', 'href', 'media'] });
  window.addEventListener('DOMContentLoaded', () => {
    observeTheme();
    if (document.head) styleObserver.observe(document.head, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['content', 'href', 'media'] });
  }, { once: true });

  listen((msg, _sender, reply) => {
    if (msg?.type === 'darkRecheck') { schedule(); return; }
    if (msg?.type === 'darkStatus' && window === window.top) reply({ status, host });
  });
  evaluate();
})();
