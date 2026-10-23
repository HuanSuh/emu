'use strict';

// Mocks tab (emu.yaml `mocks:`, see lib/src/mock.dart). Loaded after app.js
// and shares its globals (api, toast, escapeHtml). Left: scenarios and their
// rules; right: the selected rule's editor over the live traffic. Scenario
// files (`mocks/<name>.json`) are edited here; scenarios written in emu.yaml
// are shown read-only. "Mock this" turns a request the app made into a rule.

const mockEls = {
  tab: document.getElementById('tab-mocks'),
  badge: document.getElementById('mock-badge'),
  tools: document.getElementById('mock-tools'),
  active: document.getElementById('mock-active'),
  note: document.getElementById('mock-note'),
  newName: document.getElementById('mock-new-name'),
  pane: document.getElementById('mocks'),
  list: document.getElementById('mock-list'),
  edit: document.getElementById('mock-edit'),
  traffic: document.getElementById('mock-traffic'),
};
const mockState = {
  config: null,     // GET /api/mock
  drafts: {},       // scenario → rules being edited (unsaved)
  sel: null,        // {scenario, index}
  hits: [],         // newest last
  hit: null,        // the selected request, with bodies
};
const METHODS = ['', 'GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'];
const CLI = 'CLI overrides';

async function loadMocks() {
  let j;
  try {
    const r = await api('/api/mock');
    j = await r.json();
  } catch (_) { return; }
  const on = j.ok === true;
  mockEls.tab.hidden = !on;
  if (!on) {
    if (debugTab === 'mocks') showTab('logs');
    return;
  }
  // `emu mock set` overrides show as a read-only scenario on top.
  const scenarios = {};
  if ((j.overrides || []).length) scenarios[CLI] = j.overrides;
  j.scenarios = { ...scenarios, ...j.scenarios };
  j.sources = { ...j.sources, [CLI]: 'cli' };
  mockState.config = j;
  // Keep unsaved edits of scenarios that still exist; drop the rest.
  for (const name of Object.keys(mockState.drafts)) if (!(name in j.scenarios)) delete mockState.drafts[name];
  if (mockState.sel && !(mockState.sel.scenario in j.scenarios)) mockState.sel = null;
  renderMockTools();
  renderMockList();
  renderMockEditor();
  loadMockHits();
}

const mockEditable = (name) => (mockState.config.sources[name] || '').endsWith('.json');
const mockRules = (name) => mockState.drafts[name] || mockState.config.scenarios[name] || [];
const mockDirty = (name) => !!mockState.drafts[name];

function renderMockTools() {
  const c = mockState.config;
  mockEls.active.innerHTML = '<option value="">off — real server</option>' +
    Object.keys(c.scenarios).filter(n => n !== CLI).map(n => `<option value="${escapeHtml(n)}"${n === c.active ? ' selected' : ''}>${escapeHtml(n)}</option>`).join('');
  mockEls.badge.textContent = c.active ? '●' : '';
  const where = [
    c.hosts.length ? `hook: ${c.hosts.join(', ')}` : '',
    c.upstream ? `${c.define || 'base URL'} → ${c.upstream}` : '',
  ].filter(Boolean).join(' · ');
  mockEls.note.textContent = where;
  mockEls.note.title = (c.problems || []).join('\n');
  mockEls.note.classList.toggle('warnish', (c.problems || []).length > 0);
}

function ruleLabel(rule) {
  const m = rule.match || {}, r = rule.respond || {};
  return `<span class="m">${escapeHtml(m.method || '*')}</span> <span class="p">${escapeHtml(m.path || m.url || '?')}</span>` +
    ` <span class="st s${String(r.status || 200)[0]}">${r.status || 200}</span>`;
}

