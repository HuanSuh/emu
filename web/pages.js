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
// A list with `check:` also has checked rows — many at once — sent with every
// run for `{{checked.<col>...}}`.

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
  history: {},           // page id → its recent finished runs, newest first (this tab only)
  viewing: {},           // page id → the history entry the output shows; null: the newest, or the run in flight
  live: {},              // 'page.item' → the output of a run in flight, as it comes (its last LIVE_LIMIT characters)
  liveTotal: {},         // 'page.item' → how many characters of it came in all
  liveSince: {},         // 'page.item' → when this tab saw it start
  running: new Set(),    // 'page.item' in flight, from any client
  toggles: {},           // 'page.item' → {ok, on, detail, error}
  auto: {},              // 'page.item' → whether an `auto:` action runs on file changes (the server keeps it)
  selected: {},          // page id → key value of the picked row
  checked: {},           // 'page.block' → key values of the checked rows (check: true)
  bulk: {},              // 'page.block.action' → progress of a bulk run, "2/5"
  seg: {},               // 'page.block' → chosen segment
  sort: {},              // 'page.block' → {key, dir} from a column head click; null: the command's order
  tree: {},              // 'page.block' → {folder key: open} where a click changed it
  data: {},              // 'page.block' → {loading, result, query}
  search: {},            // 'page.block' → filter text
  input: {},             // 'page.form' → {field: value}
  stale: new Set(),      // 'page.block' to fetch when it shows: changed (watch) while hidden or folded
  sizes: {},             // page id → {left, bottom}: dragged panel sizes, as % of the page body
  folded: {},            // page id → the areas folded to a strip
  foldedBlocks: {},      // page id → the blocks folded to their head
};
const PAGE_KEY = 'emu.page';
const PAGE_PREFS_KEY = 'emu.pagePrefs';
try {
  pageState.current = localStorage.getItem(PAGE_KEY) || 'debug';
  const prefs = JSON.parse(localStorage.getItem(PAGE_PREFS_KEY)) || {};
  if (prefs.selected && typeof prefs.selected === 'object') pageState.selected = prefs.selected;
  if (prefs.checked && typeof prefs.checked === 'object') pageState.checked = prefs.checked;
  if (prefs.seg && typeof prefs.seg === 'object') pageState.seg = prefs.seg;
  if (prefs.sort && typeof prefs.sort === 'object') pageState.sort = prefs.sort;
  if (prefs.tree && typeof prefs.tree === 'object') pageState.tree = prefs.tree;
  if (prefs.input && typeof prefs.input === 'object') pageState.input = prefs.input;
  if (prefs.sizes && typeof prefs.sizes === 'object') pageState.sizes = prefs.sizes;
  if (prefs.folded && typeof prefs.folded === 'object') pageState.folded = prefs.folded;
  if (prefs.foldedBlocks && typeof prefs.foldedBlocks === 'object') pageState.foldedBlocks = prefs.foldedBlocks;
} catch (_) {}
function savePagePrefs() {
  try {
    localStorage.setItem(PAGE_PREFS_KEY, JSON.stringify({
      selected: pageState.selected, checked: pageState.checked, seg: pageState.seg, sort: pageState.sort, tree: pageState.tree,
      input: pageState.input, sizes: pageState.sizes, folded: pageState.folded, foldedBlocks: pageState.foldedBlocks,
    }));
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
    for (const [id, run] of Object.entries(j.last || {})) remember(id, run);
    pageState.auto = j.auto || {};
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
  if (debug) { pruneFrameRefreshed(null); showTab(debugTab); return; }
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

const followTimers = {}; // page id → the pending fetch after a pick made with the arrow keys

// [soon]: the pick came from an arrow key — what follows it is fetched once
// the keys rest, so stepping through rows fetches only the row stopped at.
function select(page, list, row, { soon = false } = {}) {
  const key = rowKeyOf(list, row);
  const before = pageState.selected[page.id];
  if (before === key) return;
  pageState.selected[page.id] = key;
  savePagePrefs();
  if (!movePick(list, before, key)) renderListRows(page, list);
  renderPageBar(page);
  // Everything that reads {{selected.*}} follows the pick.
  // A frame that isn't fetched again still hears of the pick (onData's
  // selected) — at the same moment the fetched ones do.
  const follow = () => {
    loadBlocks(page, page.blocks.filter(b => b.id !== list.id && usesSelection(b)));
    for (const b of page.blocks) if (b.kind === 'html' && !usesSelection(b)) postFrameData(page, b);
  };
  clearTimeout(followTimers[page.id]);
  if (soon) followTimers[page.id] = setTimeout(follow, 200);
  else follow();
}

// The highlight moves to the picked row as drawn, so an arrow key doesn't
// redraw a big list. False when that's not enough: the row isn't drawn, or in
// a tree the old pick isn't either (a closed folder marks it).
function movePick(list, from, to) {
  const host = blockEl(list)?.querySelector('[data-rows]');
  const drawn = (k) => host?.querySelector(`tr[data-row="${CSS.escape(k)}"]`);
  const next = to === undefined ? null : drawn(to);
  if (!next || (list.tree && from !== undefined && !drawn(from))) return false;
  host.querySelectorAll('tr.sel').forEach(tr => tr.classList.remove('sel'));
  next.classList.add('sel');
  return true;
}

// The keys in the selection list: ↑/↓ the row above or below, PageUp/PageDown
// ten rows, Home/End the first and last — as shown (filter and order applied).
const STEP_KEYS = { ArrowDown: 1, ArrowUp: -1, PageDown: 10, PageUp: -10, End: Infinity, Home: -Infinity };

function stepSelection(page, list, step) {
  const rows = listShown[blockKey(page, list)] || [];
  if (!rows.length) return;
  const i = rows.findIndex(r => rowKeyOf(list, r) === pageState.selected[page.id]);
  const from = i < 0 ? (step > 0 ? -1 : rows.length) : i;
  select(page, list, rows[Math.min(Math.max(from + step, 0), rows.length - 1)], { soon: true });
  blockEl(list)?.querySelector('tr.sel')?.scrollIntoView({ block: 'nearest' });
}

// Placeholder values sent with a run: the picked row, the checked rows and,
// for a row button, its row. A list whose tool keeps the checks (check.column)
// isn't sent: the server reads them from the list itself.
function runValues(page, row) {
  const v = {};
  const sel = selectedRow(page);
  if (sel) v.selected = sel;
  const own = checkLists(page).filter(b => !b.check.column);
  if (own.length) v.checked = Object.fromEntries(own.map(b => [b.id, checkedRows(page, b)]));
  if (row) v.row = row;
  return v;
}

// ---- checked rows ------------------------------------------------------------
// check: true — the dashboard keeps the checked keys per browser, and drops
// those a fresh fetch no longer lists. check: {column, toggle} — the tool
// keeps them: the column says, and a click runs toggle on that row.

function checkLists(page) { return page.blocks.filter(b => b.kind === 'list' && b.check); }

// Mirrors isCheckedValue in pages.dart.
function isCheckedValue(v) {
  return v === true || (typeof v === 'number' && v !== 0)
    || (typeof v === 'string' && /^(true|yes|y|on|1|checked)$/i.test(v.trim()));
}

function checkedKeys(page, block) {
  if (!block.check.column) return new Set(pageState.checked[blockKey(page, block)] || []);
  const rows = pageState.data[blockKey(page, block)]?.result?.rows || [];
  return new Set(rows.filter(r => isCheckedValue(r[block.check.column])).map(r => rowKeyOf(block, r)));
}

// The checked rows, as last fetched.
function checkedRows(page, block) {
  const rows = pageState.data[blockKey(page, block)]?.result?.rows;
  if (!rows) return [];
  const keys = checkedKeys(page, block);
  return rows.filter(r => keys.has(rowKeyOf(block, r)));
}

// `needs: checked` with nothing checked in that list.
function blockedByChecks(page, item) {
  const list = item.needsChecked && page.blocks.find(b => b.id === item.needsChecked);
  return !!list && !checkedRows(page, list).length;
}

// Check (on) or uncheck these rows. The tool's own state: one toggle run per
// row that differs, in turn — the runs' broadcasts fetch the list again.
async function setChecked(page, block, rows, on) {
  const keys = checkedKeys(page, block);
  const change = rows.filter(r => keys.has(rowKeyOf(block, r)) !== on);
  if (!change.length) return;
  if (!block.check.column) {
    for (const r of change) on ? keys.add(rowKeyOf(block, r)) : keys.delete(rowKeyOf(block, r));
    pageState.checked[blockKey(page, block)] = [...keys];
    savePagePrefs();
    renderRunning(page); // counts, and buttons that need a checked row
    return;
  }
  const toggle = { id: 'check', label: 'check', command: block.check.toggle, then: 'none' };
  for (const r of change) {
    const run = await runItem(page, toggle, `${page.id}.${block.id}.check`,
      `/api/pages/${encodeURIComponent(page.id)}/rows/${encodeURIComponent(block.id)}/check`, runValues(page, r), { quiet: true });
    if (!run?.ok) break;
  }
}

// A `bulk: true` row button from the list's head: once per checked row, in
// turn, stopping at the first failure. A confirm: true button asks once.
async function runBulk(page, block, a) {
  const rows = checkedRows(page, block);
  const key = `${page.id}.${block.id}.${a.id}`;
  if (!rows.length || pageState.bulk[key] || pageState.running.has(key)) return;
  const url = `/api/pages/${encodeURIComponent(page.id)}/rows/${encodeURIComponent(block.id)}/${encodeURIComponent(a.id)}`;
  const post = async (row, confirmed) => {
    const r = await api(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...runValues(page, row), confirmed, asker: ASKER }) });
    return [r, await r.json()];
  };
  const progress = (n) => { pageState.bulk[key] = `${n}/${rows.length}`; renderRunning(page); };
  let confirmed = false;
  progress(0);
  try {
    for (const [i, row] of rows.entries()) {
      let [r, j] = await post(row, confirmed);
      if (r.status === 428 && j.needsConfirm) {
        const more = rows.length - 1;
        const opts = confirmOpts(a, j);
        if (more) opts.command += `\n… and ${more} more, once per checked row`;
        if (!(await confirmRun(opts)).ok) return;
        confirmed = true;
        [r, j] = await post(row, true);
      }
      if (!j.ok) {
        toast(`${a.label}: stopped at ${rowKeyOf(block, row)} (${i + 1}/${rows.length}) — ${j.error || 'failed'}`);
        return;
      }
      progress(i + 1);
    }
    toast(`${a.label}: done on ${rows.length} row${rows.length === 1 ? '' : 's'}`);
  } catch (e) {
    toast(`${a.label} failed: ${e}`);
  } finally {
    delete pageState.bulk[key];
    if (currentPage() === page) renderRunning(page);
  }
}

