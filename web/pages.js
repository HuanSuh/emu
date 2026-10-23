'use strict';

// Dashboard pages (emu.yaml `pages:`). Loaded after app.js and shares its
// globals (api, toast, escapeHtml, state …); app.js calls back into this file
// only from event handlers (WebSocket messages, keys), once both have loaded.

// ---- dashboard pages ---------------------------------------------------------
// Project tools declared in emu.yaml (`pages:`): a toolbar of toggles and
// actions plus blocks. The server runs the commands and this only shows what
// they print. The top bar's app controls and the screen panel stay put on
// every page — a page's work ends in a reload and a look at the screen.
//
// The first list on a page holds its selection: the picked row is sent with
// every run and block fetch, and fills `{{selected.<col>}}` server-side.

const pageEls = {
  tabs: document.getElementById('page-tabs'),
  bar: document.getElementById('pagebar'),
  body: document.getElementById('ext-page'),
  debugToolbar: document.getElementById('debug-toolbar'),
  confirm: document.getElementById('confirm'),
  confirmDim: document.getElementById('confirm-dim'),
};
const pageState = {
  pages: [],
  problems: [],
  current: 'debug',
  last: {},              // page id → its last run
  running: new Set(),    // 'page.item' in flight, from any client
  toggles: {},           // 'page.item' → {ok, on, detail, error}
  selected: {},          // page id → key value of the picked row
  seg: {},               // 'page.block' → chosen segment
  data: {},              // 'page.block' → {loading, result, query}
  search: {},            // 'page.block' → filter text
  input: {},             // 'page.form' → {field: value}
  stale: new Set(),      // 'page.block' changed (watch) while its page was hidden
  sizes: {},             // page id → {left, bottom}: dragged panel sizes, as % of the page body
};
const PAGE_KEY = 'emu.page';
const PAGE_PREFS_KEY = 'emu.pagePrefs';
try {
  pageState.current = localStorage.getItem(PAGE_KEY) || 'debug';
  const prefs = JSON.parse(localStorage.getItem(PAGE_PREFS_KEY)) || {};
  if (prefs.selected && typeof prefs.selected === 'object') pageState.selected = prefs.selected;
  if (prefs.seg && typeof prefs.seg === 'object') pageState.seg = prefs.seg;
  if (prefs.input && typeof prefs.input === 'object') pageState.input = prefs.input;
  if (prefs.sizes && typeof prefs.sizes === 'object') pageState.sizes = prefs.sizes;
} catch (_) {}
function savePagePrefs() {
  try {
    localStorage.setItem(PAGE_PREFS_KEY, JSON.stringify({ selected: pageState.selected, seg: pageState.seg, input: pageState.input, sizes: pageState.sizes }));
  } catch (_) {}
}

const currentPage = () => pageState.pages.find(p => p.id === pageState.current);
const blockKey = (page, block) => `${page.id}.${block.id}`;
const itemKey = (page, item) => `${page.id}.${item.id}`;
const usesSelection = (x) => (x.uses || []).some(u => u.startsWith('selected.'));

async function loadPages() {
  try {
    const j = await (await api('/api/pages')).json();
    pageState.pages = j.pages || [];
    pageState.problems = j.problems || [];
    Object.assign(pageState.last, j.last || {});
  } catch (_) { return; }
  if (pageState.current !== 'debug' && !currentPage()) pageState.current = 'debug';
  renderPageTabs();
  showPage(pageState.current);
}

function renderPageTabs() {
  const tabs = [{ id: 'debug', title: 'Debug' }, ...pageState.pages];
  const problems = pageState.problems;
  pageEls.tabs.hidden = !pageState.pages.length && !problems.length;
  pageEls.tabs.innerHTML = tabs.map(p =>
    `<button class="page-tab${p.id === pageState.current ? ' active' : ''}" data-page="${escapeHtml(p.id)}"`
    + `${p.id === 'debug' ? '' : ' title="from emu.yaml"'}>${escapeHtml(p.title)}`
    + `${p.id === 'debug' ? '' : '<span class="page-src">yaml</span>'}</button>`).join('')
    + (problems.length
      ? `<span class="page-problems" title="${escapeHtml(problems.join('\n'))}">⚠ ${problems.length} in emu.yaml pages</span>` : '');
  pageEls.tabs.querySelectorAll('.page-tab').forEach(b => { b.onclick = () => showPage(b.dataset.page); });
}