function renderMockList() {
  const c = mockState.config;
  const names = Object.keys(c.scenarios);
  mockEls.list.innerHTML = names.length ? names.map(name => {
    const editable = mockEditable(name);
    const rules = mockRules(name);
    const cli = name === CLI;
    return `<div class="mscen${name === c.active || cli ? ' on' : ''}" data-scenario="${escapeHtml(name)}">` +
      `<span class="name">${escapeHtml(name)}${mockDirty(name) ? ' •' : ''}</span>` +
      (cli ? `<span class="mx" id="mock-reset" title="emu mock reset">clear</span>` : '') +
      `<span class="src" title="${escapeHtml(c.sources[name] || 'emu.yaml')}">${cli ? 'cli' : editable ? 'file' : 'yaml'}</span></div>` +
      rules.map((rule, i) => {
        const sel = mockState.sel && mockState.sel.scenario === name && mockState.sel.index === i;
        return `<div class="mrule${sel ? ' active' : ''}" data-scenario="${escapeHtml(name)}" data-index="${i}">${ruleLabel(rule)}` +
          (cli ? `<span class="mx" data-unset="${i}" title="emu mock unset">×</span>` : '') + `</div>`;
      }).join('') +
      (editable ? `<div class="madd" data-scenario="${escapeHtml(name)}">+ rule</div>` : '');
  }).join('') : `<div class="diff-note">no scenarios — name one above and press “+ scenario”, or use “mock this” on a request</div>`;
  mockEls.list.querySelectorAll('.mrule').forEach(el => {
    el.onclick = () => selectRule(el.dataset.scenario, Number(el.dataset.index));
  });
  mockEls.list.querySelectorAll('[data-unset]').forEach(el => {
    el.onclick = (e) => {
      e.stopPropagation();
      const m = (c.scenarios[CLI][Number(el.dataset.unset)] || {}).match || {};
      unsetOverride(`${m.method || '*'} ${m.url || m.path}`);
    };
  });
  const reset = document.getElementById('mock-reset');
  if (reset) reset.onclick = () => unsetOverride(null);
  mockEls.list.querySelectorAll('.madd').forEach(el => {
    el.onclick = () => addRule(el.dataset.scenario, { match: { method: 'GET', path: '/' }, respond: { status: 200, body: {} } });
  });
}

function selectRule(scenario, index) {
  mockState.sel = { scenario, index };
  renderMockList();
  renderMockEditor();
}

function draftOf(scenario) {
  if (!mockState.drafts[scenario]) mockState.drafts[scenario] = JSON.parse(JSON.stringify(mockRules(scenario)));
  return mockState.drafts[scenario];
}

function addRule(scenario, rule) {
  const rules = draftOf(scenario);
  rules.push(rule);
  selectRule(scenario, rules.length - 1);
}

function bodyText(body) {
  if (body === undefined || body === null) return '';
  return typeof body === 'string' ? body : JSON.stringify(body, null, 2);
}