// ---- toolbar -----------------------------------------------------------------

function renderPageBar(page) {
  const hasSelection = !!selectedRow(page);
  pageEls.bar.innerHTML = `<span class="title">${escapeHtml(page.title)}</span>` + page.toolbar.map(item => {
    const key = itemKey(page, item);
    const busy = pageState.running.has(key);
    const blocked = (usesSelection(item) && !hasSelection) || blockedByChecks(page, item);
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
    const title = blocked ? (usesSelection(item) && !hasSelection ? 'select a row first' : `check a row in ${item.needsChecked} first`) : item.command;
    return `<button class="ext-action${item.confirm ? ' warnish' : ''}${busy ? ' busy' : ''}" data-item="${escapeHtml(item.id)}"`
      + ` title="${escapeHtml(title)}"${blocked ? ' disabled' : ''}>${escapeHtml(item.label)}${busy ? ' …' : ''}</button>`
      + (item.auto ? autoSwitchHtml(page, item) : '');
  }).join('') + '<span class="grow"></span>'
    + '<button id="pages-unfold" title="Unfold every folded area and block of this page" hidden>unfold all</button>'
    + '<button id="pages-refresh" title="Re-read emu.yaml">↻</button>';
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
  document.getElementById('pages-unfold').onclick = () => unfoldAll(page);
  renderUnfoldAll(page);
  pageEls.bar.querySelectorAll('[data-auto]').forEach(b => { b.onclick = () => switchAuto(page, b.dataset.auto); });
}

// ---- auto: -------------------------------------------------------------------
// ⚡ beside an `auto:` action: whether the server runs it when the files it
// watches change. The server keeps the switch (per project) and runs it with
// no dashboard open; a failed run says so here.

function autoSwitchHtml(page, item) {
  const on = !!pageState.auto[itemKey(page, item)];
  const title = `${on ? 'Runs' : 'Off — click to run'} on its own when these change: ${item.auto.watch.join(', ')}`;
  return `<button class="ext-auto${on ? ' on' : ''}" data-auto="${escapeHtml(item.id)}" aria-pressed="${on}"`
    + ` title="${escapeHtml(title)}">⚡</button>`;
}