function showPage(id) {
  pageState.current = id;
  try { localStorage.setItem(PAGE_KEY, id); } catch (_) {}
  pageEls.tabs.querySelectorAll('.page-tab').forEach(b => b.classList.toggle('active', b.dataset.page === id));
  const page = currentPage();
  const debug = !page;
  pageEls.debugToolbar.hidden = !debug;
  pageEls.bar.hidden = debug;
  pageEls.body.hidden = debug;
  if (debug) { showTab(debugTab); return; }
  for (const id of ['log', 'changes', 'mocks']) document.getElementById(id).hidden = true;
  renderPageBar(page);
  renderPageBody(page);
  refreshToggles(page);
  loadBlocks(page, page.blocks);
}

// ---- selection ---------------------------------------------------------------

function selectionList(page) { return page.blocks.find(b => b.id === page.selection); }

function rowKeyOf(block, row) {
  const col = block.key || block.columns[0]?.key || Object.keys(row)[0];
  return row[col] === undefined ? undefined : String(row[col]);
}

// The picked row of the page's selection list, as last fetched (or null).
function selectedRow(page) {
  const list = selectionList(page);
  const key = pageState.selected[page.id];
  const rows = list && pageState.data[blockKey(page, list)]?.result?.rows;
  if (key === undefined || !rows) return null;
  return rows.find(r => rowKeyOf(list, r) === key) || null;
}

function select(page, list, row) {
  const key = rowKeyOf(list, row);
  if (pageState.selected[page.id] === key) return;
  pageState.selected[page.id] = key;
  savePagePrefs();
  renderListRows(page, list);
  renderPageBar(page);
  // Everything that reads {{selected.*}} follows the pick.
  loadBlocks(page, page.blocks.filter(b => b.id !== list.id && usesSelection(b)));
}

// Placeholder values sent with a run: the picked row and, for a row button, its row.
function runValues(page, row) {
  const v = {};
  const sel = selectedRow(page);
  if (sel) v.selected = sel;
  if (row) v.row = row;
  return v;
}

// ---- toolbar -----------------------------------------------------------------

function renderPageBar(page) {
  const hasSelection = !!selectedRow(page);
  pageEls.bar.innerHTML = `<span class="title">${escapeHtml(page.title)}</span>` + page.toolbar.map(item => {
    const key = itemKey(page, item);
    const busy = pageState.running.has(key);
    const blocked = usesSelection(item) && !hasSelection;
    if (item.kind === 'toggle') {
      const st = pageState.toggles[key];
      const on = st?.ok && st.on;
      const label = busy ? '…' : !st ? '' : !st.ok ? '?' : on ? 'ON' : 'OFF';
      const title = st && !st.ok ? st.error : `on: ${item.on}\noff: ${item.off}`;
      return `<button class="ext-toggle${on ? ' on' : ''}${busy ? ' busy' : ''}" data-item="${escapeHtml(item.id)}"`
        + ` role="switch" aria-checked="${on ? 'true' : 'false'}" title="${escapeHtml(title)}"${blocked ? ' disabled' : ''}>`
        + `<span class="ext-sw"></span>${escapeHtml(item.label)} <span class="ext-state">${label}</span>`
        + (st?.ok && st.detail ? `<span class="ext-detail">${escapeHtml(st.detail)}</span>` : '') + '</button>';
    }
    const title = blocked ? 'select a row first' : item.command;
    return `<button class="ext-action${item.confirm ? ' warnish' : ''}${busy ? ' busy' : ''}" data-item="${escapeHtml(item.id)}"`
      + ` title="${escapeHtml(title)}"${blocked ? ' disabled' : ''}>${escapeHtml(item.label)}${busy ? ' …' : ''}</button>`;
  }).join('') + '<span class="grow"></span><button id="pages-refresh" title="Re-read emu.yaml">↻</button>';
  pageEls.bar.querySelectorAll('[data-item]').forEach(el => {
    el.onclick = () => {
      const item = page.toolbar.find(i => i.id === el.dataset.item);
      if (!item) return;
      const body = runValues(page);
      if (item.kind === 'toggle') {
        const st = pageState.toggles[itemKey(page, item)];
        body.on = !(st?.ok && st.on);
      }
      runItem(page, item, itemKey(page, item), `/api/pages/${encodeURIComponent(page.id)}/run/${encodeURIComponent(item.id)}`, body);
    };
  });
  document.getElementById('pages-refresh').onclick = loadPages;
}

async function refreshToggles(page) {
  const sel = selectedRow(page);
  const q = new URLSearchParams();
  if (sel) for (const [k, v] of Object.entries(sel)) q.set(`selected.${k}`, typeof v === 'string' ? v : JSON.stringify(v));
  await Promise.all(page.toolbar.filter(i => i.kind === 'toggle').map(async (t) => {
    try {
      const r = await api(`/api/pages/${encodeURIComponent(page.id)}/state/${encodeURIComponent(t.id)}?${q}`);
      pageState.toggles[itemKey(page, t)] = await r.json();
    } catch (_) { /* server gone: the websocket reconnect reloads */ }
  }));
  if (currentPage() === page) renderPageBar(page);
}

