// darkreader.js wraps chrome.runtime.sendMessage (dropping its promise) and
// onMessage.addListener, so keep the real ones for dark.js.
globalThis.focusRuntime ??= {
  send: chrome.runtime.sendMessage.bind(chrome.runtime),
  listen: chrome.runtime.onMessage.addListener.bind(chrome.runtime.onMessage),
};