async function switchAuto(page, id) {
  const key = `${page.id}.${id}`;
  try {
    const r = await api(`/api/pages/${encodeURIComponent(page.id)}/auto/${encodeURIComponent(id)}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ on: !pageState.auto[key] }),
    });
    const j = await r.json();
    if (!j.ok) { toast(`auto ${id}: ${j.error || 'failed'}`); return; }
    pageState.auto[key] = j.on;
  } catch (e) {
    toast(`auto ${id} failed: ${e}`);
    return;
  }
  if (currentPage() === page) renderPageBar(page);
}

// Switched here, in another tab or by the CLI.
function onPageAuto(msg) {
  pageState.auto[`${msg.page}.${msg.item}`] = !!msg.on;
  const page = currentPage();
  if (page?.id === msg.page) renderPageBar(page);
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

// Run a toolbar item or row button. An item marked confirm: answers 428 with
// the exact command (values filled in), the dialog's words and the preview
// output; that is what the dialog shows. [frame] is the html block that asked
// for the run, if one did: its dialog says so, and falls under that frame's
// limits (frameDialog); [ask]: its words for this run (withAsk). [quiet]: no
// toast when it succeeds. Resolves to the run's answer, or {ok: false, error,
// busy | cancelled} when it didn't run.
async function runItem(page, item, key, url, body, { frame = null, ask = null, quiet = false } = {}) {
  if (pageState.running.has(key)) return { ok: false, busy: true, error: `${item.label} is already running` };
  pageState.running.add(key);
  renderRunning(page);
  try {
    const post = (b) => api(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...b, asker: ASKER }) });
    let r = await post(body);
    let j = await r.json();
    if (r.status === 428 && j.needsConfirm) {
      pageState.running.delete(key);
      renderRunning(page);
      const opts = confirmOpts(item, j);
      const answer = !frame ? await confirmRun(opts)
        : ask ? await frameDialog(page, frame, { ...withAsk(opts, ask), verb: 'asks' })
          : await frameDialog(page, frame, { ...opts, verb: 'wants to run this' });
      if (!answer.ok) return { ok: false, cancelled: true, busy: !!answer.busy, error: refusalText(answer) };
      pageState.running.add(key);
      renderRunning(page);
      r = await post({ ...body, confirmed: true });
      j = await r.json();
    }
    if (j.exitCode === undefined) toast(`${item.label}: ${j.error || 'failed'}`); // busy, no selection, unknown
    else finishRun(page, item, key, j, quiet);
    return j;
  } catch (e) {
    toast(`${item.label} failed: ${e}`);
    return { ok: false, error: String(e) };
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

const HISTORY_MAX = 10;
const LIVE_LIMIT = 256 * 1024; // as much of a run's output as the server keeps

// A finished run, once — the POST answer and the broadcast both bring it.
function remember(pageId, run) {
  if (!run?.at) return;
  const hist = pageState.history[pageId] || [];
  if (hist.some(r => r.item === run.item && r.at === run.at)) return;
  pageState.history[pageId] = [run, ...hist].sort((a, b) => (a.at < b.at ? 1 : -1)).slice(0, HISTORY_MAX);
  pageState.viewing[pageId] = null; // show what just finished
}

function finishRun(page, item, key, run, quiet) {
  remember(page.id, run);
  if (run.state) pageState.toggles[key] = run.state;
  if (!(quiet && run.ok)) toast(`${item.label}: ${run.ok ? 'done' : run.error || 'failed'}${run.then ? ` · ${run.then.action}` : ''}`);
  if (item.openUrl && run.ok) refreshShot(); // the server already waited for the app to settle
  else if (run.then?.ok) scheduleRefresh(); // reloaded: show the new screen
}

// Runs started anywhere (this tab, another tab, `emu run`) show up here too.
function onPageRun(msg) {
  if (msg.event === 'ask' || msg.event === 'ask-done') { onRunAsk(msg); return; } // a run started here asks
  const page = pageState.pages.find(p => p.id === msg.page);
  if (!page) return;
  const key = `${msg.page}.${msg.item}`;
  if (msg.event === 'output') {
    const chunk = msg.chunk || '';
    pageState.live[key] = ((pageState.live[key] || '') + chunk).slice(-LIVE_LIMIT);
    pageState.liveTotal[key] = (pageState.liveTotal[key] || 0) + chunk.length;
    if (currentPage() === page) renderOutputs(page);
    return;
  }
  if (msg.event === 'started') {
    pageState.running.add(key);
    pageState.live[key] = '';
    pageState.liveTotal[key] = 0;
    pageState.liveSince[key] = Date.now();
    pageState.viewing[page.id] = null; // follow it
  } else if (msg.event === 'finished') {
    pageState.running.delete(key);
    delete pageState.live[key];
    delete pageState.liveTotal[key];
    delete pageState.liveSince[key];
    remember(page.id, msg.run);
    if (msg.run?.state) pageState.toggles[key] = msg.run.state;
    if (msg.auto && !msg.run?.ok) toast(`⚡ ${msg.item} (on change): ${msg.run?.error || 'failed'}`);
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
  pruneFrameRefreshed(page);
  const areas = { left: [], main: [], bottom: [] };
  for (const b of page.blocks) areas[b.area]?.push(b);
  const body = pageEls.body;
  body.innerHTML = page.blocks.length
    ? ['left', 'main', 'bottom'].map(a => `<div class="ext-area ${a}" data-area="${a}">`
      + (areas[a].length ? areaFoldHtml(a, areas[a]) : '') + '</div>').join('')
    : '<div class="ext-empty">This page has no blocks — results show up in the Logs tab.</div>';
  body.querySelectorAll('[data-fold-area]').forEach(b => { b.onclick = () => foldArea(page, b.dataset.foldArea); });
  body.querySelectorAll('[data-unfold-area]').forEach(b => { b.onclick = () => unfoldArea(page, b.dataset.unfoldArea); });
  for (const [area, blocks] of Object.entries(areas)) {
    const host = body.querySelector(`[data-area="${area}"]`);
    for (const b of blocks) {
      host?.insertAdjacentHTML('beforeend', `<section class="ext-block ${b.kind}" data-block="${escapeHtml(b.id)}"></section>`);
      const el = blockEl(b);
      if (b.kind === 'list') initList(page, b, el);
      else if (b.kind === 'diff') initDiff(page, b, el);
      else if (b.kind === 'html') initHtml(page, b, el);
      else if (b.kind === 'form') initForm(page, b, el);
      else if (b.kind === 'output') initOutput(page, b, el);
      addBlockFold(page, b, el);
    }
  }
  applyFolds(page);
  addResizers(page, areas);
  renderOutputs(page);
}

// ---- folding -------------------------------------------------------------------
// Each area with blocks folds (the chevron in its first block's head) to a
// strip of its blocks' titles, and the others take its room; a click on the
// strip unfolds it in place. The last unfolded area doesn't fold. A block
// folds to its head (the caret before its name) and the others in its area
// take its room. The page bar's "unfold all" unfolds every area and block of
// the page. Kept per page. What's folded isn't fetched until it unfolds —
// except the lists that hold the pick and the checks — and an output folded
// to its head keeps only the head up to date.

// [fold, unfold] chevrons: toward where the area goes, and back.
const FOLD_ICONS = { left: ['‹', '›'], main: ['⌃', '⌄'], bottom: ['⌄', '⌃'] };

function areaFolded(page, area) { return (pageState.folded[page.id] || []).includes(area); }

function blockFolded(page, block) { return (pageState.foldedBlocks[page.id] || []).includes(block.id); }

// In a folded area, or folded to its head.
function outOfSight(page, block) { return areaFolded(page, block.area) || blockFolded(page, block); }

function areasWithBlocks(page) { return ['left', 'main', 'bottom'].filter(a => page.blocks.some(b => b.area === a)); }

function areaFoldHtml(area, blocks) {
  const titles = blocks.map(b => b.title || b.kind).join(' · ');
  return `<button class="area-fold" data-fold-area="${area}" title="Fold this area">${FOLD_ICONS[area][0]}</button>`
    + `<button class="fold-bar area-fold-bar" data-unfold-area="${area}" title="Unfold">`
    + `<span class="fold-icon">${FOLD_ICONS[area][1]}</span><span class="fold-titles">${escapeHtml(titles)}</span></button>`;
}

// The caret before a block's name: folds it to its head, and back.
function addBlockFold(page, block, el) {
  const head = el.querySelector('.blk-head');
  if (!head) return;
  head.insertAdjacentHTML('afterbegin', '<button class="blk-fold" data-fold-block></button>');
  head.firstElementChild.onclick = () => (blockFolded(page, block) ? unfoldBlock(page, block) : foldBlock(page, block));
}

// The grid follows what's folded: the left area folds to an upright strip,
// main and bottom to a bar — or, both folded, the right column to a strip.
// When main or bottom has only folded blocks, it takes their heads' height
// and the other one the rest.
function applyFolds(page) {
  const body = pageEls.body;
  const used = areasWithBlocks(page);
  const folded = (a) => used.includes(a) && areaFolded(page, a);
  const right = ['main', 'bottom'].filter(a => used.includes(a));
  const rightFolded = right.length > 0 && right.every(folded);
  for (const a of ['left', 'main', 'bottom']) {
    body.classList.toggle(`no-${a}`, !used.includes(a));
    const el = body.querySelector(`[data-area="${a}"]`);
    if (!el) continue;
    el.classList.toggle('folded', folded(a));
    el.classList.toggle('upright', folded(a) && (a === 'left' || rightFolded));
    const icon = el.querySelector('.area-fold-bar .fold-icon');
    if (icon) icon.textContent = a !== 'left' && rightFolded ? '‹' : FOLD_ICONS[a][1];
  }
  body.classList.toggle('fold-left', folded('left'));
  body.classList.toggle('fold-right', rightFolded);
  body.classList.toggle('fold-main', folded('main') && !rightFolded);
  body.classList.toggle('fold-bottom', folded('bottom') && !rightFolded);
  const both = right.length === 2 && !folded('main') && !folded('bottom');
  const heads = (a) => page.blocks.every(b => b.area !== a || blockFolded(page, b));
  body.classList.toggle('heads-bottom', both && heads('bottom'));
  body.classList.toggle('heads-main', both && heads('main') && !heads('bottom'));
  const unfolded = used.filter(a => !folded(a));
  body.querySelectorAll('[data-fold-area]').forEach(b => { b.hidden = unfolded.length < 2; });
  for (const b of page.blocks) {
    const el = blockEl(b);
    const caret = el?.querySelector('[data-fold-block]');
    if (!caret) continue;
    const f = blockFolded(page, b);
    el.classList.toggle('folded', f);
    caret.textContent = f ? '▸' : '▾';
    caret.title = f ? 'Unfold' : 'Fold to its head';
  }
  renderUnfoldAll(page);
}

// The page bar's "unfold all": there while an area or a block of the page is folded.
function renderUnfoldAll(page) {
  const btn = document.getElementById('pages-unfold');
  if (btn) btn.hidden = !areasWithBlocks(page).some(a => areaFolded(page, a)) && !page.blocks.some(b => blockFolded(page, b));
}

function foldArea(page, area) {
  pageState.folded[page.id] = [...new Set([...(pageState.folded[page.id] || []), area])];
  savePagePrefs();
  applyFolds(page);
}

function unfoldArea(page, area) {
  const folded = (pageState.folded[page.id] || []).filter(a => a !== area);
  if (folded.length) pageState.folded[page.id] = folded;
  else delete pageState.folded[page.id];
  savePagePrefs();
  unfolded(page, page.blocks.filter(b => b.area === area));
}

function foldBlock(page, block) {
  pageState.foldedBlocks[page.id] = [...new Set([...(pageState.foldedBlocks[page.id] || []), block.id])];
  savePagePrefs();
  applyFolds(page);
}

function unfoldBlock(page, block) {
  const folded = (pageState.foldedBlocks[page.id] || []).filter(id => id !== block.id);
  if (folded.length) pageState.foldedBlocks[page.id] = folded;
  else delete pageState.foldedBlocks[page.id];
  savePagePrefs();
  unfolded(page, [block]);
}

function unfoldAll(page) {
  delete pageState.folded[page.id];
  delete pageState.foldedBlocks[page.id];
  savePagePrefs();
  unfolded(page, page.blocks);
}

// [blocks] may be in sight again: what they skipped while folded.
function unfolded(page, blocks) {
  applyFolds(page);
  loadBlocks(page, blocks.filter(b => pageState.stale.has(blockKey(page, b))));
  if (blocks.some(b => b.kind === 'output')) renderOutputs(page);
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
  for (const b of page.blocks) {
    const el = b.kind === 'output' && blockEl(b);
    if (el) renderOutput(page, el, { head: outOfSight(page, b) });
  }
}

// Fetch list rows / diff patches. A block that reads {{selected.*}} waits for
// a pick — and, when the selection list is being fetched in the same batch,
// for its answer. An answer for an older selection or segment is dropped.
function loadBlocks(page, blocks) {
  const list = selectionList(page);
  const waiting = list && blocks.includes(list) ? blocks.filter(b => b !== list && usesSelection(b)) : [];
  for (const b of blocks) {
    if (b.kind === 'output' || b.kind === 'form' || waiting.includes(b)) continue;
    // A folded block is fetched when it unfolds — but the lists that hold the pick and the checks always are.
    if (outOfSight(page, b) && b.id !== page.selection && !b.check) { pageState.stale.add(blockKey(page, b)); continue; }
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
  if (block.check && !block.check.column && result.ok && pageState.checked[key]) {
    // A row that's gone is no longer checked.
    const keys = new Set(result.rows.map(r => rowKeyOf(block, r)));
    const kept = pageState.checked[key].filter(k => keys.has(k));
    if (kept.length !== pageState.checked[key].length) { pageState.checked[key] = kept; savePagePrefs(); }
  }
  renderBlockData(page, block);
  if (block.check) renderRunning(page); // buttons that need a checked row
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
    + (block.check ? '<span class="checks" data-checks></span>' : '')
    + `<span class="meta count" data-count></span>`
    + `<input class="blk-search" type="text" placeholder="filter…" autocomplete="off" spellcheck="false" /></div>`
    + '<div class="blk-scroll" data-rows></div>';
  const search = el.querySelector('.blk-search');
  const rowsEl = el.querySelector('[data-rows]');
  search.value = pageState.search[key] || '';
  search.addEventListener('input', () => { pageState.search[key] = search.value; renderListRows(page, block); });
  // A value cut with an ellipsis shows whole on hover.
  rowsEl.addEventListener('mouseover', (e) => {
    const cell = e.target.closest?.('.cell');
    if (cell && !cell.title && cell.scrollWidth > cell.clientWidth) cell.title = cell.textContent;
  });
  if (block.id !== page.selection) return;
  // The selection list takes the keys once clicked: ↑/↓ (PageUp/PageDown,
  // Home/End) pick, / goes to the filter, and ↓ or Enter there comes back.
  rowsEl.tabIndex = 0;
  rowsEl.addEventListener('keydown', (e) => {
    if (e.altKey || e.metaKey || e.ctrlKey) return;
    if (e.key in STEP_KEYS) {
      e.preventDefault();
      stepSelection(page, block, STEP_KEYS[e.key]);
    } else if (e.key === '/') {
      e.preventDefault();
      search.focus();
      search.select();
    }
  });
  search.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' || e.key === 'Enter') { e.preventDefault(); rowsEl.focus(); }
  });
}

// A tree's path columns are drawn as its folders, so they aren't columns by default.
function listColumns(block, rows) {
  if (block.columns.length) return block.columns;
  const path = new Set(block.tree?.columns || []);
  return Object.keys(rows[0] || {}).filter(k => !path.has(k)).map(k => ({ key: k, format: 'text' }));
}

// What a filter looks through: the columns, and a tree row's path.
function rowTexts(block, cols, row) {
  const texts = cols.map(c => cellText(row[c.key]));
  if (block.tree) texts.push(treePath(block, row).join('/'));
  return texts;
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

// A text value longer than its column's width (col.width, else 32em) is cut
// with an ellipsis — at its start for `:start`, so a path keeps its end.
function cellHtml(v, col) {
  if (col.format === 'chip') {
    const s = typeof v === 'boolean' ? (v ? 'on' : 'off') : cellText(v);
    const kind = CHIP_KINDS.find(([, re]) => re.test(s))?.[0] || 'plain';
    return s ? `<span class="chip ${kind}">${escapeHtml(s)}</span>` : '';
  }
  if (col.format === 'count') {
    const n = Number(v) || 0;
    return `<span class="${n ? 'count-hot' : 'muted'}">${n}</span>`;
  }
  const style = col.width ? ` style="max-width: ${escapeHtml(col.width)}"` : '';
  const text = escapeHtml(cellText(v));
  return col.clip === 'start'
    ? `<span class="cell clip-start"${style}><span>${text}</span></span>`
    : `<span class="cell"${style}>${text}</span>`;
}

// ---- list order --------------------------------------------------------------
// A click on a column head sorts by it — ascending, descending, then the
// command's own order again. `sort:` in emu.yaml is where a list starts; a
// click is kept per browser.

const listShown = {}; // 'page.block' → the rows as last drawn (filter and order applied), for ↑/↓

function sortOf(page, block) {
  const key = blockKey(page, block);
  return key in pageState.sort ? pageState.sort[key] : block.sort || null;
}

function cycleSort(page, block, col) {
  const cur = sortOf(page, block);
  pageState.sort[blockKey(page, block)] = cur?.key !== col ? { key: col, dir: 'asc' }
    : cur.dir === 'asc' ? { key: col, dir: 'desc' } : null;
  savePagePrefs();
  renderListRows(page, block);
}

// Numbers as numbers and text in natural order, so a version 1.2.10 comes
// after 1.2.9. Blanks go last either way; equal values keep the command's order.
const naturalOrder = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });

function sortRows(rows, sort, format) {
  if (!sort) return rows;
  const dir = sort.dir === 'desc' ? -1 : 1;
  const blank = (v) => v === null || v === undefined || v === '';
  const compare = (a, b) => format === 'count' || (typeof a === 'number' && typeof b === 'number')
    ? (Number(a) || 0) - (Number(b) || 0)
    : naturalOrder.compare(cellText(a), cellText(b));
  return rows.map((r, i) => [r, i]).sort(([a, i], [b, j]) => {
    const x = a[sort.key], y = b[sort.key];
    if (blank(x) || blank(y)) return blank(x) === blank(y) ? i - j : blank(x) ? 1 : -1;
    return dir * compare(x, y) || i - j;
  }).map(([r]) => r);
}

// A column head; [c.label] for one that isn't a column (a tree's names).
function sortHead(c, sort) {
  const dir = sort?.key === c.key ? sort.dir : null;
  const label = c.label ?? c.key;
  return `<th class="sortable${dir ? ' sorted' : ''}" data-sort="${escapeHtml(c.key)}" title="sort by ${escapeHtml(label)}"`
    + ` aria-sort="${dir === 'asc' ? 'ascending' : dir === 'desc' ? 'descending' : 'none'}">${escapeHtml(label)}`
    + `<span class="sort-mark">${dir === 'asc' ? '▲' : dir === 'desc' ? '▼' : ''}</span></th>`;
}

// ---- tree ----------------------------------------------------------------------
// `tree: [env, path]`: a row's path is the values of those columns, each split
// at `/`. Its last part names the row; the parts before it are folders, which
// a click opens or closes. Folders deeper than `open:` start closed, and a
// click is kept per browser. A filter shows the matching rows with every
// folder above them open. Folders come first, in the order the command lists
// them — or by name, when the tree's own head sorts.

const TREE_SORT = '(tree)'; // the sort key of a tree's head: folder and row names

// A row's path, split once: a draw asks for it to filter, to build the
// tree, to sort and to name the row.
const treePaths = new WeakMap(); // row → {cols, parts}

function treePath(block, row) {
  const cols = block.tree.columns.join('\u0000');
  const known = treePaths.get(row);
  if (known?.cols === cols) return known.parts;
  const split = block.tree.columns.flatMap(c => cellText(row[c]).split('/')).filter(Boolean);
  const parts = split.length ? split : [rowKeyOf(block, row) ?? ''];
  treePaths.set(row, { cols, parts });
  return parts;
}

// The folder keys ('prod/tpl/home') above [row].
function folderKeysOf(block, row) {
  const keys = new Set();
  if (!row) return keys;
  const parts = treePath(block, row);
  for (let i = 1; i < parts.length; i++) keys.add(parts.slice(0, i).join('/'));
  return keys;
}

// [rows] as folders: {key, name, depth, dirs: name → folder, rows: its own rows, all: every row below}.
function buildTree(block, rows) {
  const root = { key: '', name: '', depth: -1, dirs: new Map(), rows: [], all: rows };
  for (const row of rows) {
    let node = root;
    for (const part of treePath(block, row).slice(0, -1)) {
      let next = node.dirs.get(part);
      if (!next) {
        next = { key: node.key ? `${node.key}/${part}` : part, name: part, depth: node.depth + 1, dirs: new Map(), rows: [], all: [] };
        node.dirs.set(part, next);
      }
      next.all.push(row);
      node = next;
    }
    node.rows.push(row);
  }
  return root;
}

// The open part of the tree, top to bottom: {dir, open} and {row, depth}.
function treeItems(page, block, root, { filtering, sort, format }) {
  const opened = pageState.tree[blockKey(page, block)] || {};
  const byName = sort?.key === TREE_SORT;
  const dir = sort?.dir === 'desc' ? -1 : 1;
  const leaf = (r) => treePath(block, r).at(-1);
  const items = [];
  const walk = (node) => {
    const dirs = [...node.dirs.values()];
    if (byName) dirs.sort((a, b) => dir * naturalOrder.compare(a.name, b.name));
    for (const d of dirs) {
      const open = filtering || (d.key in opened ? opened[d.key] : d.depth < block.tree.open);
      items.push({ dir: d, open });
      if (open) walk(d);
    }
    const rows = byName ? [...node.rows].sort((a, b) => dir * naturalOrder.compare(leaf(a), leaf(b))) : sortRows(node.rows, sort, format);
    for (const row of rows) items.push({ row, depth: node.depth + 1 });
  };
  walk(root);
  return items;
}

function treeIndent(depth) { return 10 + depth * 16; }

// [deep] (⌥/Alt-click): every folder below goes the same way.
function toggleDir(page, block, d, { deep = false } = {}) {
  const key = blockKey(page, block);
  const opened = { ...pageState.tree[key] };
  const initial = (x) => x.depth < block.tree.open;
  const open = !(d.key in opened ? opened[d.key] : initial(d));
  const set = (x) => {
    if (open === initial(x)) delete opened[x.key];
    else opened[x.key] = open;
    if (deep) for (const c of x.dirs.values()) set(c);
  };
  set(d);
  if (Object.keys(opened).length) pageState.tree[key] = opened;
  else delete pageState.tree[key];
  savePagePrefs();
  renderListRows(page, block);
}

function renderListRows(page, block) {
  const el = blockEl(block);
  if (!el || currentPage() !== page) return;
  const key = blockKey(page, block);
  const entry = pageState.data[key];
  const host = el.querySelector('[data-rows]');
  const rows = entry?.result?.ok ? entry.result.rows : null;
  el.classList.toggle('loading', !!entry?.loading);
  renderChecksHead(page, block, el);
  if (!rows) {
    listShown[key] = [];
    host.innerHTML = blockNote(page, block, entry);
    el.querySelector('[data-count]').textContent = '';
    return;
  }
  const cols = listColumns(block, rows);
  const filter = (pageState.search[key] || '').toLowerCase();
  const sort = sortOf(page, block);
  const format = cols.find(c => c.key === sort?.key)?.format;
  const matched = filter ? rows.filter(r => rowTexts(block, cols, r).some(t => t.toLowerCase().includes(filter))) : rows;
  // What's drawn, top to bottom: rows ({row, depth}) and, in a tree, folders ({dir, open}).
  const items = block.tree
    ? treeItems(page, block, buildTree(block, matched), { filtering: !!filter, sort, format })
    : sortRows(matched, sort, format).map(row => ({ row, depth: 0 }));
  const shown = listShown[key] = items.filter(i => i.row).map(i => i.row);
  const dirs = new Map(items.filter(i => i.dir).map(i => [i.dir.key, i.dir]));
  const selectable = block.id === page.selection;
  const picked = selectable ? pageState.selected[page.id] : undefined;
  // A closed folder that holds the picked row says so.
  const pickedIn = block.tree && selectable ? folderKeysOf(block, selectedRow(page)) : new Set();
  el.querySelector('[data-count]').textContent = filter ? `${matched.length} / ${rows.length}` : `${rows.length}`;
  const actions = block.rowActions;
  const checked = block.check ? checkedKeys(page, block) : null;
  const checking = block.check && pageState.running.has(`${page.id}.${block.id}.check`);
  const checkedIn = (rs) => checked ? rs.filter(r => checked.has(rowKeyOf(block, r))).length : 0;
  const checkBox = (attr, rs) => `<input type="checkbox" ${attr}${rs.length && checkedIn(rs) === rs.length ? ' checked' : ''}`
    + `${checking || !rs.length ? ' disabled' : ''} />`;
  const checkAll = checked
    ? `<th class="lst-check">${checkBox(`data-check-all title="${block.tree && !filter ? 'check all, folded ones too' : 'check all shown'}"`, matched)}</th>` : '';
  const treeHead = block.tree ? sortHead({ key: TREE_SORT, label: block.tree.columns.join(' / ') }, sort) : '';
  const buttons = () => actions.map(a => {
    const busy = pageState.running.has(`${page.id}.${block.id}.${a.id}`);
    const blocked = blockedByChecks(page, a);
    const title = blocked ? `check a row in ${a.needsChecked} first` : a.command;
    return `<button class="${a.confirm ? 'warnish' : ''}${busy ? ' busy' : ''}" data-action="${escapeHtml(a.id)}" title="${escapeHtml(title)}"${blocked ? ' disabled' : ''}>${escapeHtml(a.label)}${busy ? ' …' : ''}</button>`;
  }).join('');
  const rowHtml = ({ row: r, depth }) => {
    const rk = rowKeyOf(block, r);
    return `<tr data-row="${escapeHtml(rk ?? '')}"${selectable ? ' class="pick' + (rk === picked ? ' sel' : '') + '"' : ''}>`
      + (checked ? `<td class="lst-check"><input type="checkbox" data-check${checked.has(rk) ? ' checked' : ''}${checking ? ' disabled' : ''} /></td>` : '')
      + (block.tree ? `<td class="tree-name" style="padding-left: ${treeIndent(depth) + 14}px"><span class="cell">${escapeHtml(treePath(block, r).at(-1))}</span></td>` : '')
      + cols.map(c => `<td>${cellHtml(r[c.key], c)}</td>`).join('')
      + (actions.length ? `<td class="row-actions">${buttons()}</td>` : '')
      + '</tr>';
  };
  const dirHtml = ({ dir: d, open }) => `<tr class="tree-dir${!open && pickedIn.has(d.key) ? ' has-sel' : ''}" data-dir="${escapeHtml(d.key)}"`
    + `${filter ? '' : ' title="⌥/Alt-click: every folder below too"'}>`
    + (checked ? `<td class="lst-check">${checkBox('data-check-dir', d.all)}</td>` : '')
    + `<td class="tree-name" colspan="${cols.length + 1}" style="padding-left: ${treeIndent(d.depth)}px">`
    + `<span class="tree-caret">${open ? '▾' : '▸'}</span>${escapeHtml(d.name)}<span class="tree-count">${d.all.length}</span></td>`
    + (actions.length ? '<td class="row-actions"></td>' : '')
    + '</tr>';
  host.innerHTML = rows.length
    ? `<table class="lst${block.tree ? ' tree' : ''}"><thead><tr>${checkAll}${treeHead}${cols.map(c => sortHead(c, sort)).join('')}${actions.length ? '<th class="row-actions"></th>' : ''}</tr></thead><tbody>`
      + items.map(i => i.dir ? dirHtml(i) : rowHtml(i)).join('') + '</tbody></table>'
      + (entry.result.truncated ? `<div class="ext-empty">first ${rows.length} of ${entry.result.truncated} rows</div>` : '')
    : '<div class="ext-empty">no rows</div>';
  const byKey = new Map(shown.map(r => [rowKeyOf(block, r) ?? '', r]));
  host.querySelectorAll('th[data-sort]').forEach(th => { th.onclick = () => cycleSort(page, block, th.dataset.sort); });
  const all = host.querySelector('[data-check-all]');
  if (all) {
    all.indeterminate = checkedIn(matched) > 0 && checkedIn(matched) < matched.length;
    all.onclick = (e) => { e.preventDefault(); setChecked(page, block, matched, checkedIn(matched) < matched.length); };
  }
  host.querySelectorAll('tr[data-dir]').forEach(tr => {
    const d = dirs.get(tr.dataset.dir);
    if (!filter) tr.onclick = (e) => toggleDir(page, block, d, { deep: e.altKey }); // a filter keeps every folder above a match open
    const box = tr.querySelector('[data-check-dir]');
    if (!box) return;
    box.indeterminate = checkedIn(d.all) > 0 && checkedIn(d.all) < d.all.length;
    box.parentElement.onclick = (e) => e.stopPropagation(); // checking a folder doesn't fold it
    box.onclick = (e) => { e.preventDefault(); setChecked(page, block, d.all, checkedIn(d.all) < d.all.length); };
  });
  host.querySelectorAll('tr[data-row]').forEach(tr => {
    const row = byKey.get(tr.dataset.row);
    if (selectable) tr.onclick = () => select(page, block, row);
    const box = tr.querySelector('[data-check]');
    if (box) {
      box.parentElement.onclick = (e) => e.stopPropagation(); // checking a row doesn't pick it
      box.onclick = (e) => { e.preventDefault(); setChecked(page, block, [row], !checked.has(rowKeyOf(block, row))); };
    }
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

// The head of a check: list — how many are checked, and its bulk buttons.
function renderChecksHead(page, block, el) {
  const host = el.querySelector('[data-checks]');
  if (!host) return;
  const n = checkedRows(page, block).length;
  host.innerHTML = `<span class="muted">${n} checked</span>` + block.rowActions.filter(a => a.bulk).map(a => {
    const progress = pageState.bulk[`${page.id}.${block.id}.${a.id}`];
    return `<button class="${a.confirm ? 'warnish' : ''}${progress ? ' busy' : ''}" data-bulk="${escapeHtml(a.id)}"`
      + ` title="${escapeHtml(`once per checked row: ${a.command}`)}"${n && !progress ? '' : ' disabled'}>`
      + `${escapeHtml(a.label)} · ${progress ? escapeHtml(progress) : n}</button>`;
  }).join('');
  host.querySelectorAll('[data-bulk]').forEach(btn => {
    btn.onclick = () => runBulk(page, block, block.rowActions.find(a => a.id === btn.dataset.bulk));
  });
}

// diff: the unified diff its command prints, drawn like the Changes tab;
// output that isn't a diff (a file shown as it is) is drawn as numbered lines.
// Segments pick what it compares against ({{seg}}). With `optional:` none is
// picked at first and a click on the picked one turns it off — {{seg}} is
// then empty; `hide:` leaves out the segment equal to that value of the
// picked row. A segment out of view counts as off (or the first shown, when
// one must be picked); the choice itself is kept.
function shownSegments(page, block) {
  if (!block.segmentsHide) return block.segments;
  const sel = selectedRow(page);
  const hidden = block.segmentsHide.replace(/\{\{\s*selected\.([A-Za-z0-9_-]+)\s*\}\}/g, (_, col) => (sel ? cellText(sel[col]) : ''));
  return block.segments.filter(s => s !== hidden);
}

function segOf(page, block) {
  const shown = shownSegments(page, block);
  const s = pageState.seg[blockKey(page, block)];
  if (shown.includes(s)) return s;
  return block.segmentsOptional ? '' : shown[0] ?? block.segments[0];
}

function initDiff(page, block, el) {
  el.innerHTML = `<div class="blk-head"><span class="name" data-title>${escapeHtml(block.title)}</span>`
    + `<span class="plus" data-plus></span><span class="minus" data-minus></span>`
    + `<span class="cmd" data-cmd title="${escapeHtml(block.command)}"></span>`
    + (block.segments.length ? `<span class="seg-pick"><span class="muted" data-vs>vs</span><span class="seg" data-seg></span></span>` : '')
    + '</div><section class="diff-view" data-diff></section>';
  renderSegments(page, block, el);
}

function renderSegments(page, block, el) {
  const host = el.querySelector('[data-seg]');
  if (!host) return;
  const cur = segOf(page, block);
  const shown = shownSegments(page, block);
  host.hidden = !shown.length;
  el.querySelector('[data-vs]').hidden = !cur || !shown.length; // nothing to compare against: the output as it is
  host.innerHTML = shown.map(s => `<button class="${s === cur ? 'on' : ''}" data-s="${escapeHtml(s)}"`
    + `${block.segmentsOptional && s === cur ? ' title="click again to compare with nothing"' : ''}>${escapeHtml(s)}</button>`).join('');
  host.querySelectorAll('button').forEach(b => {
    b.onclick = () => {
      const off = block.segmentsOptional && b.dataset.s === segOf(page, block);
      pageState.seg[blockKey(page, block)] = off ? '' : b.dataset.s;
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
  renderSegments(page, block, el); // the picked row may hide one
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
  const patch = r.patch || '';
  const files = splitPatch(patch);
  const added = files.reduce((n, f) => n + f.added, 0), deleted = files.reduce((n, f) => n + f.deleted, 0);
  el.querySelector('[data-plus]').textContent = files.length ? `+${added}` : '';
  el.querySelector('[data-minus]').textContent = files.length ? `−${deleted}` : '';
  const top = view.scrollTop;
  view.innerHTML = files.length || !patch.trim() ? patchFilesHtml(files) : textLinesHtml(patch);
  view.scrollTop = top; // a refresh of the same diff keeps the reader's place
}

// Output with no hunk in it: its lines, numbered.
function textLinesHtml(text) {
  return text.replace(/\n$/, '').split('\n')
    .map((line, i) => `<div class="dl"><span class="ln">${i + 1}</span><span class="code">${escapeHtml(line) || ' '}</span></div>`).join('');
}

function patchFilesHtml(files) {
  return files.length
    ? files.map(f => (f.path ? `<div class="dfile-head"><span class="path">${escapeHtml(f.path)}</span>`
        + `<span class="plus">+${f.added}</span><span class="minus">−${f.deleted}</span></div>` : '') + renderPatch(f.patch)).join('')
    : '<div class="diff-note">no differences</div>';
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
// postMessage ({type: 'emu:data', …}) and may ask for its declared actions —
// toolbar ids and the block's own — which run like a button press,
// confirmation included. The file arrives through the API and goes in as
// srcdoc, so the session token never appears in a frame's URL.
//
// In front of the file goes a small helper, window.emu (frameHelper), so a
// custom view needn't speak postMessage itself:
//   frame → dashboard                     dashboard → frame
//   emu:run {reqId, id, input, confirm?}  emu:result {reqId, ok, exitCode, error, output, data}
//   emu:confirm {reqId, title, message, detail, danger, button}   emu:result {reqId, value: bool}
//   emu:prompt {reqId, title, message, fields: [{name, label, default}]}  emu:result {reqId, value: {…} | null}
//   emu:choose {reqId, title, message, options: [{value, label}], multiple}  emu:result {reqId, value | null}
//   emu:select {reqId, key}  ·  emu:refresh {reqId, block?}             emu:result {reqId, ok, error?}
//   emu:toast {text, level}  ·  emu:ready  ·  emu:action {id} (emu:run without a reply)
// run's confirm: the view's own words ({title, message, detail, danger,
// button}) for the dialog of that run — one dialog, not emu.confirm and then
// the run's own.
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

// window.emu inside a frame. Runs there, not here: it is put in the srcdoc as
// source text, so it must not use anything from this file.
function frameHelper() {
  const pending = new Map();
  const listeners = [];
  let seq = 0;
  let last = null;
  const send = (m) => parent.postMessage(m, '*');
  const ask = (type, body) => new Promise((resolve) => {
    const reqId = ++seq;
    pending.set(reqId, resolve);
    send({ ...body, type, reqId });
  });
  addEventListener('message', (e) => {
    const m = e.data;
    if (e.source !== parent || !m || typeof m !== 'object') return;
    if (m.type === 'emu:data') {
      last = m;
      for (const fn of listeners.slice()) {
        try { fn(m); } catch (err) { console.error(err); }
      }
    } else if (m.type === 'emu:result' && pending.has(m.reqId)) {
      const resolve = pending.get(m.reqId);
      pending.delete(m.reqId);
      const { type, reqId, ...result } = m;
      resolve(result);
    }
  });
  const emu = {
    // fn({ok, data, text, error, needs, selected}) now (if data came already) and on every refresh.
    onData(fn) {
      listeners.push(fn);
      if (last) fn(last);
      return () => { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); };
    },
    run: (id, opts = {}) => ask('emu:run', {
      id: String(id),
      input: opts.input || {},
      ...(opts.confirm ? { confirm: typeof opts.confirm === 'string' ? { title: opts.confirm } : opts.confirm } : {}),
    }),
    confirm: (opts = {}) => ask('emu:confirm', typeof opts === 'string' ? { title: opts } : opts).then((r) => r.value === true),
    prompt: (opts = {}) => ask('emu:prompt', opts).then((r) => r.value ?? null),
    // {title, message?, options: [{value, label} | 'value'], multiple?} → the value (multiple: an array), or null.
    choose: (opts = {}) => ask('emu:choose', opts).then((r) => r.value ?? null),
    // Pick the page's row with this key, as a click would → {ok, error?}.
    select: (key) => ask('emu:select', { key }),
    // Fetch this block's data again (onData gets it), or another block's on the page → {ok, error?}.
    refresh: (block) => ask('emu:refresh', block === undefined ? {} : { block: String(block) }),
    toast: (text, level = 'info') => send({ type: 'emu:toast', text: String(text), level }),
  };
  Object.defineProperty(window, 'emu', { value: Object.freeze(emu) });
}
// Its source goes in as text (Function.prototype.toString): a minifier that renames or inlines it breaks the frame.
const FRAME_HELPER = `<script>(${frameHelper})();</script>`;

function withFrameCsp(html) {
  const meta = `<meta http-equiv="Content-Security-Policy" content="${FRAME_CSP}">${FRAME_HELPER}`;
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

// Requests from frames. Only a frame of the page on screen gets anything; one
// left over from a page the dashboard moved away from is told so, and so is
// one folded out of sight — which still gets its data (emu:ready).
window.addEventListener('message', async (e) => {
  const msg = e.data;
  const frame = [...pageEls.body.querySelectorAll('iframe.ext-frame')].find(f => f.contentWindow === e.source);
  if (!frame || !msg || typeof msg !== 'object') return;
  const reply = (answer) => {
    if (typeof msg.reqId === 'number' || typeof msg.reqId === 'string') {
      e.source.postMessage({ ...answer, type: 'emu:result', reqId: msg.reqId }, '*');
    }
  };
  const page = currentPage();
  const block = page && !pageEls.body.hidden
    && page.blocks.find(b => b.kind === 'html' && blockEl(b)?.querySelector('iframe') === frame);
  if (!block || (msg.type !== 'emu:ready' && outOfSight(page, block))) {
    reply({ ok: false, value: null, error: 'this view is not on screen' });
    return;
  }
  // A held confirm waits for its view's run only (frameRun); anything else lets it go.
  if (msg.type !== 'emu:run' && msg.type !== 'emu:action') endHold();
  switch (msg.type) {
    case 'emu:ready': postFrameData(page, block); break;
    case 'emu:action': frameRun(page, block, msg.id); break; // the older form: no reply
    case 'emu:run': reply(await frameRun(page, block, msg.id, msg.input, msg.confirm)); break;
    case 'emu:confirm': {
      const ask = frameAsk(msg);
      const a = await frameDialog(page, block, { verb: 'asks', ...ask, keep: { key: blockKey(page, block), ask } });
      reply({ value: a.ok === true, ...(a.ok ? {} : { error: refusalText(a) }) });
      break;
    }
    case 'emu:choose': {
      const options = frameOptions(msg.options);
      if (!options.length) { reply({ value: null, error: 'choose needs options: [{value, label?}]' }); break; }
      const multiple = msg.multiple === true;
      const a = await frameDialog(page, block, {
        verb: 'asks', title: clip(msg.title, 200) || 'Choose', message: clip(msg.message, 2000),
        choices: { options, multiple }, button: clip(msg.button, 40) || 'OK',
      });
      const picked = a.ok ? a.picked.map(i => options[i].value) : null;
      reply({ value: picked && (multiple ? picked : picked[0] ?? null), ...(a.ok ? {} : { error: refusalText(a) }) });
      break;
    }
    case 'emu:select': reply(frameSelect(page, msg.key)); break;
    case 'emu:refresh': reply(frameRefresh(page, block, msg.block)); break;
    case 'emu:prompt': {
      const seen = new Set();
      const fields = (Array.isArray(msg.fields) ? msg.fields : []).slice(0, 12)
        .filter(f => f && typeof f.name === 'string' && f.name && !seen.has(f.name) && seen.add(f.name))
        .map(f => ({ name: f.name, label: clip(f.label ?? f.name, 100), default: clip(f.default, 2000) }));
      if (!fields.length) { reply({ value: null, error: 'prompt needs fields: [{name, label?, default?}]' }); break; }
      const a = await frameDialog(page, block, {
        verb: 'asks', title: clip(msg.title, 200) || 'Input', message: clip(msg.message, 2000),
        fields, button: clip(msg.button, 40) || 'OK',
      });
      reply({ value: a.ok ? a.values : null, ...(a.ok ? {} : { error: refusalText(a) }) });
      break;
    }
    case 'emu:toast':
      toast(`${msg.level === 'error' ? '✗ ' : ''}${block.title}: ${clip(msg.text, 300)}`); // named, so it can't pass for emu's own
      break;
  }
});

// What a frame may hold: text, cut to [n] characters.
function clip(v, n) {
  return v === undefined || v === null ? '' : String(v).slice(0, n);
}

// A view's words for a dialog (emu.confirm, run's confirm), as text.
function frameAsk(m) {
  return {
    title: clip(m.title, 200) || 'Confirm?', message: clip(m.message, 2000), detail: clip(m.detail, 20000),
    danger: m.danger === true, button: clip(m.button, 40) || 'OK',
  };
}

// emu.choose's options: {value, label?} or a bare value; a value is a string,
// number or boolean, and given once.
function frameOptions(options) {
  const seen = new Set();
  return (Array.isArray(options) ? options : []).slice(0, 200)
    .map(o => (o !== null && typeof o === 'object' ? o : { value: o }))
    .filter(o => ['string', 'number', 'boolean'].includes(typeof o.value) && !seen.has(JSON.stringify(o.value)) && seen.add(JSON.stringify(o.value)))
    .map(o => ({ value: o.value, label: clip(o.label ?? o.value, 200) }));
}

// emu.select(key): the page's selection list picks that row, as a click would.
function frameSelect(page, key) {
  const list = selectionList(page);
  if (!list) return { ok: false, error: 'this page has no selection list (selection:)' };
  const rows = pageState.data[blockKey(page, list)]?.result?.rows || [];
  const row = (typeof key === 'string' || typeof key === 'number') ? rows.find(r => rowKeyOf(list, r) === String(key)) : null;
  if (!row) return { ok: false, error: `no row "${clip(key, 60)}" in ${list.title}` };
  select(page, list, row);
  return { ok: true };
}

// emu.refresh(blockId?): fetch a block of this page again — the asking one if
// none is named. Not while it loads, nor twice in a second (a view that
// refreshes from onData would otherwise run its command in a loop).
const frameRefreshed = {}; // 'page.block' → when a frame last had it fetched
const FRAME_REFRESH_MS = 1000;
function frameRefresh(page, block, id) {
  const target = id === undefined || id === null ? block : page.blocks.find(b => b.id === id);
  if (!target || target.kind === 'output' || target.kind === 'form') {
    return { ok: false, error: `no block "${clip(id, 60)}" with data on this page` };
  }
  const key = blockKey(page, target);
  const now = Date.now();
  if (pageState.data[key]?.loading || now - (frameRefreshed[key] || 0) < FRAME_REFRESH_MS) {
    return { ok: false, busy: true, error: `${target.title || target.id} is already loading` };
  }
  frameRefreshed[key] = now;
  loadBlocks(page, [target]);
  return { ok: true };
}

// When [page] is drawn (shown, or drawn again): forget the refreshes of
// blocks not on it, or no longer on it, and those too old to hold one back.
function pruneFrameRefreshed(page) {
  const now = Date.now();
  const keep = new Set(page ? page.blocks.map(b => blockKey(page, b)) : []);
  for (const [key, at] of Object.entries(frameRefreshed)) {
    if (!keep.has(key) || now - at >= FRAME_REFRESH_MS) delete frameRefreshed[key];
  }
}

// emu.run(id, {input, confirm}): the block's own action, or a toolbar action
// it lists. Only names in the block's inputs: go along. [confirm]: the view's
// words for the run — with the dialog of a `confirm:` action, or alone before
// one without. A `confirm:` action run right after the view's own emu.confirm
// goes on in that dialog (takeHold).
async function frameRun(page, block, id, input, confirm) {
  const own = block.blockActions.find(a => a.id === id);
  const item = own || (block.actions.includes(id) ? page.toolbar.find(i => i.kind === 'action' && i.id === id) : null);
  const key = blockKey(page, block);
  let ask = confirm && typeof confirm === 'object' ? frameAsk(confirm) : null;
  const held = item?.confirm && !ask ? takeHold(key) : null;
  if (!held) endHold();
  if (!item) {
    toast(`${block.title}: action "${clip(id, 60)}" is not allowed`);
    return { ok: false, error: `action "${clip(id, 60)}" is not allowed — list it under the block's actions:` };
  }
  if (ask && !item.confirm) {
    const a = await frameDialog(page, block, { verb: 'asks', ...ask });
    if (!a.ok) return { ok: false, cancelled: true, ...(a.busy ? { busy: true } : {}), exitCode: null, error: refusalText(a), output: '', data: null };
    ask = null;
  }
  const pid = encodeURIComponent(page.id);
  const opts = { frame: block, ask: ask || held };
  const j = own
    ? await runItem(page, own, `${page.id}.${block.id}.${own.id}`,
      `/api/pages/${pid}/frames/${encodeURIComponent(block.id)}/${encodeURIComponent(own.id)}`,
      { ...runValues(page), input: frameInput(block, input) }, opts)
    : await runItem(page, item, itemKey(page, item), `/api/pages/${pid}/run/${encodeURIComponent(item.id)}`, runValues(page), opts);
  if (held) endHold(true); // it ended without a dialog (refused, failed): let the held one go
  return {
    ok: !!j.ok,
    exitCode: j.exitCode ?? null,
    error: j.error ?? null,
    output: j.output ?? '',
    data: j.data ?? null,
    ...(j.busy ? { busy: true } : {}),
    ...(j.cancelled ? { cancelled: true } : {}),
    ...(j.needs ? { needs: j.needs } : {}),
  };
}

function frameInput(block, input) {
  const out = {};
  if (input && typeof input === 'object') {
    for (const name of block.inputs) if (input[name] !== undefined && input[name] !== null) out[name] = input[name];
  }
  return out;
}

// form: fields and the buttons that use them. What's typed fills
// {{input.<field>}} server-side and is kept per browser. With no fields
// (a panel) it's the title, an optional note and the buttons.
function formValues(page, block) {
  const saved = pageState.input[blockKey(page, block)] || {};
  return Object.fromEntries(block.fields.map(f => [f.name, saved[f.name] ?? f.default ?? '']));
}

function initForm(page, block, el) {
  const key = blockKey(page, block);
  const values = formValues(page, block);
  const fieldId = (f) => `f-${page.id}-${block.id}-${f.name}`;
  el.innerHTML = `<div class="blk-head"><span class="name">${escapeHtml(block.title)}</span></div>`
    + (block.note ? `<div class="form-note">${escapeHtml(block.note)}</div>` : '')
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
    const blocked = blockedByChecks(page, a);
    const title = blocked ? `check a row in ${a.needsChecked} first` : a.command;
    return `<button class="${a.confirm ? 'warnish' : ''}${busy ? ' busy' : ''}" data-action="${escapeHtml(a.id)}"`
      + ` title="${escapeHtml(title)}"${blocked ? ' disabled' : ''}>${escapeHtml(a.label)}${busy ? ' …' : ''}</button>`;
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

// output: the page's runs. One in flight shows its output as it comes; a
// finished one what ran, how it ended and what it printed. Addresses are
// links. The head's menu goes back to an earlier run (this tab keeps the last
// 10); a new run brings it to the newest again.
function initOutput(page, block, el) {
  el.innerHTML = '<div class="blk-head"><span class="name">output</span><span class="cmd" data-cmd></span>'
    + '<span class="meta" data-meta></span><select class="out-hist" data-hist title="recent runs" hidden></select></div>'
    + '<div class="ext-empty" data-none>no run yet — press a toolbar button</div><pre class="ext-out" data-out hidden></pre>';
  el.querySelector('[data-hist]').onchange = (e) => {
    pageState.viewing[page.id] = e.target.value === '' ? null : Number(e.target.value);
    renderOutputs(page);
  };
}

// [head]: the output is folded away — only its head (what runs, how long) is
// drawn, the rest once it unfolds.
function renderOutput(page, el, { head = false } = {}) {
  const busy = [...pageState.running].filter(k => k.startsWith(`${page.id}.`));
  const hist = pageState.history[page.id] || [];
  const viewing = pageState.viewing[page.id] ?? null;
  const liveKey = viewing === null ? busy[busy.length - 1] : undefined; // the latest started
  const run = liveKey ? null : hist[viewing ?? 0];
  const cmd = el.querySelector('[data-cmd]'), meta = el.querySelector('[data-meta]'), pre = el.querySelector('[data-out]');
  renderHistory(el, hist, viewing, busy.length > 0);
  el.querySelector('[data-none]').hidden = !!(liveKey || run);
  pre.hidden = !(liveKey || run);
  if (liveKey) startOutputTicker();
  if (!liveKey && !run) { cmd.textContent = meta.textContent = ''; el.dataset.shown = ''; return; }
  // Something new starts at the top (a live run at its end); the same keeps its place, or its end.
  // A live run is told apart by when it started: one that ran again while
  // this was folded is new, not more of the one drawn before.
  const id = liveKey ? `live:${liveKey}@${pageState.liveSince[liveKey]}` : `run:${page.id}.${run.item}@${run.at}`;
  const prev = el.dataset.shown || '';
  if (liveKey) {
    cmd.textContent = `running ${busy.map(k => k.slice(page.id.length + 1)).join(', ')}…`;
    cmd.title = '';
    const since = pageState.liveSince[liveKey];
    meta.textContent = since ? `${Math.round((Date.now() - since) / 1000)}s` : '';
    if (head) return;
    const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
    el.dataset.shown = id;
    renderLive(pre, el, liveKey, prev === id);
    if (prev !== id) pre.scrollTop = pre.scrollHeight;
    else if (atEnd) pre.scrollTop = pre.scrollHeight;
    return;
  }
  if (prev === id) return; // drawn already: a finished run doesn't change
  const mark = run.ok ? '<span class="ok-mark">✓</span>' : '<span class="fail-mark">✗</span>';
  const then = run.then ? ` · ${escapeHtml(run.then.action)}: ${escapeHtml(run.then.message || (run.then.ok ? 'ok' : 'failed'))}` : '';
  cmd.textContent = `$ ${run.command}`;
  cmd.title = run.command;
  meta.innerHTML = `${mark} ${escapeHtml(run.error || 'exit 0')} · ${(run.ms / 1000).toFixed(1)}s · ${new Date(run.at).toLocaleTimeString()}${then}`;
  if (head) return;
  const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
  el.dataset.shown = id;
  const body = stripAnsi(run.output);
  pre.innerHTML = body ? linkify(body) : '<span class="muted">(no output)</span>';
  el._live = null;
  // The run that was just streaming here keeps its place (or its end); another starts at the top.
  if (!prev.startsWith(`live:${page.id}.${run.item}@`)) pre.scrollTop = 0;
  else if (atEnd) pre.scrollTop = pre.scrollHeight;
}

// A run in flight: only what came since the last draw is added, so a chatty
// command doesn't redraw its whole output for every piece. The buffer keeps
// the last LIVE_LIMIT characters; once the page holds twice that, it's
// redrawn from the buffer. An escape sequence cut at the end of a piece waits
// for the rest.
function renderLive(pre, el, key, same) {
  const text = pageState.live[key] || '';
  const total = pageState.liveTotal[key] || 0;
  const drawn = el._live;
  const fresh = drawn ? total - drawn.total : -1;
  if (same && drawn && drawn.total > 0 && fresh >= 0 && fresh <= text.length && drawn.size + fresh <= 2 * LIVE_LIMIT) {
    if (!fresh) return;
    const piece = text.slice(text.length - fresh);
    const keep = heldEscape(piece);
    pre.insertAdjacentHTML('beforeend', linkify(stripAnsi(piece.slice(0, piece.length - keep))));
    el._live = { total: total - keep, size: drawn.size + fresh - keep };
    return;
  }
  const keep = heldEscape(text);
  const body = stripAnsi(text.slice(0, text.length - keep));
  pre.innerHTML = body ? linkify(body) : '<span class="muted">no output yet</span>';
  el._live = { total: body ? total - keep : 0, size: text.length - keep };
}

// How many characters at the end of [text] are an escape sequence still coming.
function heldEscape(text) {
  const at = text.lastIndexOf('\x1b');
  if (at < 0 || text.length - at > 32 || /^\x1b\[[0-9;?]*[ -\/]*[@-~]/.test(text.slice(at))) return 0;
  return text.length - at;
}

// The elapsed time of a run in flight, once a second while one is on screen.
let outputTicker = null;
function startOutputTicker() {
  if (outputTicker) return;
  outputTicker = setInterval(() => {
    const page = currentPage();
    if (page && [...pageState.running].some(k => k.startsWith(`${page.id}.`))) renderOutputs(page);
    else { clearInterval(outputTicker); outputTicker = null; }
  }, 1000);
}

// The menu of recent runs, rebuilt only when they change — not for every
// piece of live output, which would close it under the pointer.
function renderHistory(el, hist, viewing, live) {
  const sel = el.querySelector('[data-hist]');
  const sig = `${hist.map(r => `${r.item}@${r.at}`).join('|')}#${viewing}#${live}`;
  if (sel.dataset.sig === sig) return;
  sel.dataset.sig = sig;
  sel.hidden = !(hist.length > 1 || (hist.length && live));
  sel.innerHTML = `<option value="">${live ? 'running now' : 'latest'}</option>` + hist.map((r, i) =>
    `<option value="${i}">${escapeHtml(`${new Date(r.at).toLocaleTimeString()} · ${r.item} ${r.ok ? '✓' : '✗'}`)}</option>`).join('');
  sel.value = viewing === null ? '' : String(viewing);
}

// ---- dialogs -----------------------------------------------------------------
// One dialog at a time, drawn here — outside every frame, where a frame can't
// read or press it: the confirmation of a `confirm:` run, and what a custom
// view asks (emu.confirm, emu.prompt, emu.choose). Every text goes in as text,
// never as HTML. A run's words come from emu.yaml (`confirm:`); the command it
// runs is always there, folded under them. When a view explains the run it
// asks for, its words lead and emu.yaml's follow under [action]. A danger
// dialog keeps focus on Cancel, so Enter alone doesn't press Run; a failed
// preview disables Run unless the action allows it.

const dlg = Object.fromEntries(['from', 'title', 'msg', 'detail', 'fields', 'choices', 'action', 'action-title', 'action-msg',
  'action-detail', 'preview', 'command', 'cmd-box', 'cmd-line', 'cmd', 'then', 'block', 'wait', 'cancel', 'run']
  .map(k => [k, document.getElementById(`confirm-${k}`)]));
let dialogResolve = null;
let dialogKeep = null; // openDialog's [keep]: what to hold on to if OK is pressed
let dialogHold = null; // {key, ask, timer}: a view's confirm, just answered OK, still on screen (holdDialog)
const dialogOpen = () => dialogResolve !== null || dialogHold !== null;

// Resolves to {ok, values?, picked?} — values: the fields as typed, picked: the
// indexes of the chosen [choices] — or {ok: false, block: true}. [keep]: on OK
// the dialog stays up for a moment (holdDialog).
function openDialog({ from = '', title, message = '', detail = '', fields = [], choices = null, action = null, preview = null, command = '', then = '', button = 'OK', danger = false, offerBlock = false, keep = null }) {
  const show = (el, text) => { el.textContent = text; el.hidden = !text; };
  if (dialogHold) { clearTimeout(dialogHold.timer); dialogHold = null; } // a held dialog goes on as this one
  dialogKeep = keep;
  pageEls.confirm.classList.toggle('danger', danger);
  pageEls.confirm.classList.toggle('wide', !!preview);
  show(dlg.from, from);
  dlg.title.textContent = title;
  show(dlg.msg, message);
  show(dlg.detail, detail);
  dlg.fields.replaceChildren();
  dlg.fields.hidden = !fields.length;
  for (const f of fields) {
    const id = `confirm-field-${dlg.fields.children.length}`;
    const label = Object.assign(document.createElement('label'), { htmlFor: id, textContent: f.label });
    const input = Object.assign(document.createElement('input'), {
      id, className: 'field', type: 'text', value: f.default || '', autocomplete: 'off', spellcheck: false,
    });
    input.dataset.name = f.name;
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !danger) dlg.run.click(); });
    dlg.fields.append(label, input);
  }
  renderChoices(choices, danger);
  dlg.action.hidden = !action;
  if (action) {
    dlg['action-title'].textContent = action.title;
    show(dlg['action-msg'], action.message);
    show(dlg['action-detail'], action.detail);
  }
  renderConfirmPreview(preview);
  dlg.command.hidden = !command;
  dlg.cmd.textContent = dlg['cmd-line'].textContent = command ? `$ ${command}` : '';
  // Nothing else to read: show the command unfolded.
  dlg['cmd-box'].open = !message && !preview && !action;
  dlg.then.textContent = then;
  dlg.run.textContent = button;
  dlg.run.disabled = !!preview?.blocks || (!!choices && !choices.multiple);
  dlg.run.title = preview?.blocks ? 'the preview failed' : '';
  dlg.cancel.disabled = false;
  dlg.wait.hidden = true;
  dlg.block.hidden = !offerBlock;
  pageEls.confirm.hidden = pageEls.confirmDim.hidden = false;
  (fields.length ? dlg.fields.querySelector('input') : choices ? dlg.choices.querySelector('input')
    : danger || dlg.run.disabled ? dlg.cancel : dlg.run).focus();
  return new Promise((resolve) => { dialogResolve = resolve; });
}