// Run a toolbar item or row button. An item marked confirm: true answers 428
// with the exact command (values filled in); that is what the dialog shows.
async function runItem(page, item, key, url, body) {
  if (pageState.running.has(key)) return;
  pageState.running.add(key);
  renderRunning(page);
  try {
    const post = (b) => api(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(b) });
    let r = await post(body);
    let j = await r.json();
    if (r.status === 428 && j.needsConfirm) {
      pageState.running.delete(key);
      renderRunning(page);
      if (!(await confirmRun(item, j.command))) return;
      pageState.running.add(key);
      renderRunning(page);
      r = await post({ ...body, confirmed: true });
      j = await r.json();
    }
    if (j.exitCode === undefined) toast(`${item.label}: ${j.error || 'failed'}`); // busy, no selection, unknown
    else finishRun(page, item, key, j);
  } catch (e) {
    toast(`${item.label} failed: ${e}`);
  } finally {
    pageState.running.delete(key);
    if (currentPage() === page) renderRunning(page);
  }
}

function renderRunning(page) {
  if (currentPage() !== page) return;
  renderPageBar(page);
  renderOutputs(page);
  for (const b of page.blocks) {
    if (b.kind === 'list') renderListRows(page, b);
    else if (b.kind === 'form') renderFormButtons(page, b);
  }
}

function finishRun(page, item, key, run) {
  pageState.last[page.id] = run;
  if (run.state) pageState.toggles[key] = run.state;
  toast(`${item.label}: ${run.ok ? 'done' : run.error || 'failed'}${run.then ? ` · ${run.then.action}` : ''}`);
  if (item.openUrl && run.ok) refreshShot(); // the server already waited for the app to settle
  else if (run.then?.ok) scheduleRefresh(); // reloaded: show the new screen
}

// Runs started anywhere (this tab, another tab, `emu run`) show up here too.
function onPageRun(msg) {
  const page = pageState.pages.find(p => p.id === msg.page);
  if (!page) return;
  const key = `${msg.page}.${msg.item}`;
  if (msg.event === 'started') pageState.running.add(key);
  else if (msg.event === 'finished') {
    pageState.running.delete(key);
    pageState.last[page.id] = msg.run;
    if (msg.run?.state) pageState.toggles[key] = msg.run.state;
  }
  if (currentPage() !== page) return;
  renderRunning(page);
  if (msg.event !== 'finished') return;
  // A command may have changed what the toggles and blocks report.
  refreshToggles(page);
  loadBlocks(page, page.blocks);
}

// A watched file changed: fetch those blocks again (or on the next visit).
function onPageWatch(msg) {
  for (const [pageId, ids] of Object.entries(msg.blocks || {})) {
    const page = pageState.pages.find(p => p.id === pageId);
    if (!page) continue;
    const blocks = page.blocks.filter(b => ids.includes(b.id));
    if (currentPage() === page) {
      for (const b of blocks) if (b.kind === 'html') loadFrame(page, b); // its file may be what changed
      loadBlocks(page, blocks);
    }
    else for (const b of blocks) pageState.stale.add(blockKey(page, b));
  }
}

// ---- blocks ------------------------------------------------------------------

function renderPageBody(page) {
  const areas = { left: [], main: [], bottom: [] };
  for (const b of page.blocks) areas[b.area]?.push(b);
  const body = pageEls.body;
  body.classList.toggle('no-left', !areas.left.length);
  body.classList.toggle('no-main', !areas.main.length);
  body.innerHTML = page.blocks.length
    ? ['left', 'main', 'bottom'].map(a => `<div class="ext-area ${a}" data-area="${a}"></div>`).join('')
    : '<div class="ext-empty">This page has no blocks — results show up in the Logs tab.</div>';
  for (const [area, blocks] of Object.entries(areas)) {
    const host = body.querySelector(`[data-area="${area}"]`);
    for (const b of blocks) {
      host?.insertAdjacentHTML('beforeend', `<section class="ext-block ${b.kind}" data-block="${escapeHtml(b.id)}"></section>`);
      const el = blockEl(b);
      if (b.kind === 'list') initList(page, b, el);
      else if (b.kind === 'diff') initDiff(page, b, el);
      else if (b.kind === 'html') initHtml(page, b, el);
      else if (b.kind === 'form') initForm(page, b, el);
    }
  }
  addResizers(page, areas);
  renderOutputs(page);
}

// ---- panel sizes ---------------------------------------------------------------
// A handle on the left area's right edge and one on the bottom area's top edge.
// Sizes are kept per page as a share of the page body, so they survive a
// window resize; a double-click puts the default back.

const MIN_PANEL = 120; // px any area keeps while dragging