function renderMockEditor() {
  const sel = mockState.sel;
  if (!sel) {
    mockEls.edit.innerHTML = '<div class="diff-note">pick a rule on the left — or a request below to mock its response</div>';
    return;
  }
  const rule = mockRules(sel.scenario)[sel.index];
  if (!rule) { mockState.sel = null; renderMockEditor(); return; }
  const editable = mockEditable(sel.scenario);
  const m = rule.match || {}, r = rule.respond || {};
  const dis = editable ? '' : ' disabled';
  const kind = m.url ? 'url' : 'path';
  mockEls.edit.innerHTML =
    `<div class="blk-head"><span class="name">${escapeHtml(sel.scenario)}</span>` +
    `<span class="muted">rule ${sel.index + 1} · ${escapeHtml(mockState.config.sources[sel.scenario] || 'emu.yaml')}</span>` +
    `<span class="grow"></span>` +
    (editable
      ? `<button id="mr-dup">duplicate</button><button id="mr-del">delete rule</button>` +
        `<button id="mr-save" class="primary"${mockDirty(sel.scenario) ? '' : ' disabled'}>save ${escapeHtml(sel.scenario)}</button>`
      : '') + '</div>' +
    (editable ? '' : `<div class="diff-note">${sel.scenario === CLI
      ? 'set with <code>emu mock set</code> — checked before any scenario, kept in memory until <code>emu mock reset</code>. To keep it, type a name above and press “copy”.'
      : 'defined in emu.yaml — edit it there, or copy it to a file: type a name above and press “copy”.'}</div>`) +
    `<div class="form-grid mform">` +
    `<label>method</label><select id="mr-method"${dis}>${METHODS.map(x => `<option value="${x}"${(m.method || '') === x ? ' selected' : ''}>${x || 'any'}</option>`).join('')}</select>` +
    `<label><select id="mr-kind"${dis}><option value="path"${kind === 'path' ? ' selected' : ''}>path</option><option value="url"${kind === 'url' ? ' selected' : ''}>url</option></select></label>` +
    `<input id="mr-pattern" value="${escapeHtml(m.url || m.path || '')}" placeholder="/v1/items*   (* = anything; add ?… to match the query)" spellcheck="false"${dis} />` +
    `<label>status</label><input id="mr-status" type="number" min="100" max="599" value="${r.status || 200}"${dis} />` +
    `<label>delay ms</label><input id="mr-delay" type="number" min="0" value="${r.delay || 0}"${dis} />` +
    `<label>headers</label><textarea id="mr-headers" rows="2" placeholder="x-name: value" spellcheck="false"${dis}>${escapeHtml(Object.entries(r.headers || {}).map(([k, v]) => `${k}: ${v}`).join('\n'))}</textarea>` +
    `<label>body</label>` +
    (r.file
      ? `<div class="muted">from file <code>${escapeHtml(r.file)}</code> — edit that file</div>`
      : `<div class="mbody"><textarea id="mr-body" rows="12" spellcheck="false"${dis}>${escapeHtml(bodyText(r.body))}</textarea>` +
        `<div class="mbody-note muted" id="mr-body-note"></div></div>`) +
    `</div>`;
  if (!editable) return;
  const update = () => {
    const rules = draftOf(sel.scenario);
    const cur = rules[sel.index];
    const method = document.getElementById('mr-method').value;
    const pattern = document.getElementById('mr-pattern').value.trim();
    const match = {};
    if (method) match.method = method;
    match[document.getElementById('mr-kind').value] = pattern;
    const respond = { status: Number(document.getElementById('mr-status').value) || 200 };
    const headers = {};
    for (const line of document.getElementById('mr-headers').value.split('\n')) {
      const i = line.indexOf(':');
      if (i > 0) headers[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
    if (Object.keys(headers).length) respond.headers = headers;
    const delay = Number(document.getElementById('mr-delay').value) || 0;
    if (delay > 0) respond.delay = delay;
    const bodyEl = document.getElementById('mr-body');
    if (bodyEl) {
      const text = bodyEl.value;
      const note = document.getElementById('mr-body-note');
      if (text.trim() === '') {
        note.textContent = 'empty body';
      } else {
        try {
          respond.body = JSON.parse(text);
          note.textContent = 'JSON ✓';
        } catch (_) {
          respond.body = text;
          note.textContent = 'not JSON — sent as text';
        }
      }
    } else if (cur.respond && cur.respond.file) {
      respond.file = cur.respond.file;
    }
    rules[sel.index] = { match, respond };
    document.getElementById('mr-save').disabled = false;
    const row = mockEls.list.querySelector(`.mrule[data-scenario="${CSS.escape(sel.scenario)}"][data-index="${sel.index}"]`);
    if (row) row.innerHTML = ruleLabel(rules[sel.index]);
    const head = mockEls.list.querySelector(`.mscen[data-scenario="${CSS.escape(sel.scenario)}"] .name`);
    if (head) head.textContent = `${sel.scenario} •`;
  };
  mockEls.edit.querySelectorAll('input, select, textarea').forEach(el => { el.oninput = update; el.onchange = update; });
  document.getElementById('mr-save').onclick = () => saveScenario(sel.scenario);
  document.getElementById('mr-del').onclick = () => {
    draftOf(sel.scenario).splice(sel.index, 1);
    mockState.sel = null;
    renderMockList();
    renderMockEditor();
    saveScenario(sel.scenario);
  };
  document.getElementById('mr-dup').onclick = () => addRule(sel.scenario, JSON.parse(JSON.stringify(mockRules(sel.scenario)[sel.index])));
}

async function unsetOverride(key) {
  const q = key ? `?${new URLSearchParams({ key })}` : '';
  const j = await (await api(`/api/mock/overrides${q}`, { method: 'DELETE' })).json();
  if (!j.ok) toast(j.error);
  if (mockState.sel && mockState.sel.scenario === CLI) mockState.sel = null;
  loadMocks();
}

async function saveScenario(name, rules = mockRules(name)) {
  const r = await api(`/api/mock/scenarios/${encodeURIComponent(name)}`, {
    method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ rules }),
  });
  const j = await r.json();
  if (!j.ok) { toast(`not saved: ${j.error}`); return false; }
  delete mockState.drafts[name];
  toast(`saved ${mockState.config.dir}/${name}.json`);
  await loadMocks();
  return true;
}

