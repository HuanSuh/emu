'use strict';

// emu dashboard — connects to the server's WebSocket for live logs/status and
// drives the engine through the REST API. One engine, two frontends; this is
// the second one.

const MAX_ROWS = 5000; // keep the DOM bounded
const state = {
  entries: [],        // all received {seq, ts, level, source, text}
  level: 'all',
  search: '',
  regex: false,
  autoscroll: true,
};

const els = {
  log: document.getElementById('log'),
  count: document.getElementById('count'),
  search: document.getElementById('search'),
  regex: document.getElementById('regex'),
  autoscroll: document.getElementById('autoscroll'),
  statePill: document.getElementById('state-pill'),
  deviceName: document.getElementById('device-name'),
  devtools: document.getElementById('devtools'),
  connDot: document.getElementById('conn-dot'),
  toast: document.getElementById('toast'),
};

const LEVEL_RANK = { debug: 0, info: 1, system: 1, warn: 2, error: 3 };
const TAG = { error: 'E', warn: 'W', debug: 'D', system: '•', info: 'I' };

// ---- rendering --------------------------------------------------------------

function matches(entry) {
  if (state.level !== 'all') {
    if ((LEVEL_RANK[entry.level] ?? 1) < LEVEL_RANK[state.level]) return false;
  }
  if (state.search) {
    if (state.regex) {
      try {
        if (!state._re) state._re = new RegExp(state.search, 'i');
        if (!state._re.test(entry.text)) return false;
      } catch (_) { /* invalid regex: show everything */ }
    } else if (!entry.text.toLowerCase().includes(state.search.toLowerCase())) {
      return false;
    }
  }
  return true;
}

function highlight(text) {
  if (!state.search) return escapeHtml(text);
  let re;
  try {
    re = state.regex ? new RegExp('(' + state.search + ')', 'ig')
                     : new RegExp('(' + escapeRe(state.search) + ')', 'ig');
  } catch (_) { return escapeHtml(text); }
  return escapeHtml(text).replace(re, '<mark>$1</mark>');
}

function rowHtml(e) {
  const ts = new Date(e.ts);
  const hh = String(ts.getHours()).padStart(2, '0');
  const mm = String(ts.getMinutes()).padStart(2, '0');
  const ss = String(ts.getSeconds()).padStart(2, '0');
  return `<div class="row ${e.level}"><span class="ts">${hh}:${mm}:${ss}</span>`
       + `<span class="tag">${TAG[e.level] || 'I'}</span>`
       + `<span class="txt">${highlight(e.text)}</span></div>`;
}

function render() {
  const visible = state.entries.filter(matches);
  const shown = visible.slice(-MAX_ROWS);
  els.log.innerHTML = shown.map(rowHtml).join('');
  els.count.textContent = visible.length;
  if (state.autoscroll) els.log.scrollTop = els.log.scrollHeight;
}

function appendEntry(e) {
  state.entries.push(e);
  if (state.entries.length > MAX_ROWS * 2) {
    state.entries.splice(0, state.entries.length - MAX_ROWS * 2);
  }
  if (!matches(e)) return;
  const atBottom = els.log.scrollTop + els.log.clientHeight >= els.log.scrollHeight - 40;
  els.log.insertAdjacentHTML('beforeend', rowHtml(e));
  while (els.log.childElementCount > MAX_ROWS) els.log.removeChild(els.log.firstChild);
  els.count.textContent = state.entries.filter(matches).length;
  if (state.autoscroll && atBottom) els.log.scrollTop = els.log.scrollHeight;
}

function setStatus(s) {
  const st = s.state || 'stopped';
  els.statePill.textContent = st;
  els.statePill.className = 'pill ' + st;
  els.deviceName.textContent = s.deviceName || '';
  if (s.vmServiceUri) {
    els.devtools.hidden = false;
    els.devtools.href = s.vmServiceUri.replace(/^ws/, 'http');
  } else {
    els.devtools.hidden = true;
  }
}

// ---- websocket --------------------------------------------------------------

function connect() {
  const ws = new WebSocket(`ws://${location.host}/api/stream`);
  ws.onopen = () => els.connDot.classList.add('on');
  ws.onclose = () => {
    els.connDot.classList.remove('on');
    setTimeout(connect, 1000); // auto-reconnect
  };
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'log') appendEntry(msg.entry);
    else if (msg.type === 'status') setStatus(msg.status);
  };
}

// ---- actions ----------------------------------------------------------------

async function action(path, label) {
  toast(`${label}…`);
  try {
    const r = await fetch('/api/' + path, { method: 'POST' });
    const j = await r.json();
    toast(`${label}: ${j.message || (j.ok ? 'ok' : 'failed')}`);
  } catch (e) {
    toast(`${label} failed: ${e}`);
  }
}

let toastTimer;
function toast(text) {
  els.toast.textContent = text;
  els.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (els.toast.hidden = true), 2500);
}

// ---- wiring -----------------------------------------------------------------

document.getElementById('btn-reload').onclick = () => action('reload', 'hot reload');
document.getElementById('btn-restart').onclick = () => action('restart', 'hot restart');
document.getElementById('btn-cold').onclick = () => action('cold', 'cold restart');
document.getElementById('btn-stop').onclick = () => action('stop', 'stop');
document.getElementById('btn-shot').onclick = async () => {
  toast('capturing…');
  const r = await fetch('/api/screenshot', { method: 'POST' });
  const j = await r.json();
  toast(j.ok ? `saved ${j.path}` : `shot failed: ${j.error}`);
};

document.getElementById('btn-clear').onclick = () => {
  state.entries = [];
  render();
  fetch('/api/logs/clear', { method: 'POST' });
};
document.getElementById('btn-copy').onclick = () => {
  const text = state.entries.filter(matches).map(e => e.text).join('\n');
  navigator.clipboard.writeText(text).then(() => toast('copied'));
};

els.search.addEventListener('input', () => {
  state.search = els.search.value;
  state._re = null;
  render();
});
els.regex.addEventListener('change', () => { state.regex = els.regex.checked; state._re = null; render(); });
els.autoscroll.addEventListener('change', () => { state.autoscroll = els.autoscroll.checked; });

document.querySelectorAll('.lvl').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.lvl').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.level = btn.dataset.level;
    render();
  });
});

// Keyboard: r = reload, R = restart (when not typing in the search box).
document.addEventListener('keydown', (e) => {
  if (e.target === els.search) return;
  if (e.key === 'r') action('reload', 'hot reload');
  else if (e.key === 'R') action('restart', 'hot restart');
});

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

connect();
