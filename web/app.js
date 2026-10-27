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
  bulk: true,         // draw lines that arrive together once per frame (see receive)
  fold: false,        // fold runs of lines with the same second, level and source
  foldOpenAll: false, // what a run opens as: the last expand all / collapse all
  shown: 0,           // entries that pass the filter — the count, kept as lines come
  lastSeq: 0,         // the newest line this tab has taken
  shotLoaded: false,  // first screenshot of the current `running` session fetched
  lastRunState: null, // previous app state, to spot the edge into `starting`
};

const els = {
  log: document.getElementById('log'),
  count: document.getElementById('count'),
  search: document.getElementById('search'),
  regex: document.getElementById('regex'),
  autoscroll: document.getElementById('autoscroll'),
  bulk: document.getElementById('log-bulk'),
  fold: document.getElementById('log-fold'),
  foldAll: document.getElementById('log-fold-all'),
  statePill: document.getElementById('state-pill'),
  deviceName: document.getElementById('device-name'),
  devtools: document.getElementById('devtools'),
  connDot: document.getElementById('conn-dot'),
  toast: document.getElementById('toast'),
  shotImg: document.getElementById('shot-img'),
  screenEmpty: document.getElementById('screen-empty'),
  screenLoading: document.getElementById('screen-loading'),
  screenLoadingAnim: document.getElementById('screen-loading-anim'),
  screenLoadingLabel: document.getElementById('screen-loading-label'),
  shotAuto: document.getElementById('shot-auto'),
  textInput: document.getElementById('text-input'),
  urlInput: document.getElementById('url-input'),
  urlHistory: document.getElementById('url-history'),
  urlOpen: document.getElementById('url-open'),
};

// ---- session token ----------------------------------------------------------
// Every API call carries the session token the server wrote into index.html —
// without it any web page could drive the app through 127.0.0.1. A tab left
// open across `emu down`/`up` holds the old token: its calls get 401 and the
// page reloads itself to pick up the new one.

const TOKEN = document.querySelector('meta[name="emu-token"]')?.content || '';

function api(path, opts = {}) {
  return fetch(path, { ...opts, headers: { ...opts.headers, 'X-Emu-Token': TOKEN } }).then((r) => {
    if (r.status === 401) sessionChanged();
    return r;
  });
}

// This tab, to the server: what a command started here asks while it runs
// (an `interactive:` page action) comes to this tab alone (pages.js).
const ASKER = `tab-${Array.from(crypto.getRandomValues(new Uint8Array(8)), (b) => b.toString(16).padStart(2, '0')).join('')}`;

// For URLs that can't carry a header (WebSocket, <img>).
function withToken(url) {
  return `${url}${url.includes('?') ? '&' : '?'}token=${encodeURIComponent(TOKEN)}`;
}

// At most one reload per 10s, so a token that keeps failing can't loop.
function sessionChanged() {
  try {
    const last = Number(sessionStorage.getItem('emu.reloadedAt')) || 0;
    if (Date.now() - last < 10000) { toast('session token rejected — reload the page'); return; }
    sessionStorage.setItem('emu.reloadedAt', String(Date.now()));
  } catch (_) { /* storage blocked: reload anyway */ }
  location.reload();
}

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