// emu.choose: one radio (OK waits for a pick) or a checkbox per option.
function renderChoices(choices, danger) {
  dlg.choices.replaceChildren();
  dlg.choices.hidden = !choices;
  if (!choices) return;
  for (const [i, o] of choices.options.entries()) {
    const input = Object.assign(document.createElement('input'), {
      type: choices.multiple ? 'checkbox' : 'radio', name: 'confirm-choice', value: String(i),
    });
    input.addEventListener('change', () => { if (!choices.multiple) dlg.run.disabled = false; });
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !danger && !dlg.run.disabled) dlg.run.click(); });
    const label = document.createElement('label');
    label.append(input, Object.assign(document.createElement('span'), { textContent: o.label }));
    dlg.choices.append(label);
  }
}

// A preview's output: a diff like the Changes tab, JSON rows as a table, or text.
function renderConfirmPreview(pv) {
  const host = document.getElementById('confirm-preview');
  host.hidden = !pv;
  host.classList.toggle('failed', !!pv && !pv.ok);
  if (!pv) { host.innerHTML = ''; return; }
  const status = pv.ok ? '' : `<span class="fail-mark">✗ preview ${escapeHtml(pv.error || 'failed')}</span>`;
  let body;
  if (pv.ok && pv.kind === 'diff') {
    body = `<section class="diff-view pv-body">${patchFilesHtml(splitPatch(pv.patch || ''))}</section>`;
  } else if (pv.ok && pv.kind === 'table') {
    const cols = Object.keys(pv.rows[0] || {});
    body = `<div class="pv-body"><table class="lst"><thead><tr>${cols.map(c => `<th>${escapeHtml(c)}</th>`).join('')}</tr></thead><tbody>`
      + pv.rows.map(r => `<tr>${cols.map(c => `<td>${escapeHtml(cellText(r[c]))}</td>`).join('')}</tr>`).join('')
      + '</tbody></table>'
      + (pv.truncated ? `<div class="ext-empty">first ${pv.rows.length} of ${pv.truncated} rows</div>` : '') + '</div>';
  } else {
    const text = stripAnsi(pv.text || '').trimEnd();
    body = `<pre class="pv-body">${escapeHtml(text) || '<span class="muted">(no output)</span>'}</pre>`;
  }
  host.innerHTML = `<div class="pv-head"><span class="muted">preview</span><span class="cmd" title="${escapeHtml(pv.command)}">$ ${escapeHtml(pv.command)}</span>${status}</div>`
    + body + (pv.ok || pv.blocks === false ? '' : '<div class="fail-mark">Run is off until the preview succeeds.</div>');
}

