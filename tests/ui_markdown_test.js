'use strict';

const vm = require('vm');
const fs = require('fs');
const assert = require('assert');

function loadTowerContext({ fetch, storage = new Map() } = {}) {
  class Element {
    constructor(tagName) {
      this.tagName = tagName.toUpperCase();
      this.children = [];
      this.value = '';
      this.dataset = {};
      this.className = '';
      this.hidden = false;
      this.disabled = false;
      this.classList = { toggle() {} };
      this.attributes = new Map();
    }
    addEventListener(name, listener) { (this.listeners ??= new Map()).set(name, listener); }
    dispatch(name) { this.listeners.get(name)(); }
    append(...nodes) {
      for (const node of nodes) {
        if (node.tagName === '#FRAGMENT') this.children.push(...node.children.splice(0));
        else this.children.push(node);
      }
    }
    replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
    setAttribute(name, value) { this.attributes.set(name, String(value)); }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
    querySelector() { return null; }
    querySelectorAll() { return []; }
    focus() {}
    close() { this.open = false; }
    showModal() { this.open = true; }
    get textContent() { return this.children.map((child) => child.textContent).join(''); }
    set textContent(text) { this.children = [{ textContent: String(text) }]; }
  }
  const elements = new Map();
  const getElement = (id) => {
    if (!elements.has(id)) elements.set(id, new Element('div'));
    return elements.get(id);
  };
  const document = {
    getElementById: getElement,
    querySelector: getElement,
    createElement: (tag) => new Element(tag),
    createTextNode: (text) => ({ textContent: text }),
    createDocumentFragment: () => new Element('#fragment'),
    addEventListener() {},
    querySelectorAll: () => [],
    activeElement: null,
  };
  getElement('filter').value = 'queue';
  const context = vm.createContext({
    document, location: { hash: '', pathname: '/' },
    sessionStorage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
    history: { replaceState() {} }, window: { addEventListener() {} },
    setInterval() {}, fetch: fetch || (() => new Promise(() => {})),
  });
  vm.runInContext(fs.readFileSync(__dirname + '/../web/tower.js', 'utf8'), context);
  return { context, elements, storage };
}

function loadMarkdownRenderer() { return loadTowerContext().context.markdown; }

function itemTexts(list) {
  return list.children.map((item) => {
    assert.strictEqual(item.tagName, 'LI', `<${list.tagName.toLowerCase()}> holds <${item.tagName.toLowerCase()}>`);
    return item.textContent;
  });
}

function blocksOf(container) {
  return container.children.map((node) => {
    const tag = node.tagName.toLowerCase();
    if (tag === 'ul') return ['ul', itemTexts(node)];
    if (tag === 'ol') return ['ol', node.getAttribute('start'), itemTexts(node)];
    return [tag, node.textContent];
  });
}

module.exports = { loadMarkdownRenderer, loadTowerContext, blocksOf };

function descendants(node, className) {
  return (node.children || []).flatMap((child) => [
    ...(child.className?.split(' ').includes(className) ? [child] : []),
    ...descendants(child, className),
  ]);
}

function card(id, track, group = 'ready', title = id) {
  const fields = { id, title, status: group, ...(track === undefined ? {} : { track }) };
  return { id, title, fields, status: group, group, raw: `${id}\n${title}`, body: '',
    revision: id, blocker: '', comments: [] };
}

