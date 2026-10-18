# Dark Reader integration

Source: npm `darkreader` 4.9.133, MIT (`darkreader.LICENSE`). Site fixes are pinned to the same upstream release; provenance and hash are in `darkreader-fixes.SOURCE`.

After replacing `darkreader.js` with a fresh, unmodified 4.9.133 API bundle, run `python3 ChromeExtension/vendor/prepare-darkreader.py`. It extracts the upstream proxy into `darkreader-proxy.js` and adapts two API-only behaviors:

- Chrome MV3 disallows the API's inline proxy script insertion. The extension registers the packaged helper in MAIN at document start, matching upstream Dark Reader's extension architecture. A DOM event supplies two validated booleans. Engine cleanup restores the proxied browser APIs. No policy settings are weakened.
- Optional image-analysis failures already fall back to the original image URL in the engine. They propagate normally without the API wrapper's unconditional console-error log for data-url requests. Stylesheet failures retain their error reporting.

Regenerate site fixes with `python3 ChromeExtension/vendor/update-dark-fixes.py`. Runtime uses bundled data only.

Run `node --test ChromeExtension/tests/dark.test.cjs`. With Playwright available and Chrome installed, `node ChromeExtension/tests/csp-browser.cjs` checks strict CSP, separate execution contexts, helper lifecycle and resource fallback in headless Chrome.