function closeDialog(answer) {
  if (!dialogResolve) { endHold(true); return; } // Esc or a click outside a held dialog
  const resolve = dialogResolve;
  dialogResolve = null;
  if (answer.ok && dialogKeep) holdDialog(dialogKeep);
  else hideDialog();
  dialogKeep = null;
  resolve(answer);
}
function hideDialog() {
  pageEls.confirm.hidden = pageEls.confirmDim.hidden = true;
  setTimeout(nextRunAsk); // a question that waited for this dialog
}
dlg.run.onclick = () => closeDialog({
  ok: true,
  values: Object.fromEntries([...dlg.fields.querySelectorAll('input')].map(i => [i.dataset.name, i.value])),
  picked: [...dlg.choices.querySelectorAll('input:checked')].map(i => Number(i.value)),
});
dlg.cancel.onclick = () => closeDialog({ ok: false });
dlg.block.onclick = () => closeDialog({ ok: false, block: true });
pageEls.confirmDim.onclick = () => closeDialog({ ok: false });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && dialogOpen()) closeDialog({ ok: false }); });

// The dialog for a run's 428 answer: its `confirm:` words, preview and command.
function confirmOpts(item, res) {
  const c = res.confirm || {};
  return {
    title: c.title || `Run “${item.label}”?`,
    message: c.message || '',
    preview: res.preview || null,
    command: res.command,
    then: item.then !== 'none' ? `then: hot ${item.then} when it succeeds` : '',
    button: c.button || 'Run',
    danger: !!c.danger,
  };
}