function applySizes(page) {
  const size = pageState.sizes[page.id] || {};
  const body = pageEls.body;
  body.style.setProperty('--ext-left', size.left ? `${size.left}%` : '');
  body.style.setProperty('--ext-bottom', size.bottom ? `${size.bottom}%` : '');
  body.classList.toggle('sized-bottom', !!size.bottom);
}

function addResizers(page, areas) {
  applySizes(page);
  const body = pageEls.body;
  const hasRight = areas.main.length || areas.bottom.length;
  if (areas.left.length && hasRight) addResizer(page, body.querySelector('[data-area="left"]'), 'col');
  if (areas.bottom.length && areas.main.length) addResizer(page, body.querySelector('[data-area="bottom"]'), 'row');
}

function addResizer(page, host, axis) {
  const handle = document.createElement('div');
  handle.className = `ext-resize ${axis}`;
  handle.title = 'Drag to resize · double-click to reset';
  host.appendChild(handle);
  const key = axis === 'col' ? 'left' : 'bottom';
  handle.onpointerdown = (e) => {
    const box = pageEls.body.getBoundingClientRect();
    dragHandle(handle, e, (ev) => {
      const pct = axis === 'col'
        ? (Math.min(Math.max(ev.clientX - box.left, MIN_PANEL), box.width - MIN_PANEL) / box.width) * 100
        : (Math.min(Math.max(box.bottom - ev.clientY, MIN_PANEL / 2), box.height - MIN_PANEL / 2) / box.height) * 100;
      pageState.sizes[page.id] = { ...pageState.sizes[page.id], [key]: Math.round(pct * 10) / 10 };
      applySizes(page);
    }, savePagePrefs);
  };
  handle.ondblclick = () => {
    const size = { ...pageState.sizes[page.id] };
    delete size[key];
    if (Object.keys(size).length) pageState.sizes[page.id] = size;
    else delete pageState.sizes[page.id];
    applySizes(page);
    savePagePrefs();
  };
}

function blockEl(block) { return pageEls.body.querySelector(`[data-block="${CSS.escape(block.id)}"]`); }

function renderOutputs(page) {
  for (const b of page.blocks) if (b.kind === 'output') { const el = blockEl(b); if (el) el.innerHTML = outputHtml(page); }
}

// Fetch list rows / diff patches. A block that reads {{selected.*}} waits for
// a pick — and, when the selection list is being fetched in the same batch,
// for its answer. An answer for an older selection or segment is dropped.
function loadBlocks(page, blocks) {
  const list = selectionList(page);
  const waiting = list && blocks.includes(list) ? blocks.filter(b => b !== list && usesSelection(b)) : [];
  for (const b of blocks) {
    if (b.kind === 'output' || b.kind === 'form' || waiting.includes(b)) continue;
    pageState.stale.delete(blockKey(page, b));
    loadBlock(page, b, b === list ? waiting : []);
  }
}

// The query a block is fetched with, or null while it waits for a pick.
function blockQuery(page, block) {
  const q = new URLSearchParams();
  if (usesSelection(block)) {
    const sel = selectedRow(page);
    if (!sel) return null;
    for (const [k, v] of Object.entries(sel)) q.set(`selected.${k}`, typeof v === 'string' ? v : JSON.stringify(v));
  }
  if (block.kind === 'diff' && block.segments.length) q.set('seg', segOf(page, block));
  return q.toString();
}

async function loadBlock(page, block, after = []) {
  const key = blockKey(page, block);
  const query = blockQuery(page, block);
  if (query === null) { pageState.data[key] = { result: null, query: null }; renderBlockData(page, block); return; }
  const entry = pageState.data[key] = { ...pageState.data[key], loading: true, query };
  renderBlockData(page, block);
  let result;
  try {
    result = await (await api(`/api/pages/${encodeURIComponent(page.id)}/blocks/${encodeURIComponent(block.id)}?${query}`)).json();
  } catch (e) {
    result = { ok: false, error: String(e) };
  }
  if (pageState.data[key] !== entry) return; // a newer fetch took over
  pageState.data[key] = { result, query };
  renderBlockData(page, block);
  if (block.id !== page.selection) return;
  renderPageBar(page); // buttons that need a pick
  // What follows the pick: blocks waiting on this answer, and any whose row vanished or changed.
  loadBlocks(page, page.blocks.filter(b => b.id !== block.id && usesSelection(b)
    && (after.includes(b) || blockQuery(page, b) !== pageState.data[blockKey(page, b)]?.query)));
}

function renderBlockData(page, block) {
  if (currentPage() !== page) return;
  if (block.kind === 'list') renderListRows(page, block);
  else if (block.kind === 'diff') renderDiffView(page, block);
  else if (block.kind === 'html') renderHtmlData(page, block);
}

