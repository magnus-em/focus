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