async function trackChecks() {
  const names = ['autonomy', 'card-lifecycle', 'inbox', 'linux', 'roles', 'tracks'];
  const tracks = names.map((name) => ({ name, title: `Title ${name}`, scope: `Scope ${name}`, problem: '' }));
  tracks[1].problem = 'Missing scope.';
  const unsafeTitle = '<img src=x onerror=alert(1)>';
  const response = { project: 'Project', path: '/project', tracks, cards: [
    card('T001', 'autonomy', 'ready', unsafeTitle), card('T002', 'tracks'),
    card('T003', 'missing'), card('T004'), card('T005', 'autonomy', 'active'),
    card('T006', 'card-lifecycle'),
  ] };
  const storage = new Map([['tower-track-filter', 'autonomy']]);
  const { context, elements } = loadTowerContext({ storage, fetch: async () => ({ ok: true, json: async () => response }) });
  await new Promise(setImmediate);
  const get = (id) => elements.get(id);
  const ids = () => [...context.visibleCards()].map((entry) => entry.id);
  const filter = get('track-filter');
  assert.strictEqual(filter.value, 'autonomy', 'stored filter loads after options');
  assert.deepStrictEqual(filter.children.map((option) => [option.value, option.textContent]), [
    ['', 'All tracks'], ...tracks.map((track) => [track.name, track.title]),
    ['missing', 'missing (no charter)'], ['-', 'No track'],
  ]);
  assert.deepStrictEqual(ids(), ['T001']);
  const firstOption = filter.children[0];
  await context.refresh();
  assert.strictEqual(filter.children[0], firstOption, 'unchanged options keep their nodes');

  const known = context.trackChip('autonomy');
  assert.strictEqual(known.textContent, 'Title autonomy');
  assert.strictEqual(known.className, 'track-chip track-color-0');
  assert.strictEqual(known.title, 'Scope autonomy');
  assert.strictEqual(context.trackChip('autonomy').className, known.className);
  assert.strictEqual(new Set(names.map((name) => context.trackChip(name).className)).size, 6);
  assert.strictEqual(context.trackChip(undefined), null);
  const unknown = context.trackChip('missing');
  assert.strictEqual(unknown.className, 'track-chip track-unknown');
  assert.strictEqual(unknown.title, 'No charter .tower/tracks/missing.md. Run tower doctor.');
  const problem = context.trackChip('card-lifecycle');
  assert.ok(problem.className.includes('track-problem'));
  assert.strictEqual(problem.title, 'Charter .tower/tracks/card-lifecycle.md: Missing scope. Run tower tracks.');

  const row = context.cardRow(response.cards[0]);
  const title = descendants(row, 'row-title')[0];
  assert.strictEqual(title.children.length, 1);
  assert.strictEqual(title.children[0].textContent, unsafeTitle);
  assert.strictEqual(descendants(row, 'track-line').length, 1);
  assert.strictEqual(descendants(row, 'track-chip')[0].textContent, 'Title autonomy');
  assert.strictEqual(descendants(context.cardRow(response.cards[3]), 'track-chip').length, 0);
  context.setView('kanban');
  assert.strictEqual(descendants(context.cardRow(response.cards[0]), 'track-chip').length, 1);
  assert.strictEqual(filter.value, 'autonomy', 'both views share one track filter');

  get('filter').value = 'all';
  filter.value = '';
  assert.deepStrictEqual(ids(), ['T001', 'T002', 'T003', 'T004', 'T005', 'T006']);
  filter.value = 'autonomy';
  assert.deepStrictEqual(ids(), ['T001', 'T005']);
  filter.value = '-';
  assert.deepStrictEqual(ids(), ['T004']);
  filter.value = 'missing';
  assert.deepStrictEqual(ids(), ['T003']);
  get('filter').value = 'queue';
  filter.value = 'autonomy';
  assert.deepStrictEqual(ids(), ['T001']);
  get('search').value = 'Title autonomy';
  assert.deepStrictEqual(ids(), ['T001']);
  filter.value = '';
  assert.deepStrictEqual(ids(), ['T001']);
  get('search').value = 'absent';
  assert.deepStrictEqual(ids(), []);
  get('search').value = '';

  context.renderDetail(response.cards[0]);
  const detail = get('detail');
  assert.strictEqual(descendants(detail, 'track-chip')[0].textContent, 'Title autonomy');
  assert.strictEqual(descendants(detail, 'track-scope')[0].textContent, 'Scope autonomy');
  filter.value = 'missing';
  filter.dispatch('change');
  assert.strictEqual(storage.get('tower-track-filter'), 'missing');
  response.cards = response.cards.filter((entry) => entry.id !== 'T003');
  await context.refresh();
  assert.strictEqual(filter.value, '');
  assert.strictEqual(storage.get('tower-track-filter'), '');
  response.tracks[0].title = 'Autonomy renamed';
  await context.refresh();
  assert.strictEqual(filter.children[1].textContent, 'Autonomy renamed');
  assert.strictEqual(descendants(get('queue'), 'track-chip')[0].textContent, 'Autonomy renamed');
  console.log('  track chip, filter, detail, storage, and safe text checks passed');
}

