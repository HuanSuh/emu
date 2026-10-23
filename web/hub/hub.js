'use strict';

// emu hub — a drawer of every running emu session (lib/src/hub.dart) and the
// picked session's own dashboard in a frame beside it. The hub never holds a
// session token: each dashboard loads with its own, and actions on a session
// (restart, down) go through the hub server.

const TOKEN = document.querySelector('meta[name="emu-token"]')?.content || '';
const $ = (id) => document.getElementById(id);
const KEEP_FRAMES = 3; // recently picked dashboards stay loaded (and connected)
const NARROW = matchMedia('(max-width: 900px)');

function api(path, opts = {}) {
  return fetch(path, { ...opts, headers: { ...opts.headers, 'X-Emu-Token': TOKEN, 'Content-Type': 'application/json' } })
    .then(async (r) => {
      if (r.status === 401) { location.reload(); throw new Error('hub restarted'); }
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(body.error || body.output || `HTTP ${r.status}`);
      return body;
    });
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function store(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key);
    localStorage.setItem(key, value);
  } catch (_) { /* storage blocked */ }
  return null;
}

let toastTimer;
function toast(text, err = false) {
  const t = $('toast');
  t.textContent = text;
  t.className = `toast${err ? ' err' : ''}`;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, err ? 8000 : 3000);
}

