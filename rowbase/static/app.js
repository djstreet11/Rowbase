'use strict';
// Rowbase UI — tabs, table browser with WHERE/ORDER BY autocomplete, SQL console, history. No dependencies.

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]));
const enc = encodeURIComponent;
const store = {
  get(k, d) { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch (e) { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* storage unavailable */ } },
};

async function api(path, body) {
  const opts = body ? {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Rowbase': '1'}, body: JSON.stringify(body)}
                    : {headers: {'X-Rowbase': '1'}};
  const r = await fetch(path, opts);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
function toast(msg, ok = false) {
  const t = document.createElement('div');
  t.className = 'toast' + (ok ? ' ok' : '');
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ok ? 2500 : 7000);
}
function status(text, warn = '') { $('#st').textContent = text; $('#stWarn').textContent = warn; }
const plural = (n, w) => `${fmtN(n)} ${w}${+n === 1 ? '' : 's'}`;
const fmtN = n => Number(n).toLocaleString();
const dq = d => (d === 'mysql' ? '`' : '"');
const quoteId = (d, n) => dq(d) + String(n).split(dq(d)).join(dq(d) + dq(d)) + dq(d);
/** Identifier for suggestions: quoted only when needed ("schema.table" is quoted part by part on non-MySQL). */
const idRef = (d, n) => (d === 'mysql' ? (/^\w+$/.test(n) ? n : quoteId(d, n)) : n.split('.').map(p => (/^[a-z_][a-z0-9_]*$/.test(p) ? p : quoteId(d, p))).join('.'));
const sqlLit = v => (/^-?\d+(\.\d+)?$/.test(String(v)) ? String(v) : "'" + String(v).replace(/'/g, "''") + "'");
const READ_FIRST = /^(SELECT|SHOW|EXPLAIN|DESC|DESCRIBE|WITH|VALUES|TABLE|PRAGMA)$/i;

// ------------------------------------------------------------------ schema cache

const Schema = {
  tables: {}, meta: {}, metaSync: {},
  async loadTables(conn) {
    if (!this.tables[conn]) this.tables[conn] = api('/api/tables?conn=' + enc(conn)).catch(e => { delete this.tables[conn]; throw e; });
    return this.tables[conn];
  },
  table(conn, name) {
    const k = conn + '|' + name;
    if (!this.meta[k]) {
      this.meta[k] = api(`/api/table?conn=${enc(conn)}&name=${enc(name)}`)
        .then(m => (this.metaSync[k] = m))
        .catch(e => { delete this.meta[k]; throw e; });
    }
    return this.meta[k];
  },
  sync(conn, name) { return this.metaSync[conn + '|' + name]; },
  clear(conn) {
    if (!conn) { this.tables = {}; this.meta = {}; this.metaSync = {}; return; }
    delete this.tables[conn];
    for (const m of [this.meta, this.metaSync]) for (const k of Object.keys(m)) if (k.startsWith(conn + '|')) delete m[k];
  },
};
const enumValues = type => {
  const m = /^(?:enum|set)\((.*)\)$/s.exec(type || '');
  return m ? (m[1].match(/'((?:[^']|'')*)'/g) || []).map(x => x.slice(1, -1).replace(/''/g, "'")) : null;
};

// ------------------------------------------------------------------ SQL helpers

const KEYWORDS = ('SELECT FROM WHERE AND OR NOT IN IS NULL LIKE BETWEEN EXISTS JOIN LEFT RIGHT INNER OUTER CROSS STRAIGHT_JOIN ON USING AS ' +
  'ORDER GROUP BY HAVING LIMIT OFFSET DISTINCT UNION ALL CASE WHEN THEN ELSE END ASC DESC WITH SHOW TABLES COLUMNS DESCRIBE EXPLAIN ' +
  'ANALYZE FORMAT INTERVAL DAY HOUR MINUTE SECOND MONTH YEAR TRUE FALSE REGEXP COLLATE FORCE INDEX IGNORE ILIKE RETURNING LATERAL FILTER').split(' ');
const KW_SET = new Set(KEYWORDS);
const FUNCS = ['COUNT', 'SUM', 'MIN', 'MAX', 'AVG', 'NOW', 'CURDATE', 'DATE', 'DATE_FORMAT', 'DATE_SUB', 'DATE_ADD', 'TIMESTAMPDIFF',
  'CONCAT', 'CONCAT_WS', 'GROUP_CONCAT', 'IFNULL', 'COALESCE', 'IF', 'NULLIF', 'CAST', 'LENGTH', 'LOWER', 'UPPER', 'TRIM', 'SUBSTRING',
  'LEFT', 'RIGHT', 'REPLACE', 'HEX', 'UNHEX', 'ROUND', 'ABS', 'JSON_EXTRACT', 'JSON_UNQUOTE', 'FIND_IN_SET',
  'TO_CHAR', 'DATE_TRUNC', 'STRING_AGG', 'ARRAY_AGG', 'JSONB_EXTRACT_PATH_TEXT'];
const FN_SET = new Set(FUNCS);
const TOKEN_RE = /(--[^\n]*|#[^\n]*|\/\*[\s\S]*?(?:\*\/|$))|('(?:[^'\\]|\\.|'')*'?)|("(?:[^"\\]|\\.)*"?)|(`[^`]*`?)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)/g;

function highlightSql(src) {
  let out = '', last = 0, m;
  TOKEN_RE.lastIndex = 0;
  while ((m = TOKEN_RE.exec(src))) {
    out += esc(src.slice(last, m.index));
    const t = m[0];
    let cls = '';
    if (m[1]) cls = 'c'; else if (m[2] || m[3]) cls = 's'; else if (m[4]) cls = 'q'; else if (m[5]) cls = 'n';
    else if (KW_SET.has(t.toUpperCase())) cls = 'k';
    else if (FN_SET.has(t.toUpperCase()) && src[TOKEN_RE.lastIndex] === '(') cls = 'f';
    out += cls ? `<span class="${cls}">${esc(t)}</span>` : esc(t);
    last = TOKEN_RE.lastIndex;
  }
  return out + esc(src.slice(last)) + '\n';
}
const stripLiterals = (s, ident) => s.replace(/--[^\n]*|#[^\n]*|\/\*[\s\S]*?\*\//g, ' ').replace(ident ? /'(?:[^'\\]|\\.|'')*'/g : /'(?:[^'\\]|\\.|'')*'|"(?:[^"\\]|\\.)*"/g, "''");

/** Statement under the caret (statements split by ';' outside literals). */
function statementAt(text, pos) {
  let start = 0, inQ = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) { if (c === '\\') i++; else if (c === inQ) inQ = null; continue; }
    if (c === "'" || c === '"' || c === '`') { inQ = c; continue; }
    if (c === '-' && text[i + 1] === '-') { const e = text.indexOf('\n', i); i = e < 0 ? text.length : e; continue; }
    if (c === ';') {
      if (pos <= i) return text.slice(start, i).trim();
      start = i + 1;
    }
  }
  const tail = text.slice(start).trim();
  if (tail) return tail;
  // caret after the last ';' with nothing behind it: run the previous statement
  const parts = text.split(';').map(s => s.trim()).filter(Boolean);
  return parts[parts.length - 1] || '';
}

/** Tables referenced by FROM/JOIN with their aliases. */
function tableRefs(text, known, driver) {
  const out = [], re = /\b(?:FROM|JOIN)\s+((?:[`"]?\w+[`"]?\.)?[`"]?\w+[`"]?)(?:\s+(?:AS\s+)?[`"]?(\w+)[`"]?)?/gi;
  const clean = stripLiterals(text, driver !== 'mysql');
  let m;
  while ((m = re.exec(clean))) {
    const raw = m[1].replace(/[`"]/g, ''), name = known.has(raw) ? raw : raw.replace(/^public\./, '');
    if (!known.has(name)) continue;
    const alias = m[2] && !KW_SET.has(m[2].toUpperCase()) ? m[2] : null;
    out.push({table: name, alias});
  }
  return out;
}

// ------------------------------------------------------------------ autocomplete

function caretPoint(el) {
  const cs = getComputedStyle(el), m = document.createElement('div');
  for (const p of ['boxSizing', 'width', 'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth', 'paddingTop',
    'paddingRight', 'paddingBottom', 'paddingLeft', 'fontStyle', 'fontWeight', 'fontSize', 'lineHeight', 'fontFamily', 'letterSpacing', 'tabSize']) {
    m.style[p] = cs[p];
  }
  Object.assign(m.style, {position: 'absolute', visibility: 'hidden', top: '0', left: '-9999px', whiteSpace: 'pre', overflow: 'hidden'});
  m.textContent = el.value.slice(0, el.selectionStart);
  const mark = document.createElement('span');
  mark.textContent = '​';
  m.appendChild(mark);
  document.body.appendChild(m);
  const r = el.getBoundingClientRect();
  const lh = parseFloat(cs.lineHeight) || 18;
  const pt = {x: r.left + mark.offsetLeft - el.scrollLeft, y: r.top + mark.offsetTop - el.scrollTop + lh + 2};
  m.remove();
  if (el.tagName === 'INPUT') pt.y = r.bottom + 2;
  return pt;
}

class AutoComplete {
  /** provider(ctx) -> Promise<[{label, kind, detail, insert, back}]>; ctx = {before, prefix, qual, start, pos, inString, text} */
  constructor(el, provider) {
    this.el = el; this.provider = provider; this.box = null; this.items = []; this.sel = 0; this.seq = 0;
    el.addEventListener('input', () => { if (this.skip) { this.skip = false; return; } this.update(false); });
    el.addEventListener('keydown', e => this.key(e));
    el.addEventListener('blur', () => setTimeout(() => this.close(), 120));
    el.addEventListener('mousedown', () => this.close());
  }
  get open() { return !!this.box; }
  context() {
    const pos = this.el.selectionStart, text = this.el.value, before = text.slice(0, pos);
    const m = /(?:[`"]?([A-Za-z_]\w*)[`"]?\.)?[`"]?(\w*)$/.exec(before);
    const prefix = m[2], qual = m[1] || null;
    const inString = /'[^']*$/.test(before.replace(/'(?:[^'\\]|\\.|'')*'/g, ''));
    return {pos, text, before, prefix, qual, start: pos - prefix.length, inString};
  }
  async update(force) {
    const ctx = this.context();
    const afterDot = !!ctx.qual && /\.\w*$/.test(ctx.before);
    if (!force && !ctx.prefix && !afterDot && !(ctx.inString && /'$/.test(ctx.before)) && !/[=(]\s*$/.test(ctx.before)) return this.close();
    const seq = ++this.seq;
    let items = [];
    try { items = await this.provider(ctx); } catch (e) { items = []; }
    if (seq !== this.seq) return;
    const p = ctx.prefix.toLowerCase();
    const starts = [], contains = [];
    for (const it of items) {
      const l = it.label.toLowerCase();
      if (!p || l.startsWith(p)) starts.push(it); else if (l.includes(p)) contains.push(it);
    }
    this.items = starts.concat(contains).slice(0, 80);
    if (!this.items.length || (this.items.length === 1 && this.items[0].label === ctx.prefix && !force)) return this.close();
    this.sel = 0;
    this.render(ctx);
  }
  render(ctx) {
    if (!this.box) {
      this.box = document.createElement('div');
      this.box.className = 'ac';
      this.box.addEventListener('mousedown', e => {
        e.preventDefault();
        const d = e.target.closest('[data-i]');
        if (d) this.accept(this.items[+d.dataset.i]);
      });
      document.body.appendChild(this.box);
    }
    const p = ctx.prefix;
    const kinds = {col: 'C', tbl: 'T', kw: 'K', fn: 'ƒ', val: 'V'};
    this.box.innerHTML = this.items.map((it, i) => {
      const l = esc(it.label);
      const lb = p && it.label.toLowerCase().startsWith(p.toLowerCase()) ? `<b>${esc(it.label.slice(0, p.length))}</b>${esc(it.label.slice(p.length))}` : l;
      return `<div data-i="${i}" class="${i === this.sel ? 'sel' : ''}"><span class="kd ${it.kind}">${kinds[it.kind] || ''}</span><span class="lb">${lb}</span><span class="dt">${esc(it.detail || '')}</span></div>`;
    }).join('');
    const pt = caretPoint(this.el);
    const w = Math.min(520, Math.max(240, this.box.offsetWidth));
    this.box.style.left = Math.max(4, Math.min(pt.x - 24, innerWidth - w - 8)) + 'px';
    this.box.style.top = Math.min(pt.y, innerHeight - 290) + 'px';
  }
  move(d) {
    this.sel = (this.sel + d + this.items.length) % this.items.length;
    $$('div', this.box).forEach((x, i) => x.classList.toggle('sel', i === this.sel));
    this.box.children[this.sel]?.scrollIntoView({block: 'nearest'});
  }
  accept(it) {
    const ctx = this.context(), v = this.el.value;
    let ins = it.insert ?? it.label;
    if (ctx.inString && it.kind === 'val' && v[ctx.pos] !== "'") ins += "'";
    const st = ctx.start - (/[`"]/.test(v[ctx.start - 1] || '') && /^[`"]/.test(ins) ? 1 : 0);
    this.el.value = v.slice(0, st) + ins + v.slice(ctx.pos);
    const caret = st + ins.length - (it.back || 0);
    this.el.setSelectionRange(caret, caret);
    this.close();
    this.skip = true;
    this.el.dispatchEvent(new Event('input'));
    this.el.focus();
  }
  key(e) {
    if (e.key === ' ' && e.ctrlKey) { e.preventDefault(); this.update(true); return; }
    if (!this.box) return;
    const keys = {ArrowDown: () => this.move(1), ArrowUp: () => this.move(-1), Enter: () => this.accept(this.items[this.sel]),
      Tab: () => this.accept(this.items[this.sel]), Escape: () => this.close()};
    if (keys[e.key] && !(e.key === 'Enter' && (e.metaKey || e.ctrlKey))) {
      e.preventDefault();
      e.stopImmediatePropagation();
      keys[e.key]();
    }
  }
  close() { this.seq++; this.box?.remove(); this.box = null; }
}

const colItem = (c, detail) => ({label: c.name, kind: 'col', detail: detail ?? c.type});
const kwItems = list => list.map(k => typeof k === 'string' ? {label: k, kind: 'kw'} : {kind: 'kw', ...k});
const fnItems = () => FUNCS.map(f => ({label: f, kind: 'fn', insert: f + '()', back: 1, detail: 'function'}));
const WHERE_KW = ['AND', 'OR', 'NOT', {label: 'IN ()', insert: 'IN ()', back: 1}, {label: 'NOT IN ()', insert: 'NOT IN ()', back: 1}, 'IS NULL',
  'IS NOT NULL', "LIKE ''", 'BETWEEN', 'NOW()', 'CURDATE()', 'INTERVAL', 'DAY', 'HOUR', 'REGEXP'];

/** Values for the column right before an operator: enum values, 0/1 for flags. */
function valueItems(before, columns, quoted) {
  const m = /[`"]?(\w+)[`"]?\s*(?:=|<>|!=|(?:NOT\s+)?IN\s*\((?:\s*'[^']*'\s*,)*)\s*'?\w*$/i.exec(before);
  if (!m) return null;
  const c = columns.find(x => x.name.toLowerCase() === m[1].toLowerCase());
  if (!c) return null;
  const q = v => (quoted ? v : `'${v}'`);
  const ev = enumValues(c.type);
  if (ev) return ev.map(v => ({label: q(v), insert: quoted ? v : `'${v}'`, kind: 'val', detail: c.name}));
  if (/^tinyint\(1\)/.test(c.type)) return quoted ? [] : ['0', '1'].map(v => ({label: v, kind: 'val', detail: c.name}));
  return null;
}

// ------------------------------------------------------------------ app state & tabs

const App = {conn: null, conns: [], tabs: [], active: null, seq: 1};
const connOf = id => App.conns.find(c => c.id === id);
const curConn = () => connOf(App.conn);
const driverOf = id => connOf(id)?.driver || 'mysql';
const connLabel = c => c.name + (c.env ? ` [${c.env}]` : '');
const activeTab = () => App.tabs.find(t => t.id === App.active);
const hiddenKey = t => t.type === 'table' ? `hide:${t.conn}:${t.table}` : null;
const getHidden = t => new Set(t.type === 'table' ? store.get(hiddenKey(t), []) : (t.hidden || []));
function setHidden(t, set) { if (t.type === 'table') store.set(hiddenKey(t), [...set]); else t.hidden = [...set]; saveTabs(); }

function saveTabs() {
  store.set('tabs', App.tabs.map(t => ({id: t.id, type: t.type, conn: t.conn, table: t.table, where: t.where, order: t.order,
    limit: t.limit, view: t.view, mode: t.mode, chain: t.chain, title: t.title, label: t.label, sql: t.sql, hidden: t.hidden})));
  store.set('activeTab', App.active);
}

function newTab(props) {
  const t = Object.assign({id: 't' + Date.now().toString(36) + (App.seq++), type: 'table', conn: App.conn, where: '', order: null,
    limit: 100, offset: 0, view: 'data', mode: 'grid', chain: [], res: null, sort: null, sql: '', title: ''}, props);
  App.tabs.push(t);
  activate(t.id);
  return t;
}

function openTable(table, opts = {}) {
  const where = opts.where || '';
  const conn = opts.conn || App.conn;
  if (!connOf(conn)) { toast('Add a connection first'); return openManager(); }
  const ex = App.tabs.find(t => t.type === 'table' && t.conn === conn && t.table === table && (t.where || '') === where);
  if (ex) { if (opts.label && !ex.label) ex.label = opts.label; return activate(ex.id); }
  return newTab({type: 'table', conn, table, where, chain: opts.chain || [], label: opts.label || ''});
}

function openConsole(sql = '', opts = {}) {
  if (!connOf(opts.conn || App.conn)) { toast('Add a connection first'); return openManager(); }
  const n = App.tabs.filter(t => t.type === 'console').length + 1;
  return newTab({type: 'console', conn: opts.conn || App.conn, sql, title: 'SQL ' + n, chain: opts.chain || []});
}

function closeTab(id) {
  const i = App.tabs.findIndex(t => t.id === id);
  if (i < 0) return;
  App.tabs[i].el?.remove();
  App.tabs.splice(i, 1);
  if (App.active === id) App.active = (App.tabs[i] || App.tabs[i - 1])?.id || null;
  if (App.active) activate(App.active); else { renderTabbar(); $('#welcome').hidden = false; saveTabs(); }
}

function tabTitle(t) {
  if (t.type === 'console') return t.title;
  let s = t.table;
  if (t.label) s += ' · ' + t.label;
  else if (t.where) s += ' · ' + (t.where.length > 40 ? t.where.slice(0, 38) + '…' : t.where);
  return s;
}

function renderTabbar() {
  $('#tabbar').innerHTML = App.tabs.map(t => `<div class="tab${t.id === App.active ? ' on' : ''}" data-id="${t.id}" title="${esc(t.type === 'table' ? (t.table + (t.where ? '\nWHERE ' + t.where : '')) : t.title)}">
      <span class="ic">${t.type === 'console' ? 'SQL' : '▦'}</span><span class="tt">${esc(tabTitle(t))}</span>${t.conn !== App.conn ? `<span class="ic">${esc(connOf(t.conn)?.name || '?')}</span>` : ''}<button class="x" title="Close (middle click)">×</button></div>`).join('');
  $('#tabbar .tab.on')?.scrollIntoView({block: 'nearest', inline: 'nearest'});
}

function activate(id) {
  App.active = id;
  const t = activeTab();
  $('#welcome').hidden = true;
  App.tabs.forEach(x => { if (x.el) x.el.hidden = x.id !== id; });
  if (!t.el) buildPane(t);
  renderTabbar();
  if (t.type === 'table') { highlightSidebar(); if (!t.res && !t.loading) loadTable(t); }
  showStatus(t);
  saveTabs();
  closeDrawer('#rowDrawer');
  return t;
}

function showStatus(t) {
  const c = t ? connOf(t.conn) : curConn();
  $('#stConn').textContent = c ? `${c.name} · ${c.driver}` : '';
  if (t?.res) status(t.res.affected != null ? `${plural(t.res.affected, 'row')} affected · ${t.res.elapsed.toFixed(2)} s` : `${plural(t.res.rows.length, 'row')} · ${t.res.elapsed.toFixed(2)} s`,
    t.res.truncated ? `truncated to ${t.lastLimit} — add a WHERE or raise the limit` : '');
  else status('—');
}

function renderCrumbs(t) {
  const el = $('.crumbs', t.el);
  if (!t.chain.length) { el.innerHTML = ''; return; }
  el.innerHTML = t.chain.map((c, i) => `<a data-i="${i}">${esc(c.title)}</a>${c.via ? ` <span class="via">${esc(c.via)}</span>` : ''} ›`).join(' ')
    + ` <b>${esc(tabTitle(t))}</b>`;
  el.onclick = e => {
    const a = e.target.closest('a[data-i]');
    if (!a) return;
    const c = t.chain[+a.dataset.i];
    if (App.tabs.some(x => x.id === c.tabId)) activate(c.tabId);
    else if (c.table) openTable(c.table, {where: c.where, chain: t.chain.slice(0, +a.dataset.i), conn: t.conn});
  };
}

// ------------------------------------------------------------------ panes

function buildPane(t) {
  const tpl = $(t.type === 'table' ? '#tplTable' : '#tplConsole').content.firstElementChild.cloneNode(true);
  t.el = tpl;
  $('#panes').appendChild(tpl);
  renderCrumbs(t);
  $$('.seg.mode button', tpl).forEach(b => {
    b.classList.toggle('on', b.dataset.m === t.mode);
    b.onclick = () => { t.mode = b.dataset.m; $$('.seg.mode button', tpl).forEach(x => x.classList.toggle('on', x === b)); renderResult(t); saveTabs(); };
  });
  $('.cols', tpl).onclick = e => colPicker(t, e.currentTarget);
  $('.json', tpl).onclick = () => exportRes(t, 'json');
  $('.tsv', tpl).onclick = () => exportRes(t, 'tsv');
  $('.limit', tpl).value = String(t.limit);
  $('.result', tpl).addEventListener('click', e => gridClick(t, e));
  $('.result', tpl).addEventListener('auxclick', e => gridClick(t, e));
  updateColsBtn(t);
  if (t.type === 'table') buildTablePane(t, tpl); else buildConsolePane(t, tpl);
}

function buildTablePane(t, el) {
  const where = $('.where', el), order = $('.order', el);
  where.value = t.where;
  const run = () => { t.where = where.value.trim(); t.order = order.value.trim(); t.offset = 0; renderTabbar(); saveTabs(); runTable(t); };
  $('.run', el).onclick = run;
  $('.limit', el).onchange = e => { t.limit = +e.target.value; t.offset = 0; saveTabs(); runTable(t); };
  $('.prev', el).onclick = () => { t.offset = Math.max(0, t.offset - t.limit); runTable(t); };
  $('.next', el).onclick = () => { t.offset += t.limit; runTable(t); };
  $('.count', el).onclick = () => countRows(t);
  $('.tosql', el).onclick = () => openConsole(tableSql(t), {conn: t.conn});
  $$('.seg.view button', el).forEach(b => {
    b.classList.toggle('on', b.dataset.v === t.view);
    b.onclick = () => { t.view = b.dataset.v; applyView(t); saveTabs(); };
  });
  new AutoComplete(where, async ctx => {
    const c = (await Schema.table(t.conn, t.table)).columns;
    if (ctx.inString) return valueItems(ctx.before.slice(0, ctx.start), c, true) || [];
    const vals = valueItems(ctx.before.slice(0, ctx.start), c, false);
    if (vals && !ctx.prefix) return vals;
    return (vals || []).concat(c.map(x => colItem(x)), kwItems(WHERE_KW), fnItems());
  });
  new AutoComplete(order, async () => (await Schema.table(t.conn, t.table)).columns.map(x => colItem(x)).concat(kwItems(['ASC', 'DESC'])));
  // registered after the autocompletes: Enter with an open suggestion list accepts it instead of running
  [where, order].forEach(inp => inp.addEventListener('keydown', e => { if (e.key === 'Enter') run(); }));
  applyView(t);
}

function applyView(t) {
  const s = t.view === 'structure';
  $$('.seg.view button', t.el).forEach(b => b.classList.toggle('on', b.dataset.v === t.view));
  $('.result', t.el).hidden = s;
  $('.structure', t.el).hidden = !s;
  $('.sqlline', t.el).hidden = s;
  $$('.bar2 > *', t.el).forEach(x => { if (!x.classList.contains('mode') && !x.classList.contains('spacer')) x.disabled = s; });
  if (s) renderStructure(t);
}

const qTable = t => Schema.sync(t.conn, t.table)?.quoted || (driverOf(t.conn) === 'mysql' ? quoteId('mysql', t.table) : t.table.split('.').map(p => quoteId('postgres', p)).join('.'));
function tableSql(t) {
  let sql = 'SELECT *\nFROM ' + qTable(t);
  if (t.where) sql += '\nWHERE ' + t.where;
  if (t.order) sql += '\nORDER BY ' + t.order;
  return sql + '\nLIMIT ' + t.limit + (t.offset ? ' OFFSET ' + t.offset : '');
}

async function loadTable(t) {
  t.loading = true;
  $('.result', t.el).innerHTML = '<div class="empty">Loading…</div>';
  try {
    const meta = await Schema.table(t.conn, t.table);
    if (t.order === null) {
      const pk = meta.columns.filter(c => c.key === 'PRI');
      t.order = !t.where && pk.length === 1 ? quoteId(meta.driver || driverOf(t.conn), pk[0].name) + ' DESC' : '';
    }
    $('.order', t.el).value = t.order;
    updateColsBtn(t);
    await runTable(t);
  } catch (e) {
    $('.result', t.el).innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  } finally { t.loading = false; }
}

async function runTable(t) {
  const sql = tableSql(t);
  $('.sqlline', t.el).textContent = sql.replace(/\n/g, ' ');
  const r = await execute(t, sql, t.limit, 'table');
  const p = $('.page', t.el);
  p.textContent = r ? (r.rows.length ? `${fmtN(t.offset + 1)}–${fmtN(t.offset + r.rows.length)}` : '0') : '';
  $('.prev', t.el).disabled = !t.offset;
  $('.next', t.el).disabled = !r || r.rows.length < t.limit;
}

async function countRows(t) {
  status('COUNT…');
  try {
    const sql = 'SELECT COUNT(*) AS cnt FROM ' + (await Schema.table(t.conn, t.table)).quoted + (t.where ? ' WHERE ' + t.where : '');
    const r = await api('/api/query', {conn: t.conn, sql, limit: 1, timeout: 60, source: 'count'});
    status(`COUNT = ${fmtN(r.rows[0][0])} · ${r.elapsed.toFixed(2)} s`);
  } catch (e) { status('Error'); toast(e.message); }
}

async function execute(t, sql, limit, source) {
  status('Running…');
  const box = $('.result', t.el);
  box.style.opacity = '.5';
  try {
    const r = await api('/api/query', {conn: t.conn, sql, limit, source});
    t.res = r; t.lastLimit = limit; t.sort = null;
    t.res.explain = /^\s*EXPLAIN\b/i.test(sql);
    if (r.affected != null) {
      Schema.clear(t.conn);
      api('/api/refresh', {conn: t.conn}).catch(() => {}).then(() => (t.conn === App.conn ? reloadTables() : 0));
    }
    renderResult(t);
    if (App.active === t.id) showStatus(t);
    return r;
  } catch (e) {
    status('Error');
    toast(e.message);
    return null;
  } finally { box.style.opacity = ''; }
}

// ------------------------------------------------------------------ console

function buildConsolePane(t, el) {
  const ta = $('textarea', el), pre = $('pre.hl', el);
  ta.value = t.sql;
  const paint = () => { pre.innerHTML = highlightSql(ta.value); pre.scrollTop = ta.scrollTop; pre.scrollLeft = ta.scrollLeft; };
  ta.addEventListener('input', () => { t.sql = ta.value; paint(); saveTabsSoon(); });
  ta.addEventListener('scroll', () => { pre.scrollTop = ta.scrollTop; pre.scrollLeft = ta.scrollLeft; });
  paint();
  const ac = new AutoComplete(ta, ctx => consoleSuggestions(t, ctx));
  ta.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); runConsole(t, ''); return; }
    if (e.key === 'Tab' && !ac.open) {
      e.preventDefault();
      const s = ta.selectionStart;
      ta.setRangeText('  ', s, ta.selectionEnd, 'end');
      ta.dispatchEvent(new Event('input'));
    }
  });
  $('.run', el).onclick = () => runConsole(t, '');
  const lite = driverOf(t.conn) === 'sqlite';
  $('.explain', el).onclick = () => runConsole(t, lite ? 'EXPLAIN QUERY PLAN ' : 'EXPLAIN ');
  $('.analyze', el).onclick = () => runConsole(t, 'EXPLAIN ANALYZE ');
  if (lite) { $('.explain', el).textContent = 'EXPLAIN QUERY PLAN'; $('.analyze', el).hidden = true; }
  $('.limit', el).onchange = e => { t.limit = +e.target.value; saveTabs(); };
  setTimeout(() => ta.focus(), 0);
}
let saveTimer = null;
const saveTabsSoon = () => { clearTimeout(saveTimer); saveTimer = setTimeout(saveTabs, 400); };

