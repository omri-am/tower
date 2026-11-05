'use strict';

const vm = require('vm');
const fs = require('fs');
const assert = require('assert');

function loadMarkdownRenderer() {
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
    addEventListener() {}
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
    activeElement: null,
  };
  const context = vm.createContext({
    document, location: { hash: '', pathname: '/' },
    sessionStorage: { getItem: () => null, setItem() {} },
    history: { replaceState() {} }, window: { addEventListener() {} },
    setInterval() {}, fetch: () => new Promise(() => {}),
  });
  vm.runInContext(fs.readFileSync(__dirname + '/../web/tower.js', 'utf8'), context);
  return context.markdown;
}

function blocksOf(container) {
  return container.children.map((node) => {
    const tag = node.tagName.toLowerCase();
    if (tag === 'ul') return ['ul', node.children.map((item) => item.textContent)];
    if (tag === 'ol') return ['ol', node.getAttribute('start'), node.children.map((item) => item.textContent)];
    return [tag, node.textContent];
  });
}

module.exports = { loadMarkdownRenderer, blocksOf };

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
  if (failed) process.exitCode = 1;
}