// http(s) addresses in [text] as links that open in a new tab; the rest goes
// through [fmt] (escaping, the search highlight). Punctuation that ends a
// sentence, and a ) with no ( in the address, stay out of the link.
const URL_RE = /https?:\/\/[^\s<>"'`]+/g;
function linkify(text, fmt = escapeHtml) {
  let out = '', at = 0;
  for (const m of text.matchAll(URL_RE)) {
    let url = m[0];
    while (/[.,;:!?'")\]}]$/.test(url)) {
      const opens = url.split('(').length, closes = url.split(')').length;
      if (url.endsWith(')') && opens >= closes) break;
      url = url.slice(0, -1);
    }
    out += fmt(text.slice(at, m.index)) + `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${fmt(url)}</a>`;
    at = m.index + url.length;
  }
  return out + fmt(text.slice(at));
}

// hh:mm:ss of the line, as the row shows it (and runs fold by).
function clock(e) {
  if (e.clock) return e.clock;
  const ts = new Date(e.ts);
  const two = (n) => String(n).padStart(2, '0');
  return (e.clock = `${two(ts.getHours())}:${two(ts.getMinutes())}:${two(ts.getSeconds())}`);
}

// [run]: the fold the line is in — its head gets the run's toggle, the rest
// hide while the run is shut.
function rowHtml(e, run) {
  let cls = '', fold = '';
  if (run) {
    const head = run.gid === e.seq;
    cls = head ? ' head' : run.open ? ' cont' : ' cont shut';
    if (head) fold = `<span class="fold" title="Fold or unfold this run"${run.n < 2 ? ' hidden' : ''}>${foldLabel(run)}</span>`;
  }
  return `<div class="row ${e.level}${cls}"${run ? ` data-g="${run.gid}"` : ''}><span class="ts">${clock(e)}</span>`
       + `<span class="tag">${TAG[e.level] || 'I'}</span>`
       + `<span class="txt">${linkify(e.text, highlight)}</span>${fold}</div>`;
}

// ---- folding ----------------------------------------------------------------
// With fold on, consecutive shown lines with the same second (as displayed),
// level and source make one run: its first line, then "▸ N lines" to unfold the
// rest. A line that joins the last run adds to it, open or shut as it is.
// While a search is on every run shows all of its lines (they all match).

const folds = new Map();     // run id (its first line's seq) → {gid, key, n, open, head}, for the rows on screen
const foldState = new Map(); // run id → open, where the user flipped one from foldOpenAll
let tail = null;             // the last run on screen: the one the next line may join

function foldKey(e) { return `${clock(e)}|${e.level}|${e.source}`; }
function foldLabel(run) { return `${run.open ? '▾' : '▸'} ${run.n} lines`; }

function setBadge(run) {
  run.head ??= els.log.querySelector(`.row.head[data-g="${run.gid}"]`);
  const badge = run.head?.querySelector('.fold');
  if (!badge) return;
  badge.hidden = run.n < 2;
  badge.textContent = foldLabel(run);
}

function toggleRun(run, open) {
  run.open = open;
  if (open === state.foldOpenAll) foldState.delete(run.gid);
  else foldState.set(run.gid, open);
  els.log.querySelectorAll(`.row.cont[data-g="${run.gid}"]`).forEach(r => r.classList.toggle('shut', !open));
  setBadge(run);
}

function setAllFolds(open) {
  state.foldOpenAll = open;
  foldState.clear();
  for (const run of folds.values()) run.open = open;
  els.log.querySelectorAll('.row.cont').forEach(r => r.classList.toggle('shut', !open));
  els.log.querySelectorAll('.row.head').forEach(h => {
    const run = folds.get(Number(h.dataset.g));
    if (run) { run.head = h; setBadge(run); }
  });
  els.foldAll.textContent = open ? 'collapse all' : 'expand all';
}

// [list] as rows; with fold on it continues [tail] and opens runs as it goes.
function rowsHtml(list) {
  if (!state.fold) return list.map(e => rowHtml(e)).join('');
  // Runs first, so a head is written with its run's count.
  const runs = list.map((e) => {
    const key = foldKey(e);
    if (tail?.key !== key) {
      const gid = e.seq;
      tail = { gid, key, n: 0, open: foldState.get(gid) ?? state.foldOpenAll, head: null };
      folds.set(gid, tail);
    }
    tail.n++;
    return tail;
  });
  return list.map((e, i) => rowHtml(e, runs[i])).join('');
}

// Keep the DOM at MAX_ROWS, dropping from the top in one go. A run that loses
// its head to the cap goes on from its first line left.
function trimRows() {
  const log = els.log;
  const over = log.childElementCount - MAX_ROWS;
  if (over <= 0) return;
  if (state.fold) {
    for (let r = log.firstElementChild, i = 0; i < over; r = r.nextElementSibling, i++) {
      const gid = Number(r.dataset.g), run = folds.get(gid);
      if (run && --run.n === 0) { folds.delete(gid); foldState.delete(gid); }
    }
  }
  const range = document.createRange();
  range.setStartBefore(log.firstElementChild);
  range.setEndBefore(log.children[over]);
  range.deleteContents();
  const first = log.firstElementChild;
  if (state.fold && first?.classList.contains('cont')) {
    const run = folds.get(Number(first.dataset.g));
    first.classList.remove('cont', 'shut');
    first.classList.add('head');
    first.insertAdjacentHTML('beforeend', '<span class="fold" title="Fold or unfold this run" hidden></span>');
    if (run) { run.head = first; setBadge(run); }
  }
}

function render() {
  const visible = state.entries.filter(matches);
  state.shown = visible.length;
  tail = null;
  folds.clear();
  els.log.classList.toggle('searching', !!state.search);
  els.log.innerHTML = rowsHtml(visible.slice(-MAX_ROWS));
  els.count.textContent = state.shown;
  els.foldAll.hidden = !state.fold;
  els.foldAll.disabled = !!state.search; // every run is open while searching
  if (state.autoscroll) els.log.scrollTop = els.log.scrollHeight;
}

// ---- incoming lines ---------------------------------------------------------
// The server sends one message per line, so a burst (a stack trace, the 500
// lines a new connection is primed with, an app logging in a loop) comes as
// hundreds of messages. Drawn one by one, each forced a layout, a scroll and a
// recount of every entry. With bulk on (the default) lines wait for the next
// frame and go in together: one insert, one layout read, one scroll — ~16ms
// later, which the eye doesn't see. Bulk off draws each line as it comes.

let pending = [];
let flushFrame = 0;

// Every socket starts with the server's last REPLAY lines (server.dart), so a
// reconnect brings lines this tab has: those are dropped by seq. One that
// starts further back than a replay reaches is another stream (a new server
// this tab didn't reload for): the log starts over.
const REPLAY = 500;
function replayStart(seq) {
  if (seq >= state.lastSeq - REPLAY) return;
  state.entries = [];
  pending = [];
  state.lastSeq = 0;
  render();
}

function receive(e) {
  if (e.seq <= state.lastSeq) return;
  state.lastSeq = e.seq;
  pending.push(e);
  // A hidden tab gets no frames: keep the queue to what would be kept anyway.
  if (pending.length > MAX_ROWS * 3) pending.splice(0, pending.length - MAX_ROWS * 2);
  if (!state.bulk) flush();
  else if (!flushFrame) flushFrame = requestAnimationFrame(flush);
}

function flush() {
  if (flushFrame) { cancelAnimationFrame(flushFrame); flushFrame = 0; }
  const batch = pending;
  if (!batch.length) return;
  pending = [];
  state.entries.push(...batch);
  const over = state.entries.length - MAX_ROWS * 2;
  if (over > 0) state.shown -= state.entries.splice(0, over).filter(matches).length;
  const add = batch.filter(matches);
  state.shown += add.length;
  if (add.length) {
    // Read before writing anything, or the read forces a layout of its own.
    const log = els.log;
    const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 40;
    const grown = tail, n = tail?.n;
    log.insertAdjacentHTML('beforeend', rowsHtml(add.slice(-MAX_ROWS)));
    if (grown && grown.n !== n) setBadge(grown); // the batch went on with the last run
    trimRows();
    els.count.textContent = state.shown; // with the rows, in the layout the scroll below forces anyway
    if (state.autoscroll && atBottom) log.scrollTop = log.scrollHeight;
  } else {
    els.count.textContent = state.shown;
  }
}

function setStatus(s) {
  const st = s.state || 'stopped';
  els.statePill.textContent = st;
  els.statePill.className = 'pill ' + st;
  els.deviceName.textContent = s.deviceName || '';
  // Show the device as soon as the app is up, instead of waiting for ↻.
  // Re-armed when the app leaves `running`, so a restart loads a fresh frame.
  if (st === 'running' && !state.shotLoaded) {
    state.shotLoaded = true;
    refreshShot(2);
  } else if (st !== 'running') {
    state.shotLoaded = false;
  }
  // A (re)launch — first `up` or a cold restart — makes the last frame stale;
  // drop it so the loader shows instead. Hot reload/restart only pass through
  // `restarting`, where the current frame is still the right one to show.
  if (st === 'starting' && state.lastRunState !== 'starting') els.shotImg.hidden = true;
  state.lastRunState = st;
  // Until there is a frame to show, say why: the app is on its way, or not running.
  if (els.shotImg.hidden) {
    if (st === 'starting' || st === 'restarting') showLoading('starting app…');
    else if (st !== 'running') hideLoading();
  }
  // Real DevTools URL from the daemon (devtools.serve), already aimed at this
  // app's VM Service. Hidden until DevTools is actually being served.
  if (s.devToolsUri) {
    els.devtools.hidden = false;
    els.devtools.href = s.devToolsUri;
  } else {
    els.devtools.hidden = true;
  }
}

// ---- websocket --------------------------------------------------------------

function connect() {
  const ws = new WebSocket(withToken(`ws://${location.host}/api/stream?asker=${ASKER}`));
  ws.onopen = () => els.connDot.classList.add('on');
  ws.onclose = () => {
    els.connDot.classList.remove('on');
    // A refused upgrade (new server, new token) closes like a dropped one;
    // the session check reloads the page in that case (see api()).
    api('/api/session').catch(() => {}).finally(() => setTimeout(connect, 1000)); // auto-reconnect
  };
  let replayed = false; // this socket's first line seen
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'log') {
      if (!replayed) { replayed = true; replayStart(msg.entry.seq); }
      receive(msg.entry);
    }
    else if (msg.type === 'status') setStatus(msg.status);
    else if (msg.type === 'diff') onDiffChanged(); // files edited, or a launch/reload snapshotted the tree
    else if (msg.type === 'ext') onPageRun(msg);   // a page item started/finished (here, another tab or the CLI), or asks this tab
    else if (msg.type === 'pages') loadPages();    // emu.yaml changed
    else if (msg.type === 'ext-watch') onPageWatch(msg); // a file a page block watches changed
    else if (msg.type === 'ext-auto') onPageAuto(msg);   // an `auto:` action switched on or off
    else if (msg.type === 'mock') loadMocks();       // scenario switched or saved (here, another tab or the CLI)
    else if (msg.type === 'mock-hit') onMockHit(msg.hit); // the app made a request through emu
  };
}