// ---- traffic ------------------------------------------------------------------

async function loadMockHits() {
  try {
    const j = await (await api('/api/mock/log?n=100')).json();
    if (j.ok) mockState.hits = j.hits;
  } catch (_) {}
  renderMockTraffic();
}

function onMockHit(hit) {
  mockState.hits.push(hit);
  if (mockState.hits.length > 200) mockState.hits.shift();
  if (debugTab === 'mocks') renderMockTraffic();
}

function hitPath(url) {
  try { const u = new URL(url); return u.pathname + u.search; } catch (_) { return url; }
}

function renderMockTraffic() {
  const hits = mockState.hits.slice().reverse();
  const h = mockState.hit;
  mockEls.traffic.innerHTML =
    `<div class="blk-head"><span class="name">traffic</span><span class="muted">${hits.length} request(s) through emu</span></div>` +
    `<div class="mtraffic">` +
    `<div class="mhits">${hits.length ? hits.map(x =>
      `<div class="mhit${h && h.id === x.id ? ' active' : ''}" data-id="${x.id}">` +
      `<span class="t muted">${escapeHtml(new Date(x.at).toLocaleTimeString())}</span>` +
      `<span class="m">${escapeHtml(x.method)}</span><span class="p" title="${escapeHtml(x.url)}">${escapeHtml(hitPath(x.url))}</span>` +
      `<span class="st s${String(x.status)[0]}">${x.error ? '✗' : x.status}</span>` +
      (x.mocked ? `<span class="tag">${escapeHtml(x.mocked)}</span>` : '') + `</div>`).join('')
      : '<div class="diff-note">no requests yet — use the app</div>'}</div>` +
    `<div class="mhit-detail">${h ? hitDetail(h) : '<div class="diff-note">pick a request to see its bodies</div>'}</div>` +
    `</div>`;
  mockEls.traffic.querySelectorAll('.mhit').forEach(el => { el.onclick = () => openHit(Number(el.dataset.id)); });
  const btn = document.getElementById('mh-mock');
  if (btn) btn.onclick = () => mockThis(h);
}

function prettyBody(text) {
  if (!text) return '<span class="muted">(empty)</span>';
  try { return escapeHtml(JSON.stringify(JSON.parse(text), null, 2)); } catch (_) { return escapeHtml(text); }
}