function runConsole(t, prefix) {
  const ta = $('textarea', t.el);
  const sel = ta.value.slice(ta.selectionStart, ta.selectionEnd).trim();
  let sql = (sel || statementAt(ta.value, ta.selectionStart)).replace(/;\s*$/, '');
  if (!sql) return;
  if (prefix) sql = prefix + sql.replace(/^\s*EXPLAIN(\s+ANALYZE|\s+QUERY\s+PLAN)?\s+/i, '');
  const c = connOf(t.conn);
  if (!c) return toast('Connection no longer exists');
  const first = (/^\s*\(*\s*(\w+)/.exec(stripLiterals(sql.replace(/^\s*EXPLAIN\s+ANALYZE\s+/i, ''))) || [])[1] || '';
  if (!c.readOnly && !READ_FIRST.test(first) && !confirm(`Run on READ-WRITE connection ${c.name}?\n\n${sql.slice(0, 300)}`)) return;
  $('.sqlline', t.el).textContent = sql.replace(/\s+/g, ' ');
  return execute(t, sql, t.limit, prefix ? prefix.trim().toLowerCase() : 'console');
}

async function consoleSuggestions(t, ctx) {
  const tables = await Schema.loadTables(t.conn), d = driverOf(t.conn);
  const known = new Set(tables.map(x => x.name));
  const refs = tableRefs(ctx.text, known, d);
  const metas = await Promise.all(refs.map(r => Schema.table(t.conn, r.table).catch(() => null)));
  const allCols = refs.flatMap((r, i) => (metas[i]?.columns || []).map(c => ({c, r})));
  const columnsOnly = allCols.map(x => x.c);
  if (ctx.inString) return valueItems(ctx.before.slice(0, ctx.start), columnsOnly, true) || [];
  if (ctx.qual) {
    const q = ctx.qual.toLowerCase();
    const r = refs.find(x => (x.alias || '').toLowerCase() === q) || refs.find(x => x.table.toLowerCase() === q)
      || (known.has(ctx.qual) ? {table: ctx.qual} : null);
    if (!r) return tables.filter(x => x.name.startsWith(ctx.qual + '.')).map(x => ({label: x.name.slice(ctx.qual.length + 1), kind: 'tbl', detail: x.kind === 'view' ? 'view' : ''}));
    return (await Schema.table(t.conn, r.table)).columns.map(c => colItem(c));
  }
  const prev = stripLiterals(ctx.before.slice(0, ctx.start)).trimEnd();
  const prevWord = (/(\w+|,)$/.exec(prev) || [])[1]?.toUpperCase() || '';
  const lastKw = ([...prev.matchAll(/\b(SELECT|FROM|JOIN|WHERE|ON|AND|OR|BY|HAVING|LIMIT|DESC|DESCRIBE|SHOW)\b/gi)].pop() || [])[1]?.toUpperCase();
  if (['FROM', 'JOIN', 'DESCRIBE', 'DESC'].includes(prevWord) || (prevWord === ',' && lastKw === 'FROM')) {
    return tables.map(x => ({label: x.name, insert: idRef(d, x.name), kind: 'tbl', detail: x.kind === 'view' ? 'view' : x.rows != null ? fmtN(x.rows) + ' rows' : ''}));
  }
  const vals = valueItems(ctx.before.slice(0, ctx.start), columnsOnly, false);
  if (vals && !ctx.prefix) return vals;
  const multi = refs.length > 1;
  const colItems = allCols.map(({c, r}) => ({label: multi ? `${r.alias || r.table}.${c.name}` : c.name, kind: 'col', detail: c.type}));
  // when an alias is typed as plain word (no dot yet) also offer aliases
  const aliasItems = refs.map(r => ({label: r.alias || r.table, kind: 'tbl', detail: r.alias ? r.table : 'table'}));
  const kws = kwItems(KEYWORDS.map(k => ({label: k}))).concat(kwItems(WHERE_KW.filter(k => typeof k !== 'string')));
  let out = (vals || []).concat(colItems, aliasItems, fnItems(), kws);
  if (!refs.length) out = out.concat(tables.map(x => ({label: x.name, insert: idRef(d, x.name), kind: 'tbl', detail: x.kind === 'view' ? 'view' : 'table'})));
  return out;
}

// ------------------------------------------------------------------ result rendering

function visibleCols(t) {
  const r = t.res, hidden = getHidden(t);
  return r.cols.map((c, i) => i).filter(i => !hidden.has(r.cols[i]));
}

function cellHtml(v, ci, ri, fk) {
  if (v === null) return '<span class="null">NULL</span>';
  const s = String(v), h = esc(s.length > 300 ? s.slice(0, 300) + '…' : s);
  return fk ? `<span class="ref" data-ci="${ci}" data-ri="${ri}" title="Open ${esc(fk.table)}.${esc(fk.column)} in a new tab">${h}</span>` : h;
}

function renderResult(t) {
  const el = $('.result', t.el), r = t.res;
  updateColsBtn(t);
  if (!r) return;
  if (r.affected != null) { el.innerHTML = `<div class="empty">${plural(r.affected, 'row')} affected</div>`; return; }
  if (!r.cols.length) { el.innerHTML = '<div class="empty">Query executed, no columns returned</div>'; return; }
  if (r.explain && r.cols.length === 1) { el.innerHTML = `<pre class="plan">${r.rows.map(x => (/Seq Scan/.test(x[0]) ? `<span class="warnl">${esc(x[0])}</span>` : esc(x[0]))).join('\n')}</pre>`; return; }
  const idx = visibleCols(t);
  if (!idx.length) { el.innerHTML = '<div class="empty">All columns are hidden — use the Columns button</div>'; return; }
  const meta = t.type === 'table' ? Schema.sync(t.conn, t.table) : null;
  const fkOf = name => meta?.columns.find(c => c.name === name)?.fk || null;
  const typeOf = name => meta?.columns.find(c => c.name === name)?.type || '';
  const off = t.type === 'table' ? t.offset : 0;
  const typeI = r.explain ? r.cols.indexOf('type') : -1, rowsI = r.explain ? r.cols.indexOf('rows') : -1;
  const badRow = row => typeI >= 0 && row[typeI] === 'ALL';
  const badCell = (row, i) => (i === typeI && row[i] === 'ALL') || (i === rowsI && +row[i] > 100000);
  if (t.mode === 'transpose') {
    const head = '<th class="fld">Field</th>' + r.rows.map((_, ri) => `<th class="rn" data-row="${ri}" title="All fields of the row">${off + ri + 1}</th>`).join('');
    const body = idx.map(i => `<tr><th class="fld" title="${esc(typeOf(r.cols[i]))}">${esc(r.cols[i])}</th>${r.rows.map((row, ri) =>
      `<td class="${badCell(row, i) ? 'bad' : ''}">${cellHtml(row[i], i, ri, fkOf(r.cols[i]))}</td>`).join('')}</tr>`).join('');
    el.innerHTML = `<table class="grid tp"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>` + (r.rows.length ? '' : '<div class="empty">Empty</div>');
    return;
  }
  const s = t.sort;
  const head = '<th class="rn">#</th>' + idx.map(i => `<th data-sort="${i}" title="${esc(typeOf(r.cols[i]))}">${esc(r.cols[i])}${s && s.i === i ? (s.dir > 0 ? ' ▲' : ' ▼') : ''}</th>`).join('');
  const body = r.rows.map((row, ri) => `<tr class="${badRow(row) ? 'bad' : ''}"><td class="rn" data-row="${ri}" title="All fields of the row">${off + ri + 1}</td>${idx.map(i =>
    `<td class="${badCell(row, i) ? 'bad' : ''}" title="${row[i] === null ? '' : esc(String(row[i]).slice(0, 500))}">${cellHtml(row[i], i, ri, fkOf(r.cols[i]))}</td>`).join('')}</tr>`).join('');
  el.innerHTML = `<table class="grid"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>` + (r.rows.length ? '' : '<div class="empty">Empty</div>');
}

function sortBy(t, i) {
  const r = t.res, cur = t.sort, dir = cur && cur.i === i ? -cur.dir : 1;
  t.sort = {i, dir};
  r.rows.sort((a, b) => {
    const x = a[i], y = b[i];
    if (x === y) return 0;
    if (x === null) return 1;
    if (y === null) return -1;
    const nx = +x, ny = +y;
    return (!isNaN(nx) && !isNaN(ny) ? nx - ny : String(x).localeCompare(String(y))) * dir;
  });
  renderResult(t);
}

function gridClick(t, e) {
  const th = e.target.closest('th[data-sort]');
  if (th && e.button === 0) return sortBy(t, +th.dataset.sort);
  const rn = e.target.closest('[data-row]');
  if (rn) return openRow(t, +rn.dataset.row);
  const ref = e.target.closest('.ref');
  if (ref) return followFk(t, +ref.dataset.ri, +ref.dataset.ci);
}

function updateColsBtn(t) {
  const b = $('.cols', t.el);
  if (!b) return;
  const total = t.res?.cols.length ?? (t.type === 'table' ? Schema.sync(t.conn, t.table)?.columns.length : 0) ?? 0;
  const hidden = getHidden(t);
  const shown = t.res ? t.res.cols.filter(c => !hidden.has(c)).length : total - hidden.size;
  b.textContent = total ? `Columns ${shown}/${total}` : 'Columns';
  b.classList.toggle('primary', !!total && shown < total);
}

// ------------------------------------------------------------------ popovers

function closePops() { $$('.pop').forEach(p => p.remove()); }
function placePop(p, anchor) {
  document.body.appendChild(p);
  const b = anchor.getBoundingClientRect();
  p.style.left = Math.max(4, Math.min(b.left, innerWidth - p.offsetWidth - 8)) + 'px';
  p.style.top = Math.min(b.bottom + 4, innerHeight - p.offsetHeight - 8) + 'px';
  setTimeout(() => {
    const off = e => { if (!p.contains(e.target)) { p.remove(); document.removeEventListener('mousedown', off); } };
    document.addEventListener('mousedown', off);
  }, 0);
}

function colPicker(t, anchor) {
  closePops();
  const cols = t.res?.cols || Schema.sync(t.conn, t.table)?.columns.map(c => c.name) || [];
  if (!cols.length) return;
  const meta = t.type === 'table' ? Schema.sync(t.conn, t.table) : null;
  const hidden = getHidden(t);
  const p = document.createElement('div');
  p.className = 'pop colpick';
  p.innerHTML = `<div class="ch"><input placeholder="Find column"><button data-a="all">All</button><button data-a="none">None</button></div><div class="cl"></div>`;
  const list = $('.cl', p), q = $('input', p);
  const draw = () => {
    const f = q.value.trim().toLowerCase();
    list.innerHTML = cols.filter(c => !f || c.toLowerCase().includes(f)).map(c => {
      const ty = meta?.columns.find(x => x.name === c)?.type || '';
      return `<label><input type="checkbox" data-c="${esc(c)}"${hidden.has(c) ? '' : ' checked'}>${esc(c)}<i>${esc(ty.length > 24 ? ty.slice(0, 22) + '…' : ty)}</i></label>`;
    }).join('');
  };
  const apply = () => { setHidden(t, hidden); renderResult(t); updateColsBtn(t); };
  list.onchange = e => { const c = e.target.dataset.c; if (e.target.checked) hidden.delete(c); else hidden.add(c); apply(); };
  p.querySelector('.ch').onclick = e => {
    const a = e.target.dataset.a;
    if (!a) return;
    const f = q.value.trim().toLowerCase();
    cols.filter(c => !f || c.toLowerCase().includes(f)).forEach(c => (a === 'all' ? hidden.delete(c) : hidden.add(c)));
    draw(); apply();
  };
  q.oninput = draw;
  draw();
  placePop(p, anchor);
  q.focus();
}

// ------------------------------------------------------------------ foreign keys

const crumbOf = (t, via) => ({tabId: t.id, table: t.type === 'table' ? t.table : null, where: t.where, title: tabTitle(t), via});
function followFk(t, ri, ci) {
  const r = t.res, col = r.cols[ci], v = r.rows[ri][ci];
  const fk = t.type === 'table' ? Schema.sync(t.conn, t.table)?.columns.find(c => c.name === col)?.fk : null;
  if (!fk || v === null) return;
  openTable(fk.table, {where: `${quoteId(driverOf(t.conn), fk.column)} = ${sqlLit(v)}`, chain: [...t.chain, crumbOf(t, col)], conn: t.conn});
}

// ------------------------------------------------------------------ row drawer

let rowCtx = null;
function closeDrawer(sel) { $(sel).classList.remove('open'); }
function openRow(t, ri) {
  rowCtx = {t, ri};
  $('#rowTitle').textContent = `${tabTitle(t)} · #${(t.type === 'table' ? t.offset : 0) + ri + 1}`;
  $('#rowFilter').value = '';
  renderRow();
  closeDrawer('#histDrawer');
  $('#rowDrawer').classList.add('open');
}
function renderRow() {
  const {t, ri} = rowCtx, r = t.res, f = $('#rowFilter').value.trim().toLowerCase();
  const meta = t.type === 'table' ? Schema.sync(t.conn, t.table) : null;
  const fkOf = name => meta?.columns.find(x => x.name === name)?.fk || null;
  const rb = (meta?.referencedBy || []).map((x, k) => ({x, k, v: r.rows[ri][r.cols.indexOf(x.refColumn)]})).filter(o => o.v != null);
  $('#rowBody').innerHTML = r.cols.map((c, i) => {
    const v = r.rows[ri][i];
    if (f && !c.toLowerCase().includes(f) && !String(v ?? '').toLowerCase().includes(f)) return '';
    const ty = meta?.columns.find(x => x.name === c)?.type || '';
    return `<div class="kv"><div class="k">${esc(c)}${ty ? `<small>${esc(ty.length > 40 ? ty.slice(0, 38) + '…' : ty)}</small>` : ''}</div><div class="v">${cellHtml(v, i, ri, fkOf(c))}</div></div>`;
  }).join('') + (rb.length ? `<h3 class="sub">Referenced by</h3>` + rb.map(o => `<div class="kv rb"><div class="k"><span class="ref" data-rb="${o.k}">${esc(o.x.table)}</span></div><div class="v">${esc(o.x.column)} = ${esc(o.v)}</div></div>`).join('') : '');
}

// ------------------------------------------------------------------ structure

async function renderStructure(t) {
  const el = $('.structure', t.el);
  const m = await Schema.table(t.conn, t.table);
  const rows = m.columns.map((c, i) => {
    const ev = enumValues(c.type);
    const type = ev ? `enum <span class="null">(${ev.length})</span><div class="chips">${ev.map(v => `<span class="chip">${esc(v)}</span>`).join('')}</div>` : esc(c.type);
    return `<tr><td class="rn">${i + 1}</td><td><b>${esc(c.name)}</b></td><td>${type}</td><td>${c.nullable ? 'yes' : ''}</td><td>${esc(c.key || '')}</td>
      <td>${c.default === null || c.default === undefined ? '<span class="null">NULL</span>' : esc(c.default)}</td><td>${c.fk ? `<span class="ref" data-open="${esc(c.fk.table)}">${esc(c.fk.table)}.${esc(c.fk.column)}</span>` : ''}</td><td>${esc(c.comment || '')}</td></tr>`;
  }).join('');
  const idx = m.indexes.map(x => `<tr><td><b>${esc(x.name)}</b></td><td>${x.unique ? 'UNIQUE' : ''}</td><td>${esc([].concat(x.cols).join(', '))}</td></tr>`).join('');
  const rb = (m.referencedBy || []).map(x => `<tr><td><span class="ref" data-open="${esc(x.table)}">${esc(x.table)}</span></td><td>${esc(x.column)}</td><td>${esc(x.refColumn)}</td></tr>`).join('');
  el.innerHTML = `<table class="grid"><thead><tr><th class="rn">#</th><th>Column</th><th>Type</th><th>NULL</th><th>Key</th><th>Default</th><th>References</th><th>Comment</th></tr></thead><tbody>${rows}</tbody></table>
    <h3 class="sub">Indexes</h3><table class="grid"><thead><tr><th>Name</th><th></th><th>Columns</th></tr></thead><tbody>${idx}</tbody></table>`
    + (rb ? `<h3 class="sub">Referenced by</h3><table class="grid"><thead><tr><th>Table</th><th>Column</th><th>Refers to</th></tr></thead><tbody>${rb}</tbody></table>` : '');
  el.onclick = e => { const o = e.target.closest('[data-open]'); if (o) openTable(o.dataset.open, {conn: t.conn}); };
}

// ------------------------------------------------------------------ export

function exportRes(t, kind) {
  const r = t.res;
  if (!r) return;
  const idx = visibleCols(t);
  const text = kind === 'json'
    ? JSON.stringify(r.rows.map(row => Object.fromEntries(idx.map(i => [r.cols[i], row[i]]))), null, 2)
    : [idx.map(i => r.cols[i]).join('\t'), ...r.rows.map(row => idx.map(i => row[i] === null ? '' : String(row[i]).replace(/[\t\n]/g, ' ')).join('\t'))].join('\n');
  navigator.clipboard.writeText(text).then(() => toast(`Copied ${r.rows.length} rows as ${kind.toUpperCase()}`, true), () => toast('Copy failed'));
}

// ------------------------------------------------------------------ history

let histData = [];
async function openHistory() {
  closeDrawer('#rowDrawer');
  $('#histDrawer').classList.add('open');
  $('#histBody').innerHTML = '<div class="empty">Loading…</div>';
  try { histData = await api('/api/history?limit=500'); } catch (e) { toast(e.message); histData = []; }
  renderHistory();
  $('#histFilter').focus();
}
function renderHistory() {
  const f = $('#histFilter').value.trim().toLowerCase(), errs = $('#histErrors').checked;
  const list = histData.map((h, i) => ({h, i})).filter(({h}) => (!f || h.sql.toLowerCase().includes(f)) && (!errs || h.error));
  $('#histBody').innerHTML = list.length ? list.slice(0, 300).map(({h, i}) => `<div class="hi" data-i="${i}" title="Open in a new SQL console">
      <div class="meta"><span>${esc(h.ts.replace('T', ' '))}</span><span>${esc(h.connName || h.conn)}</span>${h.source ? `<span class="src">${esc(h.source)}</span>` : ''}
      ${h.error ? `<span class="err">${esc(h.error.slice(0, 90))}</span>` : `<span>${h.affected != null ? plural(h.affected, 'row') + ' affected' : h.rows != null ? plural(h.rows, 'row') : ''}${h.elapsed != null ? ' · ' + h.elapsed + 's' : ''}</span>`}</div>
      <pre>${highlightSql(h.sql)}</pre></div>`).join('') : '<div class="empty">Nothing found</div>';
}

// ------------------------------------------------------------------ sidebar & connections

let tablesList = [];
function renderTables() {
  const f = $('#tableFilter').value.trim().toLowerCase(), k = $('#kindFilter').value;
  const list = tablesList.filter(t => (k === 'all' || (t.kind === 'view') === (k === 'view')) && (!f || t.name.toLowerCase().includes(f)));
  $('#tableList').innerHTML = list.slice(0, 800).map(t => `<div class="t${t.kind === 'view' ? ' view' : ''}" data-t="${esc(t.name)}"><b>${esc(t.name)}</b><i>${t.kind === 'view' ? 'view' : t.rows != null ? fmtN(t.rows) : ''}</i></div>`).join('')
    + (list.length > 800 ? `<div class="empty">${list.length - 800} more… refine the search</div>` : '');
  highlightSidebar();
}
function highlightSidebar() {
  const t = activeTab(), name = t?.type === 'table' && t.conn === App.conn ? t.table : null;
  $$('#tableList .t').forEach(x => x.classList.toggle('active', x.dataset.t === name));
}
async function reloadTables() {
  try { tablesList = App.conn ? await Schema.loadTables(App.conn) : []; renderTables(); } catch (e) { toast(e.message); }
}
function renderConnSelect() {
  const groups = {}, none = [];
  App.conns.forEach(c => (c.group ? (groups[c.group] ||= []) : none).push(c));
  const opt = c => `<option value="${esc(c.id)}">${esc(connLabel(c))}</option>`;
  $('#conn').innerHTML = none.map(opt).join('') + Object.entries(groups).map(([g, l]) => `<optgroup label="${esc(g)}">${l.map(opt).join('')}</optgroup>`).join('');
  $('#conn').value = App.conn || '';
  $('#conn').hidden = !App.conns.length;
}
function renderConnBadge() {
  const c = curConn(), b = $('#connBadge');
  b.hidden = !c;
  if (c) { b.textContent = c.readOnly ? 'read-only' : 'READ-WRITE'; b.classList.toggle('rw', !c.readOnly); }
  $('header').style.setProperty('--envc', c?.env === 'prod' ? (c.color || 'var(--danger)') : 'transparent');
}
function renderWelcome() {
  const w = $('#welcome');
  w.classList.add('welcome');
  w.innerHTML = App.conns.length ? 'Pick a table on the left or open a SQL console (+ SQL).'
    : '<h2>Welcome to Row<span>base</span></h2><p>A small local client for MySQL, PostgreSQL and SQLite.<br>Add a connection to get started.</p><button class="primary" data-add>Add your first connection</button>';
}
async function switchConn(id) {
  App.conn = id;
  store.set('conn', id);
  renderConnSelect(); renderConnBadge(); renderTabbar(); showStatus(activeTab());
  if (!id) { tablesList = []; renderTables(); return; }
  status('Loading tables…');
  try {
    tablesList = await Schema.loadTables(id);
    renderTables();
    status(tablesList.length + ' tables');
  } catch (e) { tablesList = []; renderTables(); toast(e.message); status('Connection error'); }
}
async function loadConns(selectId) {
  App.conns = await api('/api/conns');
  const want = [selectId, App.conn, store.get('conn', null)].find(id => id && connOf(id));
  renderWelcome();
  await switchConn(want || App.conns[0]?.id || null);
}
function pruneTabs() {
  App.tabs.filter(t => !connOf(t.conn)).forEach(t => { t.el?.remove(); });
  App.tabs = App.tabs.filter(t => connOf(t.conn));
  if (!App.tabs.some(t => t.id === App.active)) App.active = App.tabs[0]?.id || null;
  if (App.active) activate(App.active); else { renderTabbar(); $('#welcome').hidden = false; saveTabs(); }
}

// ------------------------------------------------------------------ connection manager

const CM = {id: null};
const cf = n => $('#cf_' + n);
const CF_TEXT = ['name', 'host', 'socket', 'database', 'user', 'path', 'group'];
function cmList() {
  $('#cmList').innerHTML = App.conns.map(c => `<div class="cm-i${c.id === CM.id ? ' on' : ''}" data-id="${esc(c.id)}"><span class="dot"${c.color ? ` style="background:${esc(c.color)}"` : ''}></span><div><b>${esc(c.name)}</b><small>${esc(c.driver)}${c.env ? ' · ' + esc(c.env) : ''}${c.readOnly ? '' : ' · <span class="rw">read-write</span>'}</small></div></div>`).join('')
    || '<div class="empty">No connections yet</div>';
}
function cmDriver() {
  const d = cf('driver').value, lite = d === 'sqlite';
  $('#cmForm .net').hidden = lite;
  $('#cmForm .file').hidden = !lite;
  cf('port').placeholder = d === 'postgres' ? '5432' : '3306';
}
function cmLoad(c) {
  CM.id = c?.id || null;
  CM.options = c?.options ? {...c.options} : null;
  CF_TEXT.forEach(n => (cf(n).value = c?.[n] ?? ''));
  cf('driver').value = c?.driver || 'mysql';
  cf('port').value = c?.port ?? '';
  cf('password').value = '';
  cf('password').placeholder = c ? 'unchanged' : '';
  cf('url').value = '';
  cf('env').value = c?.env || '';
  cf('ro').checked = c ? !!c.readOnly : true;
  cf('color').value = c?.color || '#2f6fec';
  cf('color').toggleAttribute('data-on', !!c?.color);
  $('#cmTitle').textContent = c ? 'Edit connection' : 'New connection';
  $('#cmDel').hidden = !c;
  $('#cmRes').textContent = ''; $('#cmRes').className = 'cm-res';
  $('#cmWarn').hidden = cf('ro').checked;
  cmDriver(); cmList();
}
function openManager(id) {
  const dlg = $('#connDlg');
  cmLoad(connOf(id === undefined ? App.conn : id));
  if (!dlg.open) dlg.showModal();
  cf('name').focus();
}
function cmRead() {
  const d = cf('driver').value, o = {driver: d, readOnly: cf('ro').checked};
  if (CM.id) o.id = CM.id;
  CF_TEXT.forEach(n => (o[n] = cf(n).value.trim()));
  o.port = cf('port').value ? +cf('port').value : null;
  if (cf('env').value) o.env = cf('env').value;
  if (cf('color').hasAttribute('data-on')) o.color = cf('color').value;
  if (CM.options && d !== 'sqlite') o.options = CM.options;
  if (d === 'sqlite') { o.host = ''; o.socket = ''; o.database = ''; o.user = ''; o.port = null; } else o.path = '';
  const pw = cf('password').value;
  return {conn: o, password: CM.id && pw === '' ? null : pw};
}
function parseConnUrl(str) {
  const m = /^\s*(mysql|mariadb|postgres(?:ql)?|sqlite):\/\/(.*)$/i.exec(str);
  if (!m) return null;
  const sc = m[1].toLowerCase(), dec = x => { try { return decodeURIComponent(x); } catch (e) { return x; } };
  if (sc === 'sqlite') return {driver: 'sqlite', path: dec(m[2].split('?')[0].replace(/^\/\//, '/'))};
  // manual parse: URL() rejects socket URLs with an empty host (mysql://user@/db?socket=…)
  const u = /^(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?]*)(?::(\d+))?(?:\/([^?]*))?(?:\?(.*))?$/.exec(m[2].trim());
  if (!u) return null;
  const qs = Object.fromEntries(new URLSearchParams(u[6] || ''));
  const socket = qs.socket || '';
  delete qs.socket;
  return {driver: sc.startsWith('postgres') ? 'postgres' : 'mysql', host: dec(u[3] || ''), port: u[4] || '', user: dec(u[1] || ''),
    password: dec(u[2] || ''), database: dec(u[5] || ''), socket, options: Object.keys(qs).length ? qs : null};
}
function cmSay(msg, ok) { const el = $('#cmRes'); el.textContent = msg; el.className = 'cm-res ' + (ok ? 'ok' : 'err'); }
async function cmSave() {
  const b = cmRead();
  if (!b.conn.name) return cf('name').focus();
  try {
    const c = await api('/api/conns/save', b);
    Schema.clear(c.id);
    await loadConns(c.id);
    await api('/api/refresh', {conn: c.id}).catch(() => {});
    Schema.clear(c.id);
    await reloadTables();
    $('#connDlg').close();
    toast('Connection saved', true);
  } catch (e) { cmSay(e.message, false); }
}
async function cmDelete() {
  const c = connOf(CM.id);
  if (!c || !confirm(`Delete connection "${c.name}"?`)) return;
  try {
    await api('/api/conns/delete', {id: c.id});
    Schema.clear(c.id);
    await loadConns();
    pruneTabs();
    cmLoad(connOf(App.conn));
    toast('Connection deleted', true);
  } catch (e) { cmSay(e.message, false); }
}

// ------------------------------------------------------------------ wiring

$('#conn').onchange = e => switchConn(e.target.value);
$('#tableFilter').oninput = renderTables;
$('#kindFilter').onchange = renderTables;
$('#connBtn').onclick = () => openManager();
$('#welcome').onclick = e => { if (e.target.closest('[data-add]')) openManager(null); };
$('#cmNew').onclick = () => { cmLoad(null); cf('name').focus(); };
$('#cmList').onclick = e => { const d = e.target.closest('[data-id]'); if (d) { cmLoad(connOf(d.dataset.id)); cf('name').focus(); } };
$('#cmX').onclick = $('#cmCancel').onclick = () => $('#connDlg').close();
$('#cmForm').onsubmit = e => { e.preventDefault(); cmSave(); };
$('#cmDel').onclick = cmDelete;
cf('driver').onchange = cmDriver;
cf('ro').onchange = () => ($('#cmWarn').hidden = cf('ro').checked);
cf('color').oninput = () => cf('color').setAttribute('data-on', '');
$('#cf_colorX').onclick = () => cf('color').removeAttribute('data-on');
cf('url').oninput = () => {
  const p = parseConnUrl(cf('url').value);
  if (!p) return;
  for (const [k, v] of Object.entries(p)) if (k === 'options') CM.options = v; else cf(k).value = v ?? '';
  cf('url').value = '';
  cmDriver();
};
$('#cmTest').onclick = async () => {
  cmSay('Testing…', true);
  try { const r = await api('/api/conns/test', cmRead()); cmSay(`OK · ${r.version} · ${Number(r.elapsed).toFixed(2)} s`, true); } catch (e) { cmSay(e.message, false); }
};
$('#tableList').onclick = e => { const t = e.target.closest('[data-t]'); if (t) openTable(t.dataset.t); };
$('#newConsole').onclick = () => openConsole();
$('#historyBtn').onclick = openHistory;
$('#histClose').onclick = () => closeDrawer('#histDrawer');
$('#histFilter').oninput = renderHistory;
$('#histErrors').onchange = renderHistory;
$('#histBody').onclick = e => { const d = e.target.closest('[data-i]'); if (d) { const h = histData[+d.dataset.i]; closeDrawer('#histDrawer'); openConsole(h.sql, {conn: connOf(h.conn) ? h.conn : App.conn}); } };
$('#rowClose').onclick = () => closeDrawer('#rowDrawer');
$('#rowFilter').oninput = renderRow;
$('#rowBody').onclick = e => {
  const ref = e.target.closest('.ref');
  if (!ref || !rowCtx) return;
  const {t, ri} = rowCtx;
  if (ref.dataset.rb !== undefined) {
    const x = Schema.sync(t.conn, t.table).referencedBy[+ref.dataset.rb], v = t.res.rows[ri][t.res.cols.indexOf(x.refColumn)];
    closeDrawer('#rowDrawer');
    openTable(x.table, {where: `${quoteId(driverOf(t.conn), x.column)} = ${sqlLit(v)}`, chain: [...t.chain, crumbOf(t, x.refColumn)], conn: t.conn});
  } else { closeDrawer('#rowDrawer'); followFk(t, ri, +ref.dataset.ci); }
};
$('#rowCopy').onclick = () => {
  const {t, ri} = rowCtx;
  navigator.clipboard.writeText(JSON.stringify(Object.fromEntries(t.res.cols.map((c, i) => [c, t.res.rows[ri][i]])), null, 2)).then(() => toast('Row copied as JSON', true));
};
$('#tabbar').addEventListener('click', e => {
  const tab = e.target.closest('.tab');
  if (!tab) return;
  if (e.target.closest('.x')) closeTab(tab.dataset.id); else activate(tab.dataset.id);
});
$('#tabbar').addEventListener('auxclick', e => { const tab = e.target.closest('.tab'); if (tab && e.button === 1) closeTab(tab.dataset.id); });
$('#refreshBtn').onclick = async () => {
  if (!App.conn) return;
  await api('/api/refresh', {conn: App.conn}).catch(e => toast(e.message));
  Schema.clear(App.conn);
  await switchConn(App.conn);
  const t = activeTab();
  if (t?.type === 'table' && t.conn === App.conn) loadTable(t);
  toast('Schema cache reset', true);
};
document.addEventListener('keydown', e => {
  if (e.key === '/' && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) { e.preventDefault(); $('#tableFilter').focus(); }
  if (e.key === 'Escape') { closeDrawer('#rowDrawer'); closeDrawer('#histDrawer'); closePops(); }
});

(async function init() {
  try { await loadConns(); } catch (e) { toast(e.message); }
  const saved = store.get('tabs', []);
  for (const s of saved) if (connOf(s.conn)) App.tabs.push(Object.assign({offset: 0, res: null, chain: [], order: null}, s));
  const act = store.get('activeTab', null);
  if (App.tabs.length) activate(App.tabs.some(t => t.id === act) ? act : App.tabs[0].id);
  else renderTabbar();
})();