// ---- actions ----------------------------------------------------------------

async function action(path, label) {
  toast(`${label}…`);
  try {
    const r = await api('/api/' + path, { method: 'POST' });
    const j = await r.json();
    toast(`${label}: ${j.message || (j.ok ? 'ok' : 'failed')}`);
  } catch (e) {
    toast(`${label} failed: ${e}`);
  }
}

// ---- interactive screen -----------------------------------------------------

// Refresh the screenshot. Bytes come inline (?inline=1); cache-bust each load.
// [retries]: for the automatic first load — the capture can fail right as the
// app reaches `running`, and nothing else would ask again until ↻.
function refreshShot(retries = 0) {
  if (!screenOpen()) { shotPending = true; return; } // fetched when the panel unfolds
  const img = els.shotImg;
  // Only the first frame gets the loader; later refreshes keep the old frame up.
  if (img.hidden) showLoading('loading screen…');
  img.onload = () => { img.hidden = false; els.screenEmpty.hidden = true; hideLoading(); };
  img.onerror = () => {
    if (retries > 0 && state.lastRunState === 'running') {
      setTimeout(() => refreshShot(retries - 1), 1000);
      return;
    }
    img.hidden = true;
    hideLoading();
    els.screenEmpty.textContent = 'screen unavailable (app not running?)';
  };
  img.src = withToken(`/api/screenshot?inline=1&t=${Date.now()}`);
}

