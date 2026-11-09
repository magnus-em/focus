(() => {
  // Runs in the page's world: only here can the continuation element be asked to load the next page.
  // youtube.js asks when the feed filter has hidden so much that nothing is left to scroll.
  document.addEventListener('focus-edu-more', (event) => {
    const scope = event.detail === 'home'
      ? document.querySelector('ytd-browse[page-subtype="home"] ytd-rich-grid-renderer')
      : document.querySelector('#related');
    const all = scope?.querySelectorAll('ytd-continuation-item-renderer');
    const el = all?.[all.length - 1];
    try { (el?.polymerController || el)?.triggerContinuation?.(); } catch {}
  });
})();