function ago(iso) {
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${Math.floor(s)}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

function home(path) {
  const m = /^\/(Users|home)\/[^/]+/.exec(path);
  return m ? `~${path.slice(m[0].length)}` : path;
}

// The macOS app (macos/) handles "open in a new window" itself.
function openWindow(url) {
  const bridge = window.webkit?.messageHandlers?.emu;
  if (bridge) bridge.postMessage({ type: 'open-window', url });
  else window.open(url, '_blank', 'noopener');
}

// ---- state -------------------------------------------------------------------

let snap = { sessions: [], starting: [], recent: [], version: '' };
const frames = new Map(); // session id → { el, port, used }

const currentId = () => (/^#\/s\/([0-9a-f]{12})$/.exec(location.hash) || [])[1] || null;
const sessionById = (id) => snap.sessions.find((s) => s.id === id);

// ---- drawer ------------------------------------------------------------------

function setDrawer(open) {
  const hub = $('hub');
  if (NARROW.matches) {
    hub.classList.toggle('narrow-open', open);
  } else {
    hub.classList.toggle('closed', !open);
    store('emu.hub.drawer', open ? '1' : '0');
  }
  const t = $('drawer-toggle');
  t.title = `${open ? 'Hide' : 'Show'} the drawer (⌘\\)`;
  t.setAttribute('aria-expanded', String(open));
  hub.classList.toggle('inset', toggleOverFrames());
  for (const f of frames.values()) sendInset(f.el);
}

// Unless the drawer is open beside the frames, ☰ floats over their top-left
// corner: ask each dashboard to leave that much room in its top bar.
const toggleOverFrames = () => NARROW.matches || $('hub').classList.contains('closed');
function sendInset(el) {
  try {
    el.contentWindow?.postMessage({ type: 'emu-hub-inset', left: toggleOverFrames() ? 40 : 0 }, new URL(el.src).origin);
  } catch (_) { /* not loaded yet: sent again on load */ }
}
const drawerOpen = () => (NARROW.matches ? $('hub').classList.contains('narrow-open') : !$('hub').classList.contains('closed'));

function renderSessions() {
  const list = $('session-list');
  const cur = currentId();
  $('session-count').textContent = snap.sessions.length ? String(snap.sessions.length) : '';
  // Same pubspec name twice (worktrees, copies): tell them apart by folder.
  const dup = new Set(snap.sessions.map((s) => s.name).filter((n, i, all) => all.indexOf(n) !== i));
  const rows = snap.sessions.map((s) => {
    const folder = dup.has(s.name) ? s.project.split('/').pop() : '';
    const device = s.device ? `${s.device.name || s.device.id}${s.device.platform ? ` · ${s.device.platform}` : ''}` : 'no device yet';
    const old = s.emuVersion && snap.version && s.emuVersion !== snap.version;
    return `<div class="row${s.id === cur ? ' on' : ''}" data-id="${esc(s.id)}">
      <button class="pick" title="${esc(s.project)}">
        <span class="l1"><i class="sdot ${esc(s.state)}" title="${esc(s.state)}"></i><span class="name">${esc(s.name)}</span>${folder && folder !== s.name ? `<span class="port">${esc(folder)}</span>` : ''}<span class="port">:${esc(s.port)}</span>
          ${s.mockPort ? '<span class="badge" title="emu.yaml mocks: on">mock</span>' : ''}
          ${old ? `<span class="badge warn" title="Started by emu ${esc(s.emuVersion)} — restart the session (emu down, emu up) to use ${esc(snap.version)}">v${esc(s.emuVersion)}</span>` : ''}</span>
        <span class="l2">${esc(device)} · ${esc(s.state)} · ${ago(s.startedAt)}</span>
      </button>
      <button class="ghost icon more" aria-haspopup="menu" aria-expanded="false" title="Session menu">⋮</button>
    </div>`;
  });
  const starting = snap.starting.map((p) => `<div class="row pending">
      <div class="pick"><span class="l1"><i class="sdot pending"></i><span class="name">${esc(p.split('/').pop())}</span></span>
      <span class="l2">starting… (emu up)</span></div></div>`);
  list.innerHTML = rows.concat(starting).join('') ||
    '<div class="note">No running session. Start one with <code>emu up</code> in a Flutter project, or from Recent projects below.</div>';
}

function renderRecent() {
  const list = $('recent-list');
  list.innerHTML = snap.recent.map((p) => {
    const busy = snap.starting.includes(p.project);
    return `<div class="rrow" title="${esc(p.project)}">
      <div class="rtext"><div>${esc(p.name)}</div><div class="sub">${esc(home(p.project))}</div></div>
      <button class="small-btn" data-start="${esc(p.project)}" ${busy ? 'disabled' : ''}>${busy ? 'starting…' : 'Start'}</button>
    </div>`;
  }).join('') || '<div class="note">Projects you start with <code>emu up</code> show up here.</div>';
}

async function loadDevices() {
  const list = $('device-list');
  list.innerHTML = '<div class="note">loading…</div>';
  try {
    const d = await api('/api/devices');
    const names = new Map(snap.sessions.map((s) => [s.id, s.name]));
    const mobile = d.devices.filter((dev) => dev.platform === 'android' || dev.platform === 'ios');
    list.innerHTML = mobile.map((dev) => {
      const users = dev.sessions.map((id) => names.get(id)).filter(Boolean);
      const held = dev.lease ? `held by ${dev.lease.project.split('/').pop()}` : users.length ? `shared: ${users.join(', ')}` : 'free';
      return `<div class="rrow"><div class="rtext"><div>${esc(dev.name)}</div>
        <div class="sub">${esc(dev.id)} · ${esc(held)}</div></div></div>`;
    }).join('') + (d.androidAvds.length
      ? `<div class="note">AVDs: ${d.androidAvds.map(esc).join(', ')}</div>` : '');
    if (!mobile.length && !d.androidAvds.length) list.innerHTML = '<div class="note">No devices.</div>';
  } catch (e) {
    list.innerHTML = `<div class="note">${esc(e.message)}</div>`;
  }
}

function renderVersion(v) {
  const b = $('version');
  b.innerHTML = `v${esc(v.running)}${v.updateAvailable ? ` · <b>new ${esc(v.latest)}</b>` : ''}`;
  b.title = v.latest ? `This emu ${v.running} · latest release ${v.latest}` : `This emu ${v.running}`;
  b.onclick = () => showVersion(v);
}

function showVersion(v) {
  const body = v.updateAvailable
    ? `<p>emu <b>${esc(v.latest)}</b> is out (this is ${esc(v.running)}). Update, then restart the hub and your sessions:</p>
       <pre>${esc(v.command)}\nemu hub --stop && emu hub</pre>
       ${v.notes ? `<p>What changed:</p><pre>${esc(v.notes)}</pre>` : ''}
       <div class="actions"><button data-copy="${esc(v.command)}" class="primary">Copy command</button></div>`
    : `<p>emu ${esc(v.running)}${v.latest ? ' — the latest release.' : ' (could not check for a newer release).'}</p>
       <div class="actions"><button id="ver-refresh">Check again</button></div>`;
  modal('Version', body);
  $('ver-refresh')?.addEventListener('click', async () => {
    renderVersion(await api('/api/version?refresh=1'));
    closeModal();
  });
}

// ---- main area: one frame per picked session -----------------------------------

function showCurrent() {
  const id = currentId();
  const s = id && sessionById(id);
  for (const [fid, f] of frames) f.el.hidden = fid !== id || !s;
  const empty = $('empty');
  if (!s) {
    empty.hidden = false;
    empty.innerHTML = id
      ? `<h2>That session ended</h2><p>Pick another one on the left, or start it again.</p>`
      : snap.sessions.length
        ? '<h2>Pick a session</h2><p>Every running emu session on this machine is listed on the left.</p>'
        : '<h2>No running session</h2><p>Run <code>emu up</code> in a Flutter project — it shows up here on its own.</p>';
    if (id && frames.has(id)) { frames.get(id).el.remove(); frames.delete(id); }
    document.title = 'emu hub';
    return;
  }
  empty.hidden = true;
  let f = frames.get(id);
  if (f && f.port !== s.port) { f.el.remove(); frames.delete(id); f = null; }
  if (!f) {
    const el = document.createElement('iframe');
    el.src = `${s.dashboard}/`;
    el.title = `${s.name} dashboard`;
    el.setAttribute('allow', 'clipboard-read; clipboard-write');
    el.addEventListener('load', () => sendInset(el));
    $('main').appendChild(el);
    f = { el, port: s.port, used: 0 };
    frames.set(id, f);
  }
  f.el.hidden = false;
  f.used = Date.now();
  document.title = `${s.name} — emu hub`;
  // Least recently picked frames beyond the limit are dropped.
  const extra = [...frames.entries()].sort((a, b) => b[1].used - a[1].used).slice(KEEP_FRAMES);
  for (const [fid, ef] of extra) { ef.el.remove(); frames.delete(fid); }
}

function pick(id) {
  if (location.hash !== `#/s/${id}`) location.hash = `#/s/${id}`;
  else showCurrent();
  if (NARROW.matches) setDrawer(false);
}

function onSnapshot(next) {
  snap = next;
  // Frames of sessions that are gone: drop (the current one shows "ended").
  for (const [fid, f] of frames) {
    if (!sessionById(fid) && fid !== currentId()) { f.el.remove(); frames.delete(fid); }
  }
  if (!currentId() && snap.sessions.length) {
    const last = store('emu.hub.last');
    const id = sessionById(last) ? last : snap.sessions[0].id;
    history.replaceState(null, '', `#/s/${id}`);
  }
  renderSessions();
  renderRecent();
  showCurrent();
}

// ---- row menu ----------------------------------------------------------------

let menuFor = null;
function openMenu(btn, s) {
  const pop = $('rowpop');
  const mac = /Mac/.test(navigator.platform);
  pop.innerHTML = `
    <button data-act="window">Open in a new window</button>
    <button data-act="copy">Copy project path</button>
    ${mac ? '<button data-act="reveal">Show in Finder</button>' : ''}
    <hr />
    <button data-act="reload">Hot reload</button>
    <button data-act="restart">Hot restart</button>
    <hr />
    <button data-act="down" class="danger">Stop session…</button>`;
  const r = btn.getBoundingClientRect();
  pop.hidden = false;
  const h = pop.offsetHeight;
  pop.style.left = `${Math.min(r.left, innerWidth - pop.offsetWidth - 8)}px`;
  pop.style.top = r.bottom + h + 8 > innerHeight ? `${r.top - h - 4}px` : `${r.bottom + 4}px`;
  btn.setAttribute('aria-expanded', 'true');
  menuFor = { btn, s };
  pop.querySelector('button')?.focus();
}

function closeMenu() {
  if (!menuFor) return;
  menuFor.btn.setAttribute('aria-expanded', 'false');
  $('rowpop').hidden = true;
  menuFor = null;
}

async function act(s, action) {
  closeMenu();
  switch (action) {
    case 'window': return openWindow(`${s.dashboard}/`);
    case 'copy':
      try { await navigator.clipboard.writeText(s.project); toast('Copied the project path'); }
      catch (_) { toast(s.project); }
      return;
    case 'down': {
      const ok = await confirmModal(`Stop ${s.name}?`,
        `<p>Runs <code>emu down</code> for <code>${esc(home(s.project))}</code>: the app and its dashboard stop. Agents or terminals using this session lose it too.</p>`,
        'Stop session');
      if (!ok) return;
      break;
    }
  }
  try {
    await api(`/api/sessions/${s.id}/${action}`, { method: 'POST' });
    if (action === 'down') toast(`${s.name}: session stopped`);
    else if (action !== 'reveal') toast(`${s.name}: ${action === 'reload' ? 'hot reload' : 'hot restart'} sent`);
  } catch (e) {
    toast(`${s.name}: ${e.message}`, true);
  }
}

// ---- modal -------------------------------------------------------------------

let modalDone = null;
function modal(title, html) {
  $('modal-title').textContent = title;
  $('modal-body').innerHTML = html;
  $('modal').hidden = false;
}
function closeModal(result = false) {
  $('modal').hidden = true;
  const done = modalDone;
  modalDone = null;
  done?.(result);
}
function confirmModal(title, html, ok) {
  modal(title, `${html}<div class="actions"><button data-close>Cancel</button><button class="danger" data-ok>${esc(ok)}</button></div>`);
  return new Promise((resolve) => { modalDone = resolve; });
}

// ---- live updates ------------------------------------------------------------

let retry = 500;
let online = true; // tell once when the hub goes away, once when it is back
function connect() {
  const ws = new WebSocket(`ws://${location.host}/api/stream?token=${encodeURIComponent(TOKEN)}`);
  ws.onopen = () => {
    retry = 500;
    if (!online) toast('Reconnected to the hub');
    online = true;
    $('drawer').classList.remove('offline');
  };
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'sessions') onSnapshot(msg);
    if (msg.type === 'started') {
      const name = msg.project.split('/').pop();
      toast(msg.ok ? `${name}: ${msg.state || 'started'}` : `${name}: emu up failed\n${msg.output || ''}`, !msg.ok);
    }
  };
  ws.onclose = () => {
    if (online) toast('Lost the hub — reconnecting… (is `emu hub` still running?)', true);
    online = false;
    $('drawer').classList.add('offline');
    // A restarted hub has a new token: this call gets 401 and reloads the page.
    setTimeout(() => { api('/api/sessions').then(onSnapshot).catch(() => {}); connect(); }, retry);
    retry = Math.min(retry * 2, 8000);
  };
}

