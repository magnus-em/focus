chrome.runtime.sendMessage({ type: 'popup' }).then((res) => {
  if (!res) return;
  const { state, pending } = res;
  const $ = (id) => document.getElementById(id);
  $('dot').classList.add(state.connected ? 'ok' : 'bad');
  $('conn').textContent = state.connected ? 'Connected to Focus' : 'Focus app not running';
  $('status').textContent = state.blocking
    ? `Blocking · ${state.label || 'Focus'}${state.isFocus ? ' (no unlocks)' : ''}`
    : state.label ? `Tracking ${state.label} · not blocking` : 'Idle · not blocking';
  if (state.connected) $('today').textContent = `${state.todayBlocked || 0} blocked today`;
  const domains = [...new Set(state.domains || [])];
  $('sites').hidden = !domains.length;
  $('sitesSummary').textContent = `${domains.length} distracting ${domains.length === 1 ? 'site' : 'sites'}`;
  $('siteList').replaceChildren(...domains.map((domain) => {
    const item = document.createElement('li');
    item.textContent = domain;
    return item;
  }));
  if (pending) $('pending').textContent = `${pending} ${pending === 1 ? 'event' : 'events'} waiting to sync`;
});

const clock = (m) => new Date(2000, 0, 1, Math.floor(m / 60), m % 60)
  .toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
const toInput = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
const fromInput = (v) => { const [h, m] = v.split(':').map(Number); return h * 60 + m; };
const DARK_DEFAULT = { mode: 'night', from: 19 * 60, to: 7 * 60, brightness: 100, contrast: 100 };
const $ = (id) => document.getElementById(id);
let dark = DARK_DEFAULT;

async function saveDark(patch) {
  dark = { ...dark, ...patch };
  renderDark();
  await chrome.runtime.sendMessage({ type: 'setDark', dark });
  setTimeout(showDark, 300);
}

function renderDark(darkNight) {
  for (const b of $('darkMode').children) {
    const selected = b.dataset.mode === dark.mode;
    b.classList.toggle('on', selected);
    b.setAttribute('aria-pressed', String(selected));
  }
  $('darkHours').hidden = dark.mode !== 'night';
  $('darkTune').hidden = dark.mode === 'off';
  if (document.activeElement !== $('darkFrom')) $('darkFrom').value = toInput(dark.from);
  if (document.activeElement !== $('darkTo')) $('darkTo').value = toInput(dark.to);
  $('darkBrightness').value = dark.brightness;
  $('darkContrast').value = dark.contrast;
  $('darkBrightnessOut').textContent = dark.brightness;
  $('darkContrastOut').textContent = dark.contrast;
  if (darkNight !== undefined) {
    $('darkWhen').textContent = {
      off: 'Bright pages stay bright',
      always: 'On all the time',
      system: 'On while the Mac is in dark mode',
      night: darkNight ? `On now, until ${clock(dark.to)}` : `Off now, starts at ${clock(dark.from)}`,
    }[dark.mode] || '';
  }
}

for (const b of $('darkMode').children) b.onclick = () => saveDark({ mode: b.dataset.mode });
for (const id of ['darkFrom', 'darkTo']) {
  $(id).onchange = () => { if ($(id).value) saveDark({ [id === 'darkFrom' ? 'from' : 'to']: fromInput($(id).value) }); };
}
for (const [id, key] of [['darkBrightness', 'brightness'], ['darkContrast', 'contrast']]) {
  let t;
  $(id).oninput = () => {
    $(id + 'Out').textContent = $(id).value;
    clearTimeout(t);
    t = setTimeout(() => saveDark({ [key]: Number($(id).value) }), 150);
  };
}

async function showDark() {
  const s = await chrome.storage.local.get(['dark', 'darkNight', 'darkSites']);
  const darkSites = s.darkSites || {};
  dark = { ...DARK_DEFAULT, ...s.dark };
  renderDark(!!s.darkNight);

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const res = tab && await chrome.tabs.sendMessage(tab.id, { type: 'darkStatus' }, { frameId: 0 }).catch(() => null);
  $('darkToggle').hidden = true;
  $('darkSite').textContent = '';
  if (dark.mode === 'off' || !res || !res.host) return;
  const label = {
    on: 'Darkened',
    native: 'Already dark, left alone',
    excluded: 'Off for this site',
    off: darkSites[res.host] === 'on' ? 'Always darkened here' : 'Not darkened right now',
  }[res.status];
  const action = {
    on: ['Turn off here', 'off'],
    native: ['Darken anyway', 'on'],
    excluded: ['Turn back on', null],
  }[res.status];
  $('darkSite').textContent = `${res.host}: ${label}`;
  if (!action) return;
  const button = $('darkToggle');
  button.hidden = false;
  button.textContent = action[0];
  button.onclick = async () => {
    if (action[1]) darkSites[res.host] = action[1];
    else delete darkSites[res.host];
    await chrome.storage.local.set({ darkSites });
    setTimeout(showDark, 300);
  };
}
showDark();
