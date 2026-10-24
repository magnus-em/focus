const target = location.hash.slice(1);
const auto = new URLSearchParams(location.search).has('auto');
const $ = (id) => document.getElementById(id);
let eventId = null;
let domain = '';

function minutesSince(ms) {
  const m = Math.max(0, Math.round((Date.now() - ms) / 60000));
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
}

function render(state, blocked) {
  const label = state.label || 'Focus';
  $('label').textContent = state.paused ? `${label} · paused` : label;
  $('label').classList.toggle('focus', !!state.isFocus);
  const parts = [];
  if (state.sessionStart) parts.push(`${minutesSince(state.sessionStart)} into this block`);
  if (!state.connected) parts.push('Focus app not reachable');
  $('context').textContent = parts.join(' · ');
  $('unblocked').hidden = blocked;
  $('leave').hidden = !blocked;
  $('later').hidden = !blocked || !/^https?:/.test(target);
  $('reasons').hidden = !blocked || !eventId;
  $('bypass').hidden = !blocked || !state.bypassAllowed;
  $('locked').hidden = !blocked || state.bypassAllowed;
}

async function init() {
  $('continue').href = target;
  const res = await chrome.runtime.sendMessage({ type: 'blocked', url: target, auto });
  if (!res) return;
  eventId = res.id;
  domain = res.domain;
  $('domain').textContent = domain || 'This site';
  const n = res.state.todayBlocked || 0;
  if (n > 0) $('count').textContent = n === 1 ? 'First block today.' : `Block #${n} today.`;
  render(res.state, res.blocked);
}

$('leave').onclick = () => chrome.runtime.sendMessage({ type: 'leave' });

$('saveLater').onclick = async () => {
  $('saveLater').disabled = true;
  $('saveLater').textContent = 'Saving…';
  const res = await chrome.runtime.sendMessage({ type: 'readLater', url: target });
  const note = $('savedNote');
  note.hidden = false;
  if (res && res.status === 'saved') {
    $('saveLater').textContent = 'Saved to Reader';
    note.textContent = 'It\'s in your Later list. Back to work in a moment.';
    setTimeout(() => chrome.runtime.sendMessage({ type: 'leave' }), 1500);
  } else if (res && res.status === 'queued') {
    $('saveLater').textContent = 'Saved for later';
    note.textContent = res.reason || 'Focus will send it to Reader once it can.';
    setTimeout(() => chrome.runtime.sendMessage({ type: 'leave' }), 2500);
  } else {
    $('saveLater').disabled = false;
    $('saveLater').textContent = 'Try again';
    note.textContent = (res && res.error) || 'Couldn\'t save it.';
  }
};

for (const b of document.querySelectorAll('[data-r]')) {
  b.onclick = () => {
    document.querySelectorAll('[data-r]').forEach((x) => x.classList.toggle('on', x === b));
    chrome.runtime.sendMessage({ type: 'reason', id: eventId, reason: b.dataset.r });
  };
}

$('bypassOpen').onclick = () => {
  $('bypassOpen').hidden = true;
  $('bypassForm').hidden = false;
  $('bypassReason').focus();
  let left = 30;
  const tick = () => {
    const ready = left <= 0 && $('bypassReason').value.trim().length >= 10;
    $('bypassGo').disabled = !ready;
    $('bypassGo').textContent = left > 0 ? `Wait ${left}s` : ready ? 'Unlock 5 min' : 'Say why (10+ chars)';
  };
  const t = setInterval(() => { left--; tick(); if (left <= 0) clearInterval(t); }, 1000);
  $('bypassReason').oninput = tick;
  tick();
};

$('bypassGo').onclick = async () => {
  const res = await chrome.runtime.sendMessage({
    type: 'bypass', id: eventId, domain, reason: $('bypassReason').value.trim(),
  });
  if (res && res.ok) location.replace(target);
};

setInterval(async () => {
  const res = await chrome.runtime.sendMessage({ type: 'status', url: target });
  if (res) render(res.state, res.blocked);
}, 5000);

init();