// A block's status line when it has nothing (yet) to show.
function blockNote(page, block, entry) {
  if (entry?.loading && !entry.result) return '<div class="ext-empty">loading…</div>';
  const r = entry?.result;
  if (r === null || r?.needs === 'selected') {
    const list = selectionList(page);
    return `<div class="ext-empty">select a row${list ? ` in ${escapeHtml(list.title)}` : ''}</div>`;
  }
  if (r && !r.ok) return `<div class="ext-empty fail-mark">${escapeHtml(r.error || 'failed')}</div>`;
  return '';
}

// list: a table of the JSON rows its command prints.
function initList(page, block, el) {
  const key = blockKey(page, block);
  el.innerHTML = `<div class="blk-head"><span class="name">${escapeHtml(block.title)}</span>`
    + `<span class="cmd" title="${escapeHtml(block.command)}">${escapeHtml(block.command)}</span>`
    + `<span class="meta count" data-count></span>`
    + `<input class="blk-search" type="text" placeholder="filter…" autocomplete="off" spellcheck="false" /></div>`
    + '<div class="blk-scroll" data-rows></div>';
  const search = el.querySelector('.blk-search');
  search.value = pageState.search[key] || '';
  search.addEventListener('input', () => { pageState.search[key] = search.value; renderListRows(page, block); });
}

function listColumns(block, rows) {
  if (block.columns.length) return block.columns;
  return Object.keys(rows[0] || {}).map(k => ({ key: k, format: 'text' }));
}

function cellText(v) {
  if (v === null || v === undefined) return '';
  return typeof v === 'string' ? v : typeof v === 'number' || typeof v === 'boolean' ? String(v) : JSON.stringify(v);
}

// A chip's color comes from common state words; anything else stays neutral.
const CHIP_KINDS = [
  ['on', /^(on|yes|true|ok|enabled|active|local)$/i],
  ['off', /^(off|no|false|none|disabled|same|unchanged|remote)$/i],
  ['warn', /^(changed|modified|diff|dirty|pending|outdated|behind|warn(ing)?)$/i],
  ['bad', /^(error|failed|fail|invalid|missing|broken)$/i],
];

function cellHtml(v, format) {
  if (format === 'chip') {
    const s = typeof v === 'boolean' ? (v ? 'on' : 'off') : cellText(v);
    const kind = CHIP_KINDS.find(([, re]) => re.test(s))?.[0] || 'plain';
    return s ? `<span class="chip ${kind}">${escapeHtml(s)}</span>` : '';
  }
  if (format === 'count') {
    const n = Number(v) || 0;
    return `<span class="${n ? 'count-hot' : 'muted'}">${n}</span>`;
  }
  return escapeHtml(cellText(v));
}

function renderListRows(page, block) {
  const el = blockEl(block);
  if (!el || currentPage() !== page) return;
  const key = blockKey(page, block);
  const entry = pageState.data[key];
  const host = el.querySelector('[data-rows]');
  const rows = entry?.result?.ok ? entry.result.rows : null;
  el.classList.toggle('loading', !!entry?.loading);
  if (!rows) { host.innerHTML = blockNote(page, block, entry); el.querySelector('[data-count]').textContent = ''; return; }
  const cols = listColumns(block, rows);
  const filter = (pageState.search[key] || '').toLowerCase();
  const shown = filter ? rows.filter(r => cols.some(c => cellText(r[c.key]).toLowerCase().includes(filter))) : rows;
  const selectable = block.id === page.selection;
  const picked = selectable ? pageState.selected[page.id] : undefined;
  el.querySelector('[data-count]').textContent = filter ? `${shown.length} / ${rows.length}` : `${rows.length}`;
  const actions = block.rowActions;
  host.innerHTML = rows.length
    ? `<table class="lst"><thead><tr>${cols.map(c => `<th>${escapeHtml(c.key)}</th>`).join('')}${actions.length ? '<th></th>' : ''}</tr></thead><tbody>`
      + shown.map((r) => {
        const rk = rowKeyOf(block, r);
        return `<tr data-row="${escapeHtml(rk ?? '')}"${selectable ? ' class="pick' + (rk === picked ? ' sel' : '') + '"' : ''}>`
          + cols.map(c => `<td>${cellHtml(r[c.key], c.format)}</td>`).join('')
          + (actions.length ? `<td class="row-actions">${actions.map(a => {
            const busy = pageState.running.has(`${page.id}.${block.id}.${a.id}`);
            return `<button class="${a.confirm ? 'warnish' : ''}${busy ? ' busy' : ''}" data-action="${escapeHtml(a.id)}" title="${escapeHtml(a.command)}">${escapeHtml(a.label)}${busy ? ' …' : ''}</button>`;
          }).join('')}</td>` : '')
          + '</tr>';
      }).join('') + '</tbody></table>'
      + (entry.result.truncated ? `<div class="ext-empty">first ${rows.length} of ${entry.result.truncated} rows</div>` : '')
    : '<div class="ext-empty">no rows</div>';
  const byKey = new Map(shown.map(r => [rowKeyOf(block, r) ?? '', r]));
  host.querySelectorAll('tr[data-row]').forEach(tr => {
    const row = byKey.get(tr.dataset.row);
    if (selectable) tr.onclick = () => select(page, block, row);
    tr.querySelectorAll('[data-action]').forEach(btn => {
      btn.onclick = (e) => {
        e.stopPropagation(); // a row button runs on its row; it doesn't change the pick
        const a = actions.find(x => x.id === btn.dataset.action);
        runItem(page, a, `${page.id}.${block.id}.${a.id}`,
          `/api/pages/${encodeURIComponent(page.id)}/rows/${encodeURIComponent(block.id)}/${encodeURIComponent(a.id)}`,
          runValues(page, row));
      };
    });
  });
}