function confirmRun(opts) {
  return dialogOpen() ? Promise.resolve({ ok: false, busy: true }) : openDialog(opts);
}

// A run's dialog with the words of the view that asked for it: the view's
// lead (under its "from" line), emu.yaml's follow with the command. Every word
// of emu.yaml's moves under [action] whole — the view's can't stand in for it.
function withAsk(opts, ask) {
  return {
    ...opts,
    title: ask.title, message: ask.message || '', detail: ask.detail || '',
    action: { title: opts.title, message: opts.message || '', detail: opts.detail || '' },
    danger: !!(opts.danger || ask.danger),
  };
}

// Merging a view's confirm with the run it asks for next. emu.confirm can't
// know that run — the view sends it only once it has the answer — so on OK the
// dialog stays up, inert, for FRAME_MERGE_MS. If the same view runs a
// `confirm:` action in that time, the dialog goes on to that run's command in
// place (takeHold): one window, its words still on top. Anything else, or
// nothing, lets it go, and a later run asks in a dialog of its own.
const FRAME_MERGE_MS = 1000;

function holdDialog(keep) {
  dialogHold = { ...keep, timer: setTimeout(endHold, FRAME_MERGE_MS) };
  dlg.run.disabled = dlg.cancel.disabled = true;
  dlg.block.hidden = true;
  dlg.wait.hidden = false;
}