if (require.main === module) {
  const markdown = loadMarkdownRenderer();
  const cases = [
    ['hard-wrapped paragraph, bullet list and numbered list', [
      'The harness proxy answers POST /api/ci/aria-messages with the stored messages of a test conversation:',
      "each message's id, role, time, text and whether it holds tool results.", '',
      '- **Gap 1:** add a third full-diff case: the last',
      '  reviewed commit is not an ancestor of the head.', '- second item', '',
      '1. first numbered step that is long enough to wrap onto',
      '   a second source line', '2. second numbered step',
    ], [
      ['p', "The harness proxy answers POST /api/ci/aria-messages with the stored messages of a test conversation: each message's id, role, time, text and whether it holds tool results."],
      ['ul', ['**Gap 1:** add a third full-diff case: the last reviewed commit is not an ancestor of the head.', 'second item']],
      ['ol', '1', ['first numbered step that is long enough to wrap onto a second source line', 'second numbered step']],
    ]],
    ['numbered list keeps its first number', ['3. third step', '4. fourth step'], [['ol', '3', ['third step', 'fourth step']]]],
    ['quote pair keeps its line break and joins no other line', ['Text before the quote', '> first quoted line', '> second quoted line', 'Text after the quote'], [['p', 'Text before the quote'], ['p', '> first quoted line\n> second quoted line'], ['p', 'Text after the quote']]],
    ['table keeps its line breaks', ['| Column | Value |', '|---|---|', '| a | 1 |'], [['p', '| Column | Value |\n|---|---|\n| a | 1 |']]],
    ['fenced block keeps its lines as written', ['```', '  indented   line', '- not a list item', '1. not a numbered item', '```'], [['pre', '  indented   line\n- not a list item\n1. not a numbered item']]],
    ['list types switch and unindented lines continue items', ['- bullet', 'continued', '7. numbered', 'also continued', '+ bullet again'], [['ul', ['bullet continued']], ['ol', '7', ['numbered also continued']], ['ul', ['bullet again']]]],
    ['blank line resets numbered list start', ['3. first', '', '9. next'], [['ol', '3', ['first']], ['ol', '9', ['next']]]],
    ['paragraph continuation loses its leading spaces', ['  first', '   second'], [['p', '  first second']]],
    ['mixed quote and table lines keep their source', ['  > quote', ' | table', 'after'], [['p', '  > quote\n | table'], ['p', 'after']]],
    ['indented heading continues a paragraph', ['first', '  # second'], [['p', 'first # second']]],
  ];
  let failed = 0;
  for (const [name, lines, expected] of cases) {
    try { assert.deepStrictEqual(blocksOf(markdown(lines.join('\n'))), expected); }
    catch (error) { failed++; console.error(`  FAIL ${name}: ${error.message}`); }
  }
  try {
    const paragraph = markdown('`code\n  span`').children[0];
    assert.deepStrictEqual(paragraph.children.filter((node) => node.tagName === 'CODE').map((node) => node.textContent), ['code span']);
  } catch (error) { failed++; console.error(`  FAIL code span crosses a source line: ${error.message}`); }
  console.log(`  ${cases.length + 1} checks, ${failed} failed`);
  trackChecks().catch((error) => { console.error(error); process.exitCode = 1; });
  if (failed) process.exitCode = 1;
}
