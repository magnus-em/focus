// darkreader.js wraps chrome.runtime.sendMessage (dropping its promise) and
// onMessage.addListener, so keep the real ones for dark.js.
globalThis.focusRuntime ??= {
  send: chrome.runtime.sendMessage.bind(chrome.runtime),
  listen: chrome.runtime.onMessage.addListener.bind(chrome.runtime.onMessage),
};

// Static MAIN scripts and registered isolated scripts can start in either order.
if (!globalThis.focusDarkProxyBridge) {
  globalThis.focusDarkProxyBridge = true;
  let pendingProxy = null;
  document.addEventListener('__focus_darkreader_proxy', (event) => {
    pendingProxy = typeof event.detail === 'string' ? event.detail : null;
  });
  document.addEventListener('__darkreader__cleanUp', () => { pendingProxy = null; });
  document.addEventListener('__focus_darkreader_proxy_ready', () => {
    if (pendingProxy) document.dispatchEvent(new CustomEvent('__focus_darkreader_proxy', { detail: pendingProxy }));
  });
}