function hitDetail(h) {
  const target = mockTarget();
  return `<div class="mh-head"><span class="m">${escapeHtml(h.method)}</span> <span class="p">${escapeHtml(h.url)}</span>` +
    ` <span class="st s${String(h.status)[0]}">${h.status}</span> <span class="muted">${h.ms}ms${h.mocked ? ` · mock: ${escapeHtml(h.mocked)}` : ''}</span>` +
    (h.error ? `<div class="minus">${escapeHtml(h.error)}</div>` : '') +
    `<div class="mh-actions"><button id="mh-mock"${target ? '' : ' disabled'} title="${target ? '' : 'pick or create a file scenario first'}">mock this response → ${escapeHtml(target || '…')}</button></div></div>` +
    (h.requestBody ? `<div class="mh-sec">request body</div><pre>${prettyBody(h.requestBody)}</pre>` : '') +
    `<div class="mh-sec">response${h.responseType ? ` · ${escapeHtml(h.responseType)}` : ''}</div><pre>${prettyBody(h.responseBody)}</pre>`;
}

async function openHit(id) {
  try {
    const j = await (await api(`/api/mock/hits/${id}`)).json();
    if (j.ok) mockState.hit = j.hit;
    else toast(j.error);
  } catch (_) {}
  renderMockTraffic();
}

// Where "mock this" adds a rule: the selected rule's scenario if it is a
// file, else the name typed in the toolbar.
function mockTarget() {
  const sel = mockState.sel;
  if (sel && mockEditable(sel.scenario)) return sel.scenario;
  const typed = mockEls.newName.value.trim();
  return /^[A-Za-z0-9_-]+$/.test(typed) ? typed : null;
}

function mockThis(h) {
  const name = mockTarget();
  if (!name) return;
  let body = h.responseBody || '';
  try { body = JSON.parse(body); } catch (_) {}
  const path = (() => { try { return new URL(h.url).pathname; } catch (_) { return '/'; } })();
  const rule = { match: { method: h.method, path }, respond: { status: h.status || 200, body } };
  if (!(name in mockState.config.scenarios)) {
    mockState.config.scenarios[name] = [];
    mockState.config.sources[name] = `${mockState.config.dir}/${name}.json`;
  }
  addRule(name, rule);
  toast(`added to ${name} — edit, then save`);
}

// ---- toolbar ------------------------------------------------------------------

mockEls.active.onchange = async () => {
  const scenario = mockEls.active.value || null;
  const j = await (await api('/api/mock', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ scenario }),
  })).json();
  if (!j.ok) toast(j.error);
  toast(scenario ? `mock: ${scenario}` : 'mock off — real server');
  loadMocks();
};
document.getElementById('mock-new').onclick = async () => {
  const name = mockEls.newName.value.trim();
  if (!/^[A-Za-z0-9_-]+$/.test(name)) { toast('name: letters, digits, - and _'); return; }
  if (name in mockState.config.scenarios) { toast(`"${name}" exists`); return; }
  // A copy of the selected emu.yaml scenario, or an empty one.
  const sel = mockState.sel;
  const rules = sel && !mockEditable(sel.scenario) ? mockRules(sel.scenario) : [];
  if (await saveScenario(name, rules)) {
    mockEls.newName.value = '';
    if (rules.length) selectRule(name, 0);
  }
};
document.getElementById('mock-del').onclick = async () => {
  const sel = mockState.sel;
  if (!sel || !mockEditable(sel.scenario)) { toast('pick a rule of a file scenario first'); return; }
  const j = await (await api(`/api/mock/scenarios/${encodeURIComponent(sel.scenario)}`, { method: 'DELETE' })).json();
  toast(j.ok ? `deleted ${sel.scenario}` : j.error);
  delete mockState.drafts[sel.scenario];
  mockState.sel = null;
  loadMocks();
};
document.getElementById('mock-refresh').onclick = loadMocks;
mockEls.newName.addEventListener('input', () => { if (mockState.hit) renderMockTraffic(); });

loadMocks();