// [key]'s run needs a confirmation: the held dialog waits for its 428 (the
// next openDialog takes it over). Returns the view's words, or null.
function takeHold(key) {
  if (dialogHold?.key !== key || !dialogHold.timer) return null;
  clearTimeout(dialogHold.timer);
  dialogHold.timer = null;
  return dialogHold.ask;
}

// Let a held dialog go — only one still waiting for a run ([claimed]: or one
// whose run has been taken, once that run is done without a dialog).
function endHold(claimed = false) {
  if (!dialogHold || (!dialogHold.timer && !claimed)) return;
  clearTimeout(dialogHold.timer);
  dialogHold = null;
  if (!dialogResolve) hideDialog();
}

// Limits on what frames ask for. A frame whose dialogs keep getting cancelled
// is offered a way out: block it, and until the dashboard reloads its
// confirm/prompt/choose answer no (false/null) at once — runs that need a
// confirmation included.
const frameGuard = { blocked: new Set(), cancels: {} }; // 'page.block' → times of recent cancels
const FRAME_SPAM_MS = 20000;
const FRAME_SPAM_CANCELS = 2;

// A dialog for [block]'s frame, headed with who asks; [verb]: 'asks', 'wants to run this'.
async function frameDialog(page, block, { verb, ...opts }) {
  const key = blockKey(page, block);
  if (frameGuard.blocked.has(key)) return { ok: false, blocked: true };
  const held = dialogHold?.key === key && !dialogHold.timer; // its run, taken over by takeHold
  if (dialogOpen() && !held) return { ok: false, busy: true };
  if (currentPage() !== page || document.visibilityState !== 'visible') return { ok: false, hidden: true };
  const now = Date.now();
  const recent = (frameGuard.cancels[key] || []).filter(t => now - t < FRAME_SPAM_MS);
  const answer = await openDialog({
    ...opts,
    from: `“${block.title}” (emu.yaml · ${block.src}) ${verb}:`,
    offerBlock: recent.length >= FRAME_SPAM_CANCELS,
  });
  frameGuard.cancels[key] = answer.ok ? [] : [...recent, now];
  if (answer.block) {
    frameGuard.blocked.add(key);
    toast(`${block.title}: its requests are blocked until the dashboard reloads`);
  }
  return answer;
}