// ---- wiring ------------------------------------------------------------------

$('session-list').addEventListener('click', (e) => {
  const row = e.target.closest('.row[data-id]');
  if (!row) return;
  const s = sessionById(row.dataset.id);
  if (!s) return;
  const more = e.target.closest('.more');
  if (more) {
    e.stopPropagation();
    if (menuFor?.btn === more) closeMenu(); else { closeMenu(); openMenu(more, s); }
    return;
  }
  store('emu.hub.last', s.id);
  pick(s.id);
});

$('rowpop').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-act]');
  if (b && menuFor) act(menuFor.s, b.dataset.act);
});

$('recent-list').addEventListener('click', async (e) => {
  const b = e.target.closest('button[data-start]');
  if (!b) return;
  b.disabled = true;
  b.textContent = 'starting…';
  try {
    await api('/api/projects/start', { method: 'POST', body: JSON.stringify({ project: b.dataset.start }) });
  } catch (err) {
    toast(err.message, true);
    renderRecent();
  }
});

for (const t of document.querySelectorAll('[data-fold]')) {
  const sec = t.closest('.dsec');
  const key = `emu.hub.fold.${t.dataset.fold}`;
  if (store(key) === '1') sec.classList.add('open');
  t.addEventListener('click', () => {
    const open = sec.classList.toggle('open');
    store(key, open ? '1' : '0');
    if (open && t.dataset.fold === 'devices') loadDevices();
  });
}
if ($('device-list').closest('.dsec').classList.contains('open')) loadDevices();

