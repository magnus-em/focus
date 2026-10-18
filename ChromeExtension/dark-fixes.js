// Matching follows Dark Reader v4.9.133 (MIT, vendor/darkreader.LICENSE).
let darkFixesData;
async function darkFixesFor(address) {
  if (!darkFixesData) {
    darkFixesData = fetch(chrome.runtime.getURL('vendor/darkreader-fixes.json'))
      .then((r) => { if (!r.ok) throw new Error('Site fixes unavailable'); return r.json(); })
      .catch((error) => { darkFixesData = null; throw error; });
  }
  const entries = await darkFixesData;
  let url;
  try { url = new URL(address); } catch { return null; }
  const matches = entries.filter((entry) => entry.url.some((pattern) => darkURLMatches(url, pattern)));
  matches.sort((a, b) => a.url[0].length - b.url[0].length);
  const result = { invert: [], css: '', ignoreInlineStyle: [], ignoreImageAnalysis: [], ignoreCSSUrl: [] };
  for (const entry of matches) {
    for (const key of ['invert', 'ignoreInlineStyle', 'ignoreImageAnalysis', 'ignoreCSSUrl']) result[key].push(...entry[key] || []);
    if (entry.css) result.css += '\n' + entry.css;
  }
  return result;
}

function darkURLMatches(url, pattern) {
  if (pattern === '*') return true;
  if (pattern.startsWith('/') && pattern.endsWith('/')) {
    try { return new RegExp(pattern.slice(1, -1)).test(url.href); } catch { return false; }
  }
  const exactStart = pattern.startsWith('^');
  const exactEnd = pattern.endsWith('$');
  pattern = pattern.replace(/^\^|\$$/g, '');
  const protocol = pattern.match(/^([^:]+:)\/\//)?.[1];
  if (protocol) pattern = pattern.slice(protocol.length + 2);
  const slash = pattern.indexOf('/');
  const host = slash < 0 ? pattern : pattern.slice(0, slash);
  const path = slash < 0 ? '' : pattern.slice(slash + 1);
  const colon = host.lastIndexOf(':');
  const port = colon >= 0 ? host.slice(colon + 1) : '*';
  const hosts = (colon >= 0 ? host.slice(0, colon) : host).split('.').reverse();
  const actualHosts = url.hostname.split('.').reverse();
  const paths = path.replace(/\/$/, '').split('/').filter((p, i, a) => p || i < a.length - 1);
  const actualPaths = url.pathname.slice(1).replace(/\/$/, '').split('/').filter((p, i, a) => p || i < a.length - 1);
  if (hosts.length > actualHosts.length || (exactStart && hosts.length !== actualHosts.length)
      || (exactEnd && paths.length !== actualPaths.length) || (port !== '*' && port !== url.port)
      || (protocol && protocol !== url.protocol) || paths.length > actualPaths.length) return false;
  if (!hosts.every((part, i) => part === '*' || part === actualHosts[i])) return false;
  if (hosts.length >= 2 && hosts.at(-1) !== '*' && (hosts.length < actualHosts.length - 1
      || (hosts.length === actualHosts.length - 1 && actualHosts.at(-1) !== 'www'))) return false;
  return paths.every((part, i) => part === '*' || part === actualPaths[i]);
}