// Loading placeholder: the emu mark blinking (web/loading.json, a Lottie
// animation). Created on first use; without the player it degrades to the label.
let loadingAnim = null;
function showLoading(label) {
  els.screenLoadingLabel.textContent = label;
  els.screenEmpty.hidden = true;
  els.screenLoading.hidden = false;
  if (!loadingAnim && window.lottie) {
    loadingAnim = window.lottie.loadAnimation({
      container: els.screenLoadingAnim, renderer: 'svg', loop: true, autoplay: true, path: 'loading.json',
    });
  }
  loadingAnim?.play();
}
function hideLoading() {
  els.screenLoading.hidden = true;
  els.screenEmpty.hidden = !els.shotImg.hidden;
  loadingAnim?.pause();
}
// After an input action, show its effect shortly after it lands.
function scheduleRefresh() { setTimeout(refreshShot, 350); }

// Map a pointer event on the (scaled) image to physical device pixels — the
// same space `emu tap`/`swipe` expect, so the ratio is naturalSize/displayedSize.
function toPhysical(e) {
  const img = els.shotImg;
  const rect = img.getBoundingClientRect();
  return {
    x: Math.round((e.clientX - rect.left) / rect.width * img.naturalWidth),
    y: Math.round((e.clientY - rect.top) / rect.height * img.naturalHeight),
    cx: e.clientX, cy: e.clientY,
  };
}

let pointerStart = null;
els.shotImg.addEventListener('pointerdown', (e) => { pointerStart = toPhysical(e); });
els.shotImg.addEventListener('pointerup', (e) => {
  if (!pointerStart) return;
  const end = toPhysical(e);
  const movedPx = Math.hypot(end.cx - pointerStart.cx, end.cy - pointerStart.cy);
  if (movedPx < 8) tapAt(pointerStart.x, pointerStart.y);            // a click is a tap
  else swipeAt(pointerStart.x, pointerStart.y, end.x, end.y);        // a drag is a swipe
  pointerStart = null;
});