// diff: the unified diff its command prints, drawn like the Changes tab.
function segOf(page, block) {
  const s = pageState.seg[blockKey(page, block)];
  return block.segments.includes(s) ? s : block.segments[0];
}

function initDiff(page, block, el) {
  el.innerHTML = `<div class="blk-head"><span class="name" data-title>${escapeHtml(block.title)}</span>`
    + `<span class="plus" data-plus></span><span class="minus" data-minus></span>`
    + `<span class="cmd" data-cmd title="${escapeHtml(block.command)}"></span>`
    + (block.segments.length ? `<span class="meta muted">vs</span><span class="seg" data-seg></span>` : '')
    + '</div><section class="diff-view" data-diff></section>';
  renderSegments(page, block, el);
}

function renderSegments(page, block, el) {
  const host = el.querySelector('[data-seg]');
  if (!host) return;
  const cur = segOf(page, block);
  host.innerHTML = block.segments.map(s => `<button class="${s === cur ? 'on' : ''}" data-s="${escapeHtml(s)}">${escapeHtml(s)}</button>`).join('');
  host.querySelectorAll('button').forEach(b => {
    b.onclick = () => {
      pageState.seg[blockKey(page, block)] = b.dataset.s;
      savePagePrefs();
      renderSegments(page, block, el);
      loadBlock(page, block);
    };
  });
}

function renderDiffView(page, block) {
  const el = blockEl(block);
  if (!el || currentPage() !== page) return;
  const entry = pageState.data[blockKey(page, block)];
  const r = entry?.result;
  el.classList.toggle('loading', !!entry?.loading);
  const sel = usesSelection(block) ? selectedRow(page) : null;
  const list = selectionList(page);
  el.querySelector('[data-title]').textContent = sel && list ? `${block.title} · ${rowKeyOf(list, sel)}` : block.title;
  el.querySelector('[data-cmd]').textContent = r?.command || '';
  const view = el.querySelector('[data-diff]');
  if (!r?.ok) {
    el.querySelector('[data-plus]').textContent = el.querySelector('[data-minus]').textContent = '';
    view.innerHTML = blockNote(page, block, entry);
    return;
  }
  const files = splitPatch(r.patch || '');
  const added = files.reduce((n, f) => n + f.added, 0), deleted = files.reduce((n, f) => n + f.deleted, 0);
  el.querySelector('[data-plus]').textContent = files.length ? `+${added}` : '';
  el.querySelector('[data-minus]').textContent = files.length ? `−${deleted}` : '';
  const top = view.scrollTop;
  view.innerHTML = files.length
    ? files.map(f => (f.path ? `<div class="dfile-head"><span class="path">${escapeHtml(f.path)}</span>`
        + `<span class="plus">+${f.added}</span><span class="minus">−${f.deleted}</span></div>` : '') + renderPatch(f.patch)).join('')
    : '<div class="diff-note">no differences</div>';
  view.scrollTop = top; // a refresh of the same diff keeps the reader's place
}

// A multi-file unified diff → one entry per file (path from its +++/--- line).
function splitPatch(patch) {
  const files = [];
  let cur = null;
  const start = (path) => { cur = { path, lines: [], added: 0, deleted: 0 }; files.push(cur); };
  const lines = patch.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('diff --git ')) { start(''); continue; }
    if (line.startsWith('--- ') && lines[i + 1]?.startsWith('+++ ')) {
      if (!cur || cur.lines.some(l => l.startsWith('@@'))) start('');
      const strip = (p) => p.replace(/^[ab]\//, '').replace(/\t.*$/, '');
      const to = lines[i + 1].slice(4), from = line.slice(4);
      cur.path = strip(to === '/dev/null' ? from : to);
      i++;
      continue;
    }
    if (!cur) { if (!line.startsWith('@@')) continue; start(''); }
    cur.lines.push(line);
    if (line.startsWith('+')) cur.added++;
    else if (line.startsWith('-')) cur.deleted++;
  }
  return files.filter(f => f.lines.some(l => l.startsWith('@@'))).map(f => ({ ...f, patch: f.lines.join('\n') }));
}

