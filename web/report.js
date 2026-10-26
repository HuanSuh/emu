'use strict';

// Report — a bug, feature request or question about emu, sent as a GitHub
// issue (lib/src/report_api.dart). Self-contained: the dashboard and the hub
// both load it and mark their button with `data-emu-report`.
//
// What is sent is the preview: Send only names the preview's digest, and the
// server sends the issue it built for that preview — nothing is rebuilt. Any
// edit drops the preview, so Send is only ever one click after reading it.

(() => {
  const TOKEN = document.querySelector('meta[name="emu-token"]')?.content || '';
  const GITHUB = 'https://github.com/';

  async function call(path, opts = {}) {
    let r;
    try {
      r = await fetch(path, { ...opts, headers: { ...opts.headers, 'X-Emu-Token': TOKEN, 'Content-Type': 'application/json' } });
    } catch (_) {
      return { ok: false, error: 'the emu server is not answering' };
    }
    if (r.status === 401) return { ok: false, error: 'session token rejected — reload the page' };
    return r.json().catch(() => ({ ok: false, error: `HTTP ${r.status}` }));
  }
  const withToken = (url) => `${url}${url.includes('?') ? '&' : '?'}token=${encodeURIComponent(TOKEN)}`;

  // Built once; user text only ever goes in through .value / .textContent.
  const TEMPLATE = `
    <div class="rp-dim"></div>
    <div class="rp-modal" role="dialog" aria-modal="true" aria-labelledby="rp-title">
      <div class="rp-head">
        <b id="rp-title">Report to emu</b>
        <span class="rp-tabs">
          <button data-tab="new" class="on">New</button>
          <button data-tab="mine">My reports</button>
        </span>
        <span class="rp-grow"></span>
        <button class="rp-x" aria-label="Close">×</button>
      </div>
      <div class="rp-body" data-pane="new">
        <div class="rp-note">A public issue on <b>github.com/HuanSuh/emu</b> — <span class="rp-via">…</span></div>
        <div class="rp-kinds" role="radiogroup">
          <label><input type="radio" name="rp-kind" value="bug" checked> bug</label>
          <label><input type="radio" name="rp-kind" value="feature"> feature request</label>
          <label><input type="radio" name="rp-kind" value="question"> question</label>
        </div>
        <input class="rp-field rp-title" type="text" maxlength="200" placeholder="Title — one line" autocomplete="off">
        <textarea class="rp-field rp-text" rows="6" placeholder="What you did, what happened, what you expected"></textarea>
        <div class="rp-attach">
          <span class="rp-muted">attach:</span>
          <label data-a="logs"><input type="checkbox" data-a="logs"> logs
            <select class="rp-lines" title="Last N lines"><option>50</option><option selected>200</option><option>500</option></select></label>
          <label data-a="errors"><input type="checkbox" data-a="errors"> exceptions</label>
          <label data-a="shot"><input type="checkbox" data-a="shot"> screen</label>
          <span class="rp-muted">— nothing unless ticked; paths, project/app names and tokens are masked</span>
        </div>
        <div class="rp-preview" hidden>
          <div class="rp-meta"></div>
          <pre class="rp-pre"></pre>
          <div class="rp-images"></div>
          <ul class="rp-notes"></ul>
        </div>
        <div class="rp-result" hidden></div>
      </div>
      <div class="rp-body" data-pane="mine" hidden><div class="rp-mine"></div></div>
      <div class="rp-foot">
        <span class="rp-msg"></span>
        <span class="rp-grow"></span>
        <button class="rp-edit" hidden>Edit</button>
        <button class="rp-preview-btn">Preview</button>
        <button class="rp-send rp-primary" hidden>Send</button>
      </div>
    </div>`;

  let root = null;
  let preview = null; // the server's preview: {digest, title, body, …}
  let busy = false;
  let edits = 0; // bumped on every edit — a preview built from older fields is thrown away
  const $ = (sel) => root.querySelector(sel);

  function build() {
    root = document.createElement('div');
    root.className = 'rp-root';
    root.hidden = true;
    root.innerHTML = TEMPLATE;
    document.body.appendChild(root);
    // The dashboard's r/R shortcuts listen on document — keep typing here out of them.
    root.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Escape') close();
    });
    $('.rp-dim').onclick = close;
    $('.rp-x').onclick = close;
    for (const b of root.querySelectorAll('.rp-tabs button')) b.onclick = () => tab(b.dataset.tab);
    for (const input of root.querySelectorAll('.rp-body[data-pane="new"] input, .rp-body[data-pane="new"] textarea, .rp-body[data-pane="new"] select')) {
      input.addEventListener('input', dropPreview);
      input.addEventListener('change', dropPreview);
    }
    $('.rp-preview-btn').onclick = doPreview;
    $('.rp-edit').onclick = () => { dropPreview(); $('.rp-title').focus(); };
    $('.rp-send').onclick = doSend;
  }

  async function open() {
    if (!root) build();
    root.hidden = false;
    tab('new');
    $('.rp-title').focus();
    const info = await call('/api/report');
    if (!info.ok) return msg(info.error, true);
    $('.rp-via').textContent = info.via === 'gh'
      ? 'created with your gh login'
      : 'gh is not signed in here, so it opens a prefilled GitHub form to submit';
    for (const a of ['logs', 'errors', 'shot']) {
      $(`label[data-a="${a}"]`).hidden = !info.attach?.[a];
    }
    $('.rp-attach').hidden = !Object.values(info.attach || {}).some(Boolean); // the hub: nothing to attach
  }

  function close() {
    if (root) root.hidden = true;
  }

  function tab(name) {
    for (const b of root.querySelectorAll('.rp-tabs button')) b.classList.toggle('on', b.dataset.tab === name);
    for (const p of root.querySelectorAll('.rp-body')) p.hidden = p.dataset.pane !== name;
    const isNew = name === 'new';
    $('.rp-foot').hidden = !isNew;
    if (!isNew) loadMine();
  }

  function msg(text, err = false) {
    const m = $('.rp-msg');
    m.textContent = text || '';
    m.classList.toggle('err', err);
  }

  function setBusy(on, text = '') {
    busy = on;
    for (const b of root.querySelectorAll('.rp-foot button')) b.disabled = on;
    msg(text);
  }

  function dropPreview() {
    edits++;
    preview = null;
    $('.rp-preview').hidden = true;
    $('.rp-send').hidden = true;
    $('.rp-edit').hidden = true;
    $('.rp-preview-btn').hidden = false;
    $('.rp-result').hidden = true;
    msg('');
  }

  function draft() {
    const kind = root.querySelector('input[name="rp-kind"]:checked')?.value || 'bug';
    const ticked = (a) => { const c = $(`input[data-a="${a}"]`); return c.checked && !c.closest('label').hidden; };
    return {
      kind,
      title: $('.rp-title').value,
      body: $('.rp-text').value,
      attach: {
        logs: ticked('logs') ? Number($('.rp-lines').value) : 0,
        errors: ticked('errors'),
        shot: ticked('shot'),
      },
    };
  }

  async function doPreview() {
    const d = draft();
    if (!d.title.trim()) { msg('a title is required', true); $('.rp-title').focus(); return; }
    const asOf = edits;
    setBusy(true, d.attach.shot ? 'capturing the screen…' : 'building the preview…');
    const j = await call('/api/report/preview', { method: 'POST', body: JSON.stringify(d) });
    setBusy(false);
    if (asOf !== edits) return msg('changed while the preview was being built — preview again');
    if (!j.ok) return msg(j.error, true);
    preview = j;
    $('.rp-meta').textContent = `title: ${j.title}\nlabel: ${j.labeled ? j.label : '(none)'} · ${j.via === 'gh' ? 'gh issue create' : 'opens in the browser'}`;
    $('.rp-pre').textContent = j.body;
    const imgs = $('.rp-images');
    imgs.replaceChildren();
    j.images.forEach((_, i) => {
      const img = document.createElement('img');
      img.src = withToken(`/api/report/image/${j.digest}/${i}`);
      img.alt = 'screenshot to paste in';
      imgs.appendChild(img);
    });
    const notes = $('.rp-notes');
    notes.replaceChildren(...j.notes.map((n) => Object.assign(document.createElement('li'), { textContent: n })));
    $('.rp-preview').hidden = false;
    $('.rp-preview-btn').hidden = true;
    $('.rp-edit').hidden = false;
    $('.rp-send').hidden = false;
    $('.rp-send').textContent = j.via === 'gh' ? 'Send' : 'Open GitHub form';
    msg('this is exactly what will be sent');
    $('.rp-send').focus();
  }

  async function doSend() {
    if (!preview) return;
    setBusy(true, 'sending…');
    const j = await call('/api/report/send', { method: 'POST', body: JSON.stringify({ digest: preview.digest }) });
    setBusy(false);
    if (!j.ok) return msg(j.error, true);
    const out = $('.rp-result');
    out.replaceChildren();
    const line = document.createElement('div');
    if (j.via === 'gh') {
      line.append(j.duplicate ? 'Already sent a moment ago — ' : '✓ Sent — ', link(j.url, `#${j.number}`));
    } else {
      line.append('Submit it on GitHub: ', link(j.url, 'open the prefilled form ↗'));
      if (j.trimmed) {
        out.append(line, copyButton('Copy the full text', () => navigator.clipboard.writeText(j.body)),
          note('the attachments did not fit in a link — paste the full text over the form\'s'));
      }
    }
    if (!out.contains(line)) out.prepend(line);
    if (j.images?.length) {
      out.append(note(j.via === 'gh'
        ? 'Screenshots can\'t be uploaded for you: copy one, then paste it (⌘V) into a comment on the issue — or drag the image there.'
        : 'Once submitted, paste the screenshot (⌘V) into a comment — or drag the image there.'));
      for (const u of j.images) {
        const img = document.createElement('img');
        img.src = withToken(u);
        out.append(img, copyButton('Copy image', async () => {
          const blob = await (await fetch(withToken(u))).blob();
          await navigator.clipboard.write([new ClipboardItem({ [blob.type || 'image/png']: blob })]);
        }));
      }
      if (j.via === 'gh') out.append(link(j.url, 'open the issue ↗'));
    }
    out.hidden = false;
    $('.rp-preview').hidden = true;
    $('.rp-send').hidden = true;
    $('.rp-edit').hidden = true;
    $('.rp-preview-btn').hidden = false;
    preview = null;
    if (j.via === 'gh') { $('.rp-title').value = ''; $('.rp-text').value = ''; }
    msg('');
  }

  async function loadMine() {
    const box = $('.rp-mine');
    box.textContent = 'loading…';
    const j = await call('/api/report/mine');
    box.replaceChildren();
    if (!j.ok) { box.textContent = j.error; return; }
    if (!j.issues) {
      box.append('gh is not signed in here — ', link(j.url, 'see your issues on GitHub ↗'));
      return;
    }
    if (!j.issues.length) { box.textContent = 'No issues sent with emu report yet.'; return; }
    for (const i of j.issues) {
      const row = document.createElement('div');
      row.className = 'rp-issue';
      const status = Object.assign(document.createElement('span'), { className: `rp-status s-${i.status.replace(' ', '-')}`, textContent: i.status });
      const extra = [
        i.comments ? `${i.comments} comment${i.comments === 1 ? '' : 's'}` : '',
        i.prs?.length ? `PR ${i.prs.map((p) => `#${p.number}`).join(', ')}` : '',
      ].filter(Boolean).join(' · ');
      row.append(status, link(i.url, `#${i.number}`), ' ', Object.assign(document.createElement('span'), { textContent: i.title }));
      if (extra) row.append(Object.assign(document.createElement('span'), { className: 'rp-muted', textContent: `  ${extra}` }));
      box.append(row);
    }
  }

  // Only links into GitHub — the server's answer is trusted, but cheaply checked.
  function link(url, text) {
    const a = document.createElement('a');
    a.textContent = text;
    if (typeof url === 'string' && url.startsWith(GITHUB)) {
      a.href = url;
      a.target = '_blank';
      a.rel = 'noopener noreferrer';
    }
    return a;
  }

  function copyButton(label, copy) {
    const b = document.createElement('button');
    b.textContent = label;
    b.onclick = async () => {
      try { await copy(); b.textContent = 'Copied ✓'; } catch (_) { b.textContent = 'Copy failed — drag it instead'; }
    };
    return b;
  }

  function note(text) {
    return Object.assign(document.createElement('div'), { className: 'rp-muted', textContent: text });
  }

  document.addEventListener('click', (e) => {
    if (e.target.closest?.('[data-emu-report]')) open();
  });
})();
