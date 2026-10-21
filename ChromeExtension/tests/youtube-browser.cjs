const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const shots = path.resolve(root, '../.shots/youtube-focus');

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  });
  try {
    fs.mkdirSync(shots, { recursive: true });
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    await page.addInitScript(() => {
      window.runtimeListeners = [];
      window.storageListeners = [];
      window.pauseCalls = 0;
      HTMLMediaElement.prototype.pause = () => { window.pauseCalls++; };
      window.chrome = {
        runtime: {
          sendMessage: async (message) => message.type === 'youtubeState' ? {
            active: true,
            settings: { mode: 'focus', hideHome: true, hideRelated: true, hideShorts: true,
              hideEndScreens: true, disableAutoplay: true, hideComments: false },
          } : null,
          onMessage: { addListener: (listener) => runtimeListeners.push(listener) },
        },
        storage: { onChanged: { addListener: (listener) => storageListeners.push(listener) } },
      };
      window.sendYouTube = (settings, active = true) => {
        for (const listener of runtimeListeners) listener({ type: 'youtubeFocusChanged', settings, active });
      };
    });
    await page.route('https://www.youtube.com/**', (route) => route.fulfill({
      contentType: 'text/html',
      body: '<html><body><header style="height:56px;border-bottom:1px solid #ddd"></header><ytd-browse page-subtype="home"><ytd-rich-grid-renderer><div>Recommended video</div></ytd-rich-grid-renderer></ytd-browse></body></html>',
    }));
    await page.goto('https://www.youtube.com/');
    await page.addStyleTag({ path: path.join(root, 'youtube.css') });
    await page.addScriptTag({ path: path.join(root, 'youtube.js') });
    await page.waitForSelector('#focus-youtube-home-message', { state: 'visible' });
    assert.equal(await page.locator('ytd-rich-grid-renderer').evaluate((element) => getComputedStyle(element).display), 'none');
    assert.equal(await page.locator('#focus-youtube-home-message a').getAttribute('href'), '/feed/subscriptions');
    await page.screenshot({ path: path.join(shots, 'youtube-home.png') });

    await page.evaluate(() => {
      history.pushState({}, '', '/watch?v=lesson');
      document.body.innerHTML = '<header style="height:56px;border-bottom:1px solid #ddd"></header><main><video></video><button class="ytp-autonav-toggle-button" aria-checked="true">Autoplay</button><div class="ytp-ce-element">End suggestion</div><ytd-comments id="comments">Useful comments</ytd-comments></main><aside id="related">Related videos</aside>';
      document.querySelector('.ytp-autonav-toggle-button').onclick = (event) => event.currentTarget.setAttribute('aria-checked', 'false');
      window.dispatchEvent(new Event('yt-navigate-finish'));
    });
    await page.waitForFunction(() => document.documentElement.dataset.focusYoutubePage === 'watch');
    assert.equal(await page.locator('#related').evaluate((element) => getComputedStyle(element).display), 'none');
    assert.equal(await page.locator('.ytp-ce-element').evaluate((element) => getComputedStyle(element).display), 'none');
    assert.notEqual(await page.locator('#comments').evaluate((element) => getComputedStyle(element).display), 'none');
    assert.equal(await page.locator('.ytp-autonav-toggle-button').getAttribute('aria-checked'), 'false');

    await page.evaluate(() => sendYouTube({ mode: 'focus', hideHome: true, hideRelated: true, hideShorts: true,
      hideEndScreens: true, disableAutoplay: true, hideComments: true }));
    await page.waitForFunction(() => document.documentElement.hasAttribute('data-focus-youtube-hide-comments'));
    assert.equal(await page.locator('#comments').evaluate((element) => getComputedStyle(element).display), 'none');

    await page.evaluate(() => {
      history.pushState({}, '', '/shorts/abc123');
      document.body.innerHTML = '<header style="height:56px;border-bottom:1px solid #ddd"></header><video></video><div>Shorts feed</div>';
      window.dispatchEvent(new Event('yt-navigate-finish'));
    });
    await page.waitForSelector('#focus-youtube-shorts-block', { state: 'visible' });
    assert.equal(await page.locator('#focus-youtube-shorts-block a').getAttribute('href'), '/watch?v=abc123');
    assert.equal(await page.evaluate(() => document.activeElement?.id), 'focus-youtube-shorts-block');
    assert.equal(await page.locator('body > video').evaluate((element) => getComputedStyle(element).visibility), 'hidden');
    assert.ok(await page.evaluate(() => pauseCalls > 0));
    await page.screenshot({ path: path.join(shots, 'youtube-shorts.png') });

    await page.evaluate(() => sendYouTube({ mode: 'focus', hideHome: true, hideRelated: true, hideShorts: true,
      hideEndScreens: true, disableAutoplay: true, hideComments: false }, false));
    await page.waitForFunction(() => !document.documentElement.hasAttribute('data-focus-youtube-active'));
    assert.equal(await page.locator('#focus-youtube-shorts-block').count(), 0);

    const popup = await browser.newPage({ viewport: { width: 360, height: 720 } });
    await popup.addInitScript(() => {
      const youtubeFocus = { mode: 'focus', hideHome: true, hideRelated: true, hideShorts: true,
        hideEndScreens: true, disableAutoplay: true, hideComments: false };
      const noOpEvent = { addListener() {} };
      window.chrome = {
        runtime: {
          sendMessage: async (message) => {
            if (message.type === 'popup') return { state: { connected: true, blocking: true, isFocus: true, label: 'AI', todayBlocked: 4, domains: [] }, pending: 0 };
            if (message.type === 'youtubeState') return { settings: youtubeFocus, active: true };
            if (message.type === 'setYouTube') return { settings: message.settings, active: true };
            return { ok: true };
          },
          onMessage: noOpEvent,
        },
        storage: {
          local: { get: async () => ({ youtubeFocus, dark: { mode: 'night', from: 1140, to: 420, brightness: 100, contrast: 100 }, darkNight: false, darkSites: {} }), set: async () => {} },
          onChanged: noOpEvent,
        },
        tabs: { query: async () => [], sendMessage: async () => null },
      };
    });
    const popupHTML = fs.readFileSync(path.join(root, 'popup.html'), 'utf8').replace('<script src="popup.js"></script>', '');
    await popup.route('https://focus-extension.test/**', (route) => route.fulfill({ contentType: 'text/html', body: popupHTML }));
    await popup.goto('https://focus-extension.test/popup.html');
    await popup.addStyleTag({ path: path.join(root, 'style.css') });
    await popup.addScriptTag({ path: path.join(root, 'popup.js') });
    await popup.locator('#youtube').evaluate((element) => { element.open = true; });
    await popup.waitForFunction(() => document.querySelector('#youtubeSummary').textContent === 'Active now');
    await popup.screenshot({ path: path.join(shots, 'popup.png'), fullPage: true });
    assert.equal(await popup.locator('[data-youtube="hideComments"]').isChecked(), false);
    assert.equal(await popup.locator('[data-mode="focus"]').getAttribute('aria-pressed'), 'true');

    console.log('PASS YouTube home, watch, Shorts, inactive restoration, and popup settings UI.');
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