// html: a project file in a sandboxed frame. It runs in an opaque origin
// (no allow-same-origin) under a CSP with no network, gets its data by
// postMessage ({type: 'emu:data', …}) and may ask for its declared toolbar
// actions ({type: 'emu:action', id}) — which run like a button press,
// confirmation included. The file arrives through the API and goes in as
// srcdoc, so the session token never appears in a frame's URL.
const FRAME_CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
  + "img-src data: blob:; font-src data:; form-action 'none'";

function initHtml(page, block, el) {
  el.innerHTML = `<div class="blk-head"><span class="name">${escapeHtml(block.title)}</span>`
    + `<span class="cmd" data-cmd></span><span class="meta muted" title="sandboxed: no network, no access to the dashboard">${escapeHtml(block.src)}</span></div>`
    + `<div class="ext-empty" data-note hidden></div>`
    + `<iframe class="ext-frame" sandbox="allow-scripts" referrerpolicy="no-referrer" title="${escapeHtml(block.title)}"></iframe>`;
  el.querySelector('iframe').addEventListener('load', () => postFrameData(page, block));
  loadFrame(page, block);
}

function withFrameCsp(html) {
  const meta = `<meta http-equiv="Content-Security-Policy" content="${FRAME_CSP}">`;
  const doctype = html.match(/^\s*<!doctype[^>]*>/i); // keep it first, or the frame drops to quirks mode
  return doctype ? doctype[0] + meta + html.slice(doctype[0].length) : meta + html;
}

async function loadFrame(page, block) {
  const el = blockEl(block);
  if (!el) return;
  let r;
  try {
    r = await (await api(`/api/pages/${encodeURIComponent(page.id)}/frames/${encodeURIComponent(block.id)}`)).json();
  } catch (e) {
    r = { ok: false, error: String(e) };
  }
  if (blockEl(block) !== el) return; // the page was re-rendered meanwhile
  const note = el.querySelector('[data-note]');
  note.hidden = r.ok;
  if (!r.ok) { note.textContent = r.error || 'failed'; return; }
  el.querySelector('iframe').srcdoc = withFrameCsp(r.html);
}

function renderHtmlData(page, block) {
  const el = blockEl(block);
  if (!el || currentPage() !== page) return;
  const entry = pageState.data[blockKey(page, block)];
  el.classList.toggle('loading', !!entry?.loading);
  el.querySelector('[data-cmd]').textContent = entry?.result?.command || '';
  if (!entry?.loading) postFrameData(page, block);
}

function postFrameData(page, block) {
  const frame = blockEl(block)?.querySelector('iframe');
  const r = pageState.data[blockKey(page, block)]?.result;
  // The frame's origin is opaque, so '*' is the only target that reaches it.
  frame?.contentWindow?.postMessage({
    type: 'emu:data',
    ok: r ? !!r.ok : null,
    data: r?.data ?? null,
    text: r?.text ?? null,
    error: r && !r.ok ? r.error : null,
    needs: r === null ? 'selected' : r?.needs ?? null,
    selected: selectedRow(page),
  }, '*');
}

window.addEventListener('message', (e) => {
  const page = currentPage();
  if (!page) return;
  const block = page.blocks.find(b => b.kind === 'html' && blockEl(b)?.querySelector('iframe')?.contentWindow === e.source);
  const msg = e.data;
  if (!block || !msg || typeof msg !== 'object') return;
  if (msg.type === 'emu:ready') postFrameData(page, block);
  else if (msg.type === 'emu:action') {
    const item = page.toolbar.find(i => i.kind === 'action' && i.id === msg.id);
    if (!item || !block.actions.includes(item.id)) { toast(`${block.title}: action "${msg.id}" is not allowed`); return; }
    runItem(page, item, itemKey(page, item),
      `/api/pages/${encodeURIComponent(page.id)}/run/${encodeURIComponent(item.id)}`, runValues(page));
  }
});

// form: fields and the buttons that use them. What's typed fills
// {{input.<field>}} server-side and is kept per browser.
function formValues(page, block) {
  const saved = pageState.input[blockKey(page, block)] || {};
  return Object.fromEntries(block.fields.map(f => [f.name, saved[f.name] ?? f.default ?? '']));
}