async function tapAt(x, y) {
  toast(`tap ${x},${y}`);
  try { await api(`/api/tap?x=${x}&y=${y}`, { method: 'POST' }); } catch (_) {}
  scheduleRefresh();
}
async function swipeAt(x1, y1, x2, y2) {
  toast(`swipe → ${x2},${y2}`);
  try {
    await api(`/api/swipe?x1=${x1}&y1=${y1}&x2=${x2}&y2=${y2}`, { method: 'POST' });
  } catch (_) {}
  scheduleRefresh();
}
async function sendText() {
  const t = els.textInput.value;
  if (!t) return;
  toast('text →');
  try {
    const r = await api(`/api/text?text=${encodeURIComponent(t)}`, { method: 'POST' });
    const j = await r.json();
    toast(j.ok ? 'text sent' : `text: ${j.error || 'failed'}`);
  } catch (e) { toast(`text failed: ${e}`); }
  els.textInput.value = '';
  scheduleRefresh();
}

// Deep links: recent URLs are kept per browser (localStorage) and offered
// through the input's <datalist>. Storage can throw (private mode), so every
// access degrades to "no history" rather than breaking the button.
const URL_HISTORY_KEY = 'emu.urlHistory';
const URL_HISTORY_MAX = 10;

function loadUrlHistory() {
  // Anything but an array of strings (another app on this localhost port, a
  // hand edit) would throw in render — at page load, before connect().
  try {
    const v = JSON.parse(localStorage.getItem(URL_HISTORY_KEY));
    return Array.isArray(v) ? v.filter(u => typeof u === 'string') : [];
  } catch (_) { return []; }
}
function renderUrlHistory() {
  els.urlHistory.innerHTML = loadUrlHistory()
    .map(u => `<option value="${escapeHtml(u)}"></option>`).join('');
}
function rememberUrl(url) {
  const next = [url, ...loadUrlHistory().filter(u => u !== url)].slice(0, URL_HISTORY_MAX);
  try { localStorage.setItem(URL_HISTORY_KEY, JSON.stringify(next)); } catch (_) {}
  renderUrlHistory();
}

// One at a time: the request holds for the settle (up to ~4s), and a second
// Enter/click meanwhile would open the link again.
async function openUrl() {
  const url = els.urlInput.value.trim();
  if (!url || els.urlOpen.disabled) return;
  els.urlOpen.disabled = true;
  toast(`open ${url}`);
  try {
    const r = await api(`/api/open-url?url=${encodeURIComponent(url)}`, { method: 'POST' });
    const j = await r.json();
    if (j.ok) rememberUrl(url);
    toast(j.ok ? `opened ${url}` : `open-url: ${j.error || 'failed'}`);
  } catch (e) { toast(`open-url failed: ${e}`); }
  finally { els.urlOpen.disabled = false; }
  refreshShot(); // the server already waited for settle
}

let autoTimer = null;
function syncAutoRefresh() {
  clearInterval(autoTimer);
  autoTimer = null;
  if (els.shotAuto.checked && screenOpen()) { refreshShot(); autoTimer = setInterval(refreshShot, 1500); }
}
els.shotAuto.addEventListener('change', syncAutoRefresh);

// The screen panel folds for work that doesn't look at the device (› or s)
// into a strip on the right edge, leaving its width to the page; the strip
// (or s) unfolds it. While folded no screenshot is fetched — auto refresh
// pauses — and it unfolds with a fresh one. Kept per browser.
const SCREEN_FOLDED_KEY = 'emu.screenFolded';
let shotPending = false; // a refresh came while the panel was folded
function screenOpen() { return !document.getElementById('screen').hidden; }
function setScreenOpen(open) {
  document.getElementById('screen').hidden = !open;
  document.getElementById('screen-unfold').hidden = open;
  try {
    if (open) localStorage.removeItem(SCREEN_FOLDED_KEY);
    else localStorage.setItem(SCREEN_FOLDED_KEY, '1');
  } catch (_) {}
  syncAutoRefresh();
  if (open && shotPending) { shotPending = false; refreshShot(); }
}
document.getElementById('screen-fold').onclick = () => setScreenOpen(false);
document.getElementById('screen-unfold').onclick = () => setScreenOpen(true);
try { if (localStorage.getItem(SCREEN_FOLDED_KEY)) setScreenOpen(false); } catch (_) {}
document.getElementById('shot-refresh').onclick = () => refreshShot();
document.getElementById('text-send').onclick = sendText;
els.textInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') sendText(); });
els.urlOpen.onclick = openUrl;
els.urlInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') openUrl(); });
renderUrlHistory();

// ---- changes tab ------------------------------------------------------------
// git diff of the project in four scopes (see lib/src/diff.dart). The server
// snapshots the working tree on every launch/reload and watches the project
// for edits; either pushes a `diff` message, so the tab stays live.