$('drawer-toggle').addEventListener('click', () => setDrawer(!drawerOpen()));
$('drawer-back').addEventListener('click', () => setDrawer(false));
$('modal-close').addEventListener('click', () => closeModal(false));
$('modal').addEventListener('click', (e) => {
  if (e.target === $('modal') || e.target.closest('[data-close]')) closeModal(false);
  else if (e.target.closest('[data-ok]')) closeModal(true);
  const copy = e.target.closest('[data-copy]');
  if (copy) navigator.clipboard.writeText(copy.dataset.copy).then(() => toast('Copied'), () => {});
});
document.addEventListener('click', (e) => {
  if (menuFor && !e.target.closest('#rowpop')) closeMenu();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (!$('modal').hidden) return closeModal(false);
    if (menuFor) return closeMenu();
    if (NARROW.matches && drawerOpen()) return setDrawer(false);
  }
  if (e.key === '\\' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); setDrawer(!drawerOpen()); }
  if (menuFor && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
    e.preventDefault();
    const items = [...$('rowpop').querySelectorAll('button')];
    const i = items.indexOf(document.activeElement);
    items[(i + (e.key === 'ArrowDown' ? 1 : items.length - 1)) % items.length].focus();
  }
});
addEventListener('hashchange', () => {
  const id = currentId();
  if (id) store('emu.hub.last', id);
  renderSessions();
  showCurrent();
});
NARROW.addEventListener('change', () => setDrawer(!NARROW.matches && store('emu.hub.drawer') !== '0'));

setDrawer(!NARROW.matches && store('emu.hub.drawer') !== '0');
api('/api/sessions').then(onSnapshot).catch((e) => toast(e.message, true));
api('/api/version').then(renderVersion).catch(() => {});
setInterval(renderSessions, 30000); // keep the "2m" ages fresh between updates
connect();