function initForm(page, block, el) {
  const key = blockKey(page, block);
  const values = formValues(page, block);
  const fieldId = (f) => `f-${page.id}-${block.id}-${f.name}`;
  el.innerHTML = `<div class="blk-head"><span class="name">${escapeHtml(block.title)}</span></div>`
    + '<div class="form-grid">'
    + block.fields.map(f => `<label for="${escapeHtml(fieldId(f))}">${escapeHtml(f.label)}</label>`
      + `<input class="field" id="${escapeHtml(fieldId(f))}" data-field="${escapeHtml(f.name)}" type="text"`
      + ` placeholder="${escapeHtml(f.placeholder || '')}" value="${escapeHtml(values[f.name])}" autocomplete="off" spellcheck="false" />`).join('')
    + '<div class="form-actions"></div></div>';
  el.querySelectorAll('[data-field]').forEach(input => {
    input.addEventListener('input', () => {
      pageState.input[key] = { ...formValues(page, block), [input.dataset.field]: input.value };
      savePagePrefs();
    });
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') el.querySelector('[data-action]')?.click(); });
  });
  renderFormButtons(page, block);
}

function renderFormButtons(page, block) {
  const host = blockEl(block)?.querySelector('.form-actions');
  if (!host) return;
  host.innerHTML = block.actions.map(a => {
    const busy = pageState.running.has(`${page.id}.${block.id}.${a.id}`);
    return `<button class="${a.confirm ? 'warnish' : ''}${busy ? ' busy' : ''}" data-action="${escapeHtml(a.id)}"`
      + ` title="${escapeHtml(a.command)}">${escapeHtml(a.label)}${busy ? ' …' : ''}</button>`;
  }).join('');
  host.querySelectorAll('[data-action]').forEach(btn => {
    btn.onclick = () => {
      const a = block.actions.find(x => x.id === btn.dataset.action);
      runItem(page, a, `${page.id}.${block.id}.${a.id}`,
        `/api/pages/${encodeURIComponent(page.id)}/forms/${encodeURIComponent(block.id)}/${encodeURIComponent(a.id)}`,
        { ...runValues(page), input: formValues(page, block) });
    };
  });
}

// output: the page's last run — what ran, how it ended, what it printed.
function outputHtml(page) {
  const busy = [...pageState.running].filter(k => k.startsWith(`${page.id}.`));
  const run = pageState.last[page.id];
  if (busy.length) {
    return `<div class="blk-head"><span class="name">output</span><span class="cmd">running ${busy.map(k => escapeHtml(k.slice(page.id.length + 1))).join(', ')}…</span></div>`
      + `<pre class="ext-out muted">${run ? escapeHtml(stripAnsi(run.output)) : ''}</pre>`;
  }
  if (!run) return '<div class="blk-head"><span class="name">output</span></div><div class="ext-empty">no run yet — press a toolbar button</div>';
  const mark = run.ok ? '<span class="ok-mark">✓</span>' : '<span class="fail-mark">✗</span>';
  const then = run.then ? ` · ${escapeHtml(run.then.action)}: ${escapeHtml(run.then.message || (run.then.ok ? 'ok' : 'failed'))}` : '';
  const when = new Date(run.at).toLocaleTimeString();
  return `<div class="blk-head"><span class="name">output</span><span class="cmd" title="${escapeHtml(run.command)}">$ ${escapeHtml(run.command)}</span>`
    + `<span class="meta">${mark} ${escapeHtml(run.error || 'exit 0')} · ${(run.ms / 1000).toFixed(1)}s · ${when}${then}</span></div>`
    + `<pre class="ext-out">${escapeHtml(stripAnsi(run.output)) || '<span class="muted">(no output)</span>'}</pre>`;
}

let confirmResolve = null;
function confirmRun(item, command) {
  document.getElementById('confirm-title').textContent = `Run “${item.label}”?`;
  document.getElementById('confirm-cmd').textContent = `$ ${command}`;
  document.getElementById('confirm-then').textContent =
    item.then !== 'none' ? `then: hot ${item.then} when it succeeds` : '';
  pageEls.confirm.hidden = pageEls.confirmDim.hidden = false;
  document.getElementById('confirm-run').focus();
  return new Promise((resolve) => { confirmResolve = resolve; });
}
function closeConfirm(ok) {
  pageEls.confirm.hidden = pageEls.confirmDim.hidden = true;
  confirmResolve?.(ok);
  confirmResolve = null;
}
document.getElementById('confirm-run').onclick = () => closeConfirm(true);
document.getElementById('confirm-cancel').onclick = () => closeConfirm(false);
pageEls.confirmDim.onclick = () => closeConfirm(false);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && confirmResolve) closeConfirm(false); });

function stripAnsi(s) { return (s || '').replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, ''); }

loadPages();