const diffEls = {
  tab: document.getElementById('tab-changes'),
  badge: document.getElementById('diff-badge'),
  scope: document.getElementById('diff-scope'),
  base: document.getElementById('diff-base'),
  hideGen: document.getElementById('diff-hide-gen'),
  note: document.getElementById('diff-note'),
  files: document.getElementById('diff-files'),
  view: document.getElementById('diff-view'),
};
const diffState = { files: [], range: null, current: null, loading: false, again: false, shown: null, stale: false };
const DIFF_PREFS_KEY = 'emu.diffPrefs';

function loadDiffPrefs() {
  try {
    const p = JSON.parse(localStorage.getItem(DIFF_PREFS_KEY)) || {};
    if (p.scope) diffEls.scope.value = p.scope;
    if (typeof p.hideGen === 'boolean') diffEls.hideGen.checked = p.hideGen;
    if (p.base) diffEls.base.value = p.base;
  } catch (_) {}
}
function saveDiffPrefs() {
  try {
    localStorage.setItem(DIFF_PREFS_KEY, JSON.stringify({
      scope: diffEls.scope.value, hideGen: diffEls.hideGen.checked, base: diffEls.base.value.trim(),
    }));
  } catch (_) {}
}

function diffQuery(extra = {}) {
  const q = new URLSearchParams({ scope: diffEls.scope.value, ...extra });
  const base = diffEls.base.value.trim();
  if (diffEls.scope.value === 'base' && base) q.set('base', base);
  return q.toString();
}

// Every listing snapshots the working tree (`git add -A` into a scratch
// index), so only re-list while the tab is on screen; otherwise remember it's
// out of date and catch up when the tab is opened.
function onDiffChanged() {
  if (document.getElementById('changes').hidden) diffState.stale = true;
  else loadDiffFiles();
}

function visibleDiffFiles() {
  return diffState.files.filter(f => !(diffEls.hideGen.checked && f.generated));
}

async function loadDiffFiles() {
  // A reload notification can land mid-request; re-run once it finishes
  // rather than dropping it (the in-flight answer may predate the reload).
  if (diffState.loading) { diffState.again = true; return; }
  diffState.loading = true;
  diffState.stale = false;
  diffEls.base.hidden = diffEls.scope.value !== 'base';
  const query = diffQuery();
  try {
    const r = await api(`/api/diff/files?${query}`);
    const j = await r.json();
    // The scope/base changed while this was in flight: its answer is for the
    // old selection — drop it and fetch again (finally) instead of mislabeling.
    if (diffQuery() !== query) { diffState.again = true; return; }
    if (j.git === false) { diffEls.tab.hidden = true; return; }
    diffEls.tab.hidden = false;
    if (j.error) {
      diffState.files = [];
      diffState.range = null;
      diffEls.note.textContent = j.error;
    } else {
      diffState.files = j.files;
      diffState.range = j.from && j.to ? { from: j.from, to: j.to } : null;
      if (j.base && !diffEls.base.value) diffEls.base.placeholder = j.base;
      diffEls.note.textContent = j.note || snapshotNote(j.snapshots);
    }
    renderDiffFiles();
  } catch (_) {
    // Server unreachable — the websocket reconnect will bring us back.
  } finally {
    diffState.loading = false;
    if (diffState.again) { diffState.again = false; loadDiffFiles(); }
  }
}

function snapshotNote(snaps) {
  const scope = diffEls.scope.value;
  if ((scope !== 'reload' && scope !== 'pending') || !snaps?.length) return '';
  const last = snaps[snaps.length - 1];
  const t = new Date(last.at).toLocaleTimeString();
  return scope === 'reload' ? `${last.reason} at ${t}` : `since ${last.reason} at ${t}`;
}

function renderDiffFiles() {
  const rows = visibleDiffFiles();
  const hidden = diffState.files.length - rows.length;
  diffEls.badge.textContent = rows.length || '';
  if (!rows.some(f => f.path === diffState.current)) diffState.current = rows[0]?.path ?? null;
  diffEls.files.innerHTML = rows.map(f => `
    <div class="fitem${f.path === diffState.current ? ' active' : ''}" data-path="${escapeHtml(f.path)}" title="${escapeHtml(f.path)}">
      <span class="fname">${escapeHtml(f.path)}</span>
      ${f.binary ? '<span class="flag">bin</span>' : `<span class="plus">+${f.added}</span><span class="minus">−${f.deleted}</span>`}
    </div>`).join('')
    + (rows.length ? '' : '<div class="diff-note">no changes</div>')
    + (hidden ? `<div class="diff-note">${hidden} generated file${hidden > 1 ? 's' : ''} hidden</div>` : '');
  diffEls.files.querySelectorAll('.fitem').forEach(el => {
    el.onclick = () => { diffState.current = el.dataset.path; renderDiffFiles(); };
  });
  loadDiffPatch(rows.find(f => f.path === diffState.current));
}

