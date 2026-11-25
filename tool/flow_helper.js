// win-30: Google Flow helper, pasted into a signed-in Flow tab by Claude.
// - flowQueue(items): stores [{id, prompt}] and inserts the next prompt into the
//   editor (submission itself needs a real Enter key press from the browser tool;
//   Flow ignores synthetic clicks).
// - flowCollect(): finds every finished image of the queued prompts (matched by
//   prompt text, not by looking at pictures) and sends it straight to MotionAI
//   (POST http://127.0.0.1:7820/api/upload) — no browser download, no save prompt.
//   Several images per prompt are kept as id_1, id_2, …
// Usage in the tab:
//   flowSetup({token: '<MotionAI token>', folder: 'P360'});
//   flowQueue([{id: 's06_bg', prompt: '…'}, …]);   // then: flowNext() + Enter, repeat
//   await flowCollect();                            // → {sent: [...], missing: [...]}
(() => {
  const S = (window.__flow = window.__flow || { items: [], next: 0, sent: {}, token: '', folder: 'inbox', port: 7820 });
  const norm = (s) => (s || '').replace(/\s+/g, ' ').trim();

  window.flowSetup = ({ token, folder = 'inbox', port = 7820 } = {}) => {
    S.token = token || S.token;
    S.folder = folder;
    S.port = port;
    return { ok: !!S.token, folder: S.folder };
  };

  window.flowQueue = (items) => {
    S.items = items.map((x) => ({ id: x.id, prompt: x.prompt }));
    S.next = 0;
    S.sent = {};
    return S.items.length;
  };

  /** Puts the next queued prompt into the Flow editor; returns its id (or null when done). */
  window.flowNext = () => {
    const it = S.items[S.next];
    if (!it) return null;
    const e = document.querySelector('.ProseMirror');
    if (!e) throw new Error('Flow prompt box not found');
    e.focus();
    document.execCommand('selectAll');
    document.execCommand('delete');
    document.execCommand('insertText', false, it.prompt);
    S.next++;
    return it.id;
  };

  /** Which queued prompts are visible in the project (submitted ok). */
  window.flowStatus = () => {
    const t = norm(document.body.innerText);
    return S.items.map((it) => ({ id: it.id, seen: t.includes(norm(it.prompt).slice(0, 120)) }));
  };

  const scroller = () =>
    [...document.querySelectorAll('*')]
      .filter((e) => e.scrollHeight > e.clientHeight + 200 && /auto|scroll/.test(getComputedStyle(e).overflowY))
      .sort((a, b) => b.scrollHeight - a.scrollHeight)[0];

  /** Image src → queued id, by the prompt text of the card the image is in. */
  const scan = (found) => {
    for (const img of document.querySelectorAll('img')) {
      if (img.naturalWidth < 300 || found.has(img.src)) continue;
      let a = img;
      for (let k = 0; k < 10 && a; k++) {
        a = a.parentElement;
        if (!a) break;
        const t = norm(a.innerText);
        const hits = S.items.filter((it) => t.includes(norm(it.prompt).slice(0, 170)));
        if (hits.length === 1) {
          found.set(img.src, hits[0].id);
          break;
        }
        if (hits.length > 1) break;
      }
    }
  };

  /** Finds all finished images and uploads them to MotionAI. */
  window.flowCollect = async ({ step = 300, wait = 350 } = {}) => {
    if (!S.token) throw new Error('flowSetup({token}) first');
    const found = new Map();
    const sc = scroller();
    if (sc) {
      for (let y = 0; y <= sc.scrollHeight; y += step) {
        sc.scrollTop = y;
        await new Promise((r) => setTimeout(r, wait));
        scan(found);
      }
    } else scan(found);
    const count = {};
    const sent = [], failed = [];
    for (const [src, id] of found) {
      count[id] = (count[id] || 0) + 1;
      try {
        const res = await fetch(src);
        const blob = await res.blob();
        const ext = blob.type.includes('png') ? 'png' : blob.type.includes('webp') ? 'webp' : 'jpg';
        const name = `${id}_${count[id]}.${ext}`;
        if (S.sent[name]) continue;
        const up = await fetch(`http://127.0.0.1:${S.port}/api/upload?folder=${encodeURIComponent(S.folder)}&name=${encodeURIComponent(name)}`, {
          method: 'POST',
          headers: { Authorization: 'Bearer ' + S.token, 'Content-Type': blob.type || 'application/octet-stream' },
          body: blob,
        });
        const j = await up.json();
        if (!up.ok) throw new Error(j.error || up.status);
        S.sent[name] = j.path;
        sent.push(name);
      } catch (e) {
        failed.push(`${id}: ${e.message || e}`);
      }
    }
    const missing = S.items.map((it) => it.id).filter((id) => !count[id]);
    return { sent, failed, missing, folder: S.folder };
  };
})();