function refusalText(answer) {
  return answer.busy ? 'another dialog is open'
    : answer.blocked || answer.block ? 'requests from this view are blocked'
      : answer.hidden ? 'this view is not on screen'
        : 'cancelled';
}

// ---- asking while a command runs ----------------------------------------------
// An `interactive:` action's command may ask (`::emu-ask` lines): the server
// sends the question to the tab that started the run — this one — and the
// answer goes back by its ask id. It is a dialog like the others: one at a
// time (a question waits for an open dialog to close), text only, headed with
// the page and action that ask, Cancel focused when it is danger. Cancel
// answers false (confirm) or null; a question the server gave up on
// (timed out, the command ended) closes unanswered.
const runAsks = { queue: [], current: null };

function onRunAsk(msg) {
  if (msg.event === 'ask') {
    runAsks.queue.push(msg);
    nextRunAsk();
  } else {
    runAsks.queue = runAsks.queue.filter(m => m.askId !== msg.askId);
    if (runAsks.current === msg.askId) closeDialog({ ok: false, gone: true });
  }
}

// The dialog for a run's question: [msg] as the server sent it.
function runAskOpts(msg) {
  const q = msg.ask || {};
  const opts = {
    from: `“${clip(msg.from?.action ?? msg.item, 100)}” on page “${clip(msg.from?.page ?? msg.page, 100)}” (emu.yaml) asks while it runs:`,
    title: clip(q.title, 200) || 'Confirm?', message: clip(q.message, 2000), detail: clip(q.detail, 20000),
    danger: q.danger === true, button: clip(q.button, 40) || 'OK',
  };
  if (q.kind === 'prompt') {
    opts.fields = (Array.isArray(q.fields) ? q.fields : []).slice(0, 12).filter(f => f && typeof f.name === 'string')
      .map(f => ({ name: f.name, label: clip(f.label ?? f.name, 100), default: clip(f.default, 2000) }));
  } else if (q.kind === 'choose') {
    opts.choices = { options: frameOptions(q.options), multiple: q.multiple === true };
  }
  return opts;
}

// The dialog's answer as the command gets it.
function runAskValue(kind, opts, answer) {
  if (kind === 'confirm') return answer.ok === true;
  if (!answer.ok) return null;
  if (kind === 'prompt') return answer.values;
  const picked = answer.picked.map(i => opts.choices.options[i].value);
  return opts.choices.multiple ? picked : picked[0] ?? null;
}

async function nextRunAsk() {
  if (runAsks.current || dialogOpen() || !runAsks.queue.length) return;
  const msg = runAsks.queue.shift();
  runAsks.current = msg.askId;
  const opts = runAskOpts(msg);
  const answer = await openDialog(opts);
  runAsks.current = null;
  if (!answer.gone) {
    try {
      await api(`/api/pages/${encodeURIComponent(msg.page)}/asks/${encodeURIComponent(msg.askId)}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ value: runAskValue(msg.ask?.kind, opts, answer) }),
      });
    } catch (e) {
      toast(`answer to “${opts.title}” failed: ${e}`);
    }
  }
  nextRunAsk();
}

function stripAnsi(s) { return (s || '').replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, ''); }

loadPages();