async function loadDiffPatch(file) {
  const view = diffEls.view;
  if (!file) { view.innerHTML = ''; return; }
  const head = `<div class="dfile-head"><span class="path">${escapeHtml(file.path)}</span>`
    + (file.binary ? '' : `<span class="plus">+${file.added}</span><span class="minus">−${file.deleted}</span>`) + '</div>';
  if (file.binary) { view.innerHTML = head + '<div class="diff-note">binary file — contents not compared</div>'; return; }
  const path = file.path;
  try {
    // The listing's own trees: counts and patch agree, and no re-snapshot per click.
    const r = await api(`/api/diff/file?${diffQuery({ path, ...(diffState.range || {}) })}`);
    const j = await r.json();
    if (diffState.current !== path) return; // the user moved on while this loaded
    view.innerHTML = head + (j.error ? `<div class="diff-note">${escapeHtml(j.error)}</div>` : renderPatch(j.patch || ''));
    // A live refresh of the same file keeps the reader's place; a new file starts at the top.
    if (diffState.shown !== path) view.scrollTop = 0;
    diffState.shown = path;
  } catch (e) {
    view.innerHTML = head + `<div class="diff-note">failed to load: ${escapeHtml(String(e))}</div>`;
  }
}

// One file's unified diff → rows with old/new line numbers.
function renderPatch(patch) {
  let o = 0, n = 0, inHunk = false;
  const out = [];
  for (const line of patch.split('\n')) {
    const m = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (m) { o = +m[1]; n = +m[2]; inHunk = true; out.push(`<div class="hunk">${escapeHtml(line)}</div>`); continue; }
    if (!inHunk || line.startsWith('\\')) continue; // file headers, "\ No newline at end of file"
    const t = line[0], code = escapeHtml(line.slice(1)) || ' ';
    if (t === '+') out.push(`<div class="dl add"><span class="ln"></span><span class="ln">${n++}</span><span class="code">${code}</span></div>`);
    else if (t === '-') out.push(`<div class="dl del"><span class="ln">${o++}</span><span class="ln"></span><span class="code">${code}</span></div>`);
    else if (t === ' ') out.push(`<div class="dl"><span class="ln">${o++}</span><span class="ln">${n++}</span><span class="code">${code}</span></div>`);
  }
  return out.join('') || '<div class="diff-note">no textual changes</div>';
}

let debugTab = 'logs';
function showTab(name) {
  debugTab = name;
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === name));
  document.getElementById('log').hidden = name !== 'logs';
  document.getElementById('log-tools').hidden = name !== 'logs';
  document.getElementById('changes').hidden = name !== 'changes';
  document.getElementById('diff-tools').hidden = name !== 'changes';
  document.getElementById('mocks').hidden = name !== 'mocks';
  document.getElementById('mock-tools').hidden = name !== 'mocks';
  if (name === 'changes' && diffState.stale) loadDiffFiles();
  if (name === 'mocks') loadMocks();
}

document.querySelectorAll('.tab').forEach(t => { t.onclick = () => showTab(t.dataset.tab); });
diffEls.scope.addEventListener('change', () => { saveDiffPrefs(); loadDiffFiles(); });
diffEls.hideGen.addEventListener('change', () => { saveDiffPrefs(); renderDiffFiles(); });
diffEls.base.addEventListener('keydown', (e) => { if (e.key === 'Enter') { saveDiffPrefs(); loadDiffFiles(); } });
document.getElementById('diff-refresh').onclick = loadDiffFiles;
loadDiffPrefs();
loadDiffFiles(); // also decides whether the tab exists (git repo or not)

// Drag [handle] (a pointer press [e]) and call [move] with each pointer
// event, then [done] once — the panel resizers' common part.
function dragHandle(handle, e, move, done) {
  if (e.button !== 0) return;
  e.preventDefault();
  handle.setPointerCapture(e.pointerId);
  handle.classList.add('dragging');
  document.body.classList.add('resizing');
  const up = () => {
    handle.classList.remove('dragging');
    document.body.classList.remove('resizing');
    handle.removeEventListener('pointermove', move);
    handle.removeEventListener('pointerup', up);
    handle.removeEventListener('pointercancel', up);
    done();
  };
  handle.addEventListener('pointermove', move);
  handle.addEventListener('pointerup', up);
  handle.addEventListener('pointercancel', up);
}

