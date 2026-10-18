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
  if (state.domains && state.domains.length) $('sites').textContent = state.domains.join(', ');
  if (pending) $('pending').textContent = `${pending} events waiting to sync`;
});

const clock = (m) => new Date(2000, 0, 1, Math.floor(m / 60), m % 60)
  .toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });

async function showDark() {
  const $ = (id) => document.getElementById(id);
  const { dark, darkNight, darkSites = {} } = await chrome.storage.local.get(['dark', 'darkNight', 'darkSites']);
  if (!dark || dark.mode === 'off') return;
  $('dark').hidden = false;
  $('darkWhen').textContent = {
    always: 'On all the time',
    system: 'On while the Mac is in dark mode',
    night: darkNight ? `On until ${clock(dark.to)}` : `Starts at ${clock(dark.from)}`,
  }[dark.mode] || '';

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const res = tab && await chrome.tabs.sendMessage(tab.id, { type: 'darkStatus' }, { frameId: 0 }).catch(() => null);
  $('darkToggle').hidden = true;
  if (!res || !res.host) return;
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