// The screen panel's width, kept for every page; double-click resets it.
const SCREEN_W_KEY = 'emu.screenWidth';
function setScreenWidth(px) {
  document.documentElement.style.setProperty('--screen-w', px ? `${px}px` : '');
}
try { setScreenWidth(Number(localStorage.getItem(SCREEN_W_KEY)) || 0); } catch (_) {}
(() => {
  const handle = document.getElementById('screen-resize');
  let width = 0;
  handle.onpointerdown = (e) => dragHandle(handle, e, (ev) => {
    width = Math.round(Math.min(Math.max(window.innerWidth - ev.clientX, 240), window.innerWidth - 360));
    setScreenWidth(width);
  }, () => { try { localStorage.setItem(SCREEN_W_KEY, String(width)); } catch (_) {} });
  handle.ondblclick = () => {
    setScreenWidth(0);
    try { localStorage.removeItem(SCREEN_W_KEY); } catch (_) {}
  };
})();

let toastTimer;
function toast(text) {
  els.toast.textContent = text;
  els.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (els.toast.hidden = true), 2500);
}

// ---- wiring -----------------------------------------------------------------

// Inside `emu hub` (web/hub/): the hub's ☰ button floats over this page's
// top-left corner while its drawer is closed — make room for it.
window.addEventListener('message', (e) => {
  if (e.source !== window.parent || window.parent === window) return;
  if (e.data?.type !== 'emu-hub-inset') return;
  const left = Math.max(0, Math.min(80, Number(e.data.left) || 0));
  document.querySelector('.topbar').style.paddingLeft = left ? `${12 + left}px` : '';
});

document.getElementById('btn-reload').onclick = () => action('reload', 'hot reload');
document.getElementById('btn-restart').onclick = () => action('restart', 'hot restart');
document.getElementById('btn-cold').onclick = () => action('cold', 'cold restart');
document.getElementById('btn-stop').onclick = () => action('stop', 'stop');
document.getElementById('btn-shot').onclick = async () => {
  toast('capturing…');
  const r = await api('/api/screenshot', { method: 'POST' });
  const j = await r.json();
  toast(j.ok ? `saved ${j.path}` : `shot failed: ${j.error}`);
};

document.getElementById('btn-clear').onclick = () => {
  state.entries = [];
  pending = [];
  render();
  api('/api/logs/clear', { method: 'POST' });
};
document.getElementById('btn-copy').onclick = () => {
  flush(); // lines still waiting for their frame
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

// bulk and fold, kept per browser.
const LOG_PREFS_KEY = 'emu.logPrefs';
try {
  const p = JSON.parse(localStorage.getItem(LOG_PREFS_KEY)) || {};
  if (typeof p.bulk === 'boolean') state.bulk = p.bulk;
  if (typeof p.fold === 'boolean') state.fold = p.fold;
} catch (_) {}
els.bulk.checked = state.bulk;
els.fold.checked = state.fold;
els.foldAll.hidden = !state.fold;
function saveLogPrefs() {
  try { localStorage.setItem(LOG_PREFS_KEY, JSON.stringify({ bulk: state.bulk, fold: state.fold })); } catch (_) {}
}
els.bulk.addEventListener('change', () => {
  state.bulk = els.bulk.checked;
  saveLogPrefs();
  if (!state.bulk) flush();
});
els.fold.addEventListener('change', () => {
  state.fold = els.fold.checked;
  saveLogPrefs();
  flush();
  render();
});
els.foldAll.onclick = () => setAllFolds(!state.foldOpenAll);
els.log.addEventListener('click', (ev) => {
  const badge = ev.target.closest('.fold');
  const run = badge && folds.get(Number(badge.parentElement.dataset.g));
  if (run) toggleRun(run, !run.open);
});

document.querySelectorAll('.lvl').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.lvl').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    state.level = btn.dataset.level;
    render();
  });
});

// Keyboard: r = reload, R = restart, s = fold or unfold the screen panel (when not typing in a field).
document.addEventListener('keydown', (e) => {
  if (['INPUT', 'TEXTAREA', 'SELECT'].includes(e.target.tagName)) return; // don't hijack typing in any field
  if (e.metaKey || e.ctrlKey || e.altKey) return; // a browser shortcut (⌘R reloads the page, not the app)
  if (dialogOpen()) return; // a dialog is up (pages.js)
  if (e.key === 'r') action('reload', 'hot reload');
  else if (e.key === 'R') action('restart', 'hot restart');
  else if (e.key === 's') setScreenOpen(!screenOpen());
});

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

connect();
