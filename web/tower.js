'use strict';

const $ = (id) => document.getElementById(id);
let token = location.hash.slice(1) || sessionStorage.getItem('tower-token') || '';
if (token) sessionStorage.setItem('tower-token', token);
history.replaceState(null, '', location.pathname);
let cards = [];
let selected = '';
let renderedRevision = '';
let busy = false;
let refreshing = false;
let connected = false;
let connectionError = false;
let queueView = '';
let actionView = '';
const commentDrafts = new Map();
let viewMode = 'queue';
const viewFilters = { queue: 'queue', kanban: 'all' };
const groups = { approval: 'Needs approval', ready: 'Ready to dispatch', waiting: 'Waiting', active: 'Active', done: 'Merged', invalid: 'Needs attention' };
const boardColumns = { approval: 'Needs approval', ready: 'Ready to dispatch', waiting: 'Waiting', 'in-flight': 'In flight', 'in-review': 'In review', done: 'Merged', invalid: 'Needs attention' };
const collapsedColumns = new Set(Object.keys(boardColumns).filter((column) => sessionStorage.getItem(`tower-fold-${column}`) === 'true'));
const statuses = { draft: 'Draft', ready: 'Ready', 'in-flight': 'In flight', 'in-review': 'In review', blocked: 'Blocked', merged: 'Merged' };

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

async function api(path, data) {
  const options = { headers: { 'X-Tower-Token': token } };
  if (data) {
    options.method = 'POST';
    options.headers['Content-Type'] = 'application/json';
    options.body = JSON.stringify(data);
  }
  const response = await fetch(path, options);
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'The request failed. Refresh and try again.');
  return result;
}

function visibleCards() {
  const query = $('search').value.toLocaleLowerCase().trim();
  return cards.filter((card) => {
    const included = $('filter').value === 'all' || !['active', 'done'].includes(card.group);
    return included && (card.id + '\n' + card.raw).toLocaleLowerCase().includes(query);
  });
}

function orderedCards() {
  const visible = visibleCards();
  return Object.keys(displayColumns()).flatMap((column) => visible.filter((card) => columnFor(card) === column && !(viewMode === 'kanban' && collapsedColumns.has(column))));
}

function displayColumns() {
  return viewMode === 'kanban' ? boardColumns : groups;
}

function columnFor(card) {
  return viewMode === 'kanban' && card.group === 'active' ? card.status : card.group;
}

function columnVisible(column, entries) {
  if (entries.length) return true;
  if (viewMode !== 'kanban' || column === 'invalid') return false;
  return $('filter').value === 'all' || !['in-flight', 'in-review', 'done'].includes(column);
}

function setView(mode) {
  viewFilters[viewMode] = $('filter').value;
  viewMode = mode;
  sessionStorage.setItem('tower-view', mode);
  $('filter').value = viewFilters[mode];
  const board = mode === 'kanban';
  const dialog = $('card-dialog');
  if (dialog.open) dialog.close();
  document.querySelector('.workspace').classList.toggle('kanban-view', board);
  $('view-queue').setAttribute('aria-pressed', String(!board));
  $('view-kanban').setAttribute('aria-pressed', String(board));
  document.querySelector('.queue-heading h1').textContent = board ? 'Task board' : 'Task queue';
  (board ? dialog : document.querySelector('.workspace')).append($('detail-panel'));
  renderQueue();
}

function openCardDialog() {
  if (viewMode !== 'kanban') return;
  const dialog = $('card-dialog');
  if (!dialog.open) dialog.showModal();
  $('close-card').focus();
}

function cardState(card) {
  return card.group === 'active' ? card.status : card.group;
}

function statusBadge(card) {
  const label = { approval: 'Needs approval', ready: 'Ready to dispatch', waiting: 'Waiting', done: 'Merged', invalid: 'Needs attention' }[card.group] || statuses[card.status];
  return element('span', label, `status-badge state-${cardState(card)}`);
}

function cardRow(card) {
  const button = element('button', undefined, 'card-row');
  button.type = 'button';
  button.dataset.id = card.id;
  button.setAttribute('aria-current', String(card.id === selected));
  const meta = element('span', undefined, 'row-meta');
  meta.append(element('span', card.id), statusBadge(card));
  button.append(meta, element('span', card.title || 'Untitled card', 'row-title'));
  if (card.blocker) button.append(element('span', card.blocker, 'row-reason'));
  if (viewMode === 'kanban' && card.comments.length) button.append(element('span', `${card.comments.length} ${card.comments.length === 1 ? 'comment' : 'comments'}`, 'row-comments'));
  button.addEventListener('click', () => selectCard(card.id));
  return button;
}

function columnHeading(column, label, count) {
  const heading = element('h2');
  const title = element('span', label);
  const total = element('span', String(count));
  if (viewMode !== 'kanban') { heading.append(title, total); return heading; }
  const button = element('button', undefined, 'column-toggle');
  button.type = 'button';
  button.dataset.columnToggle = column;
  button.setAttribute('aria-controls', `column-${column}`);
  button.setAttribute('aria-expanded', String(!collapsedColumns.has(column)));
  const arrow = element('span', collapsedColumns.has(column) ? '›' : '⌄', 'column-arrow');
  arrow.setAttribute('aria-hidden', 'true');
  button.append(arrow, title, total);
  button.addEventListener('click', () => {
    if (collapsedColumns.has(column)) collapsedColumns.delete(column);
    else collapsedColumns.add(column);
    sessionStorage.setItem(`tower-fold-${column}`, String(collapsedColumns.has(column)));
    renderQueue();
  });
  heading.append(button);
  return heading;
}

function cardColumn(column, label, entries) {
  const section = element('section', undefined, `group state-${column}`);
  section.setAttribute('aria-label', label);
  section.dataset.column = column;
  const folded = viewMode === 'kanban' && collapsedColumns.has(column);
  section.classList.toggle('collapsed', folded);
  const columnCards = element('div', undefined, 'column-cards');
  columnCards.id = `column-${column}`;
  columnCards.hidden = folded;
  columnCards.append(...entries.map(cardRow));
  if (!entries.length) columnCards.append(element('p', 'No cards', 'column-empty'));
  section.append(columnHeading(column, label, entries.length), columnCards);
  return section;
}

function renderQueue() {
  const focusedId = document.activeElement?.dataset.id;
  const focusedColumn = document.activeElement?.dataset.columnToggle;
  const visible = visibleCards();
  const view = JSON.stringify([visible, selected, viewMode, $('filter').value, [...collapsedColumns]]);
  if (view === queueView) return;
  queueView = view;
  const fragment = document.createDocumentFragment();
  for (const [group, label] of Object.entries(displayColumns())) {
    const entries = visible.filter((card) => columnFor(card) === group);
    if (!columnVisible(group, entries)) continue;
    fragment.append(cardColumn(group, label, entries));
  }
  if (!visible.length && viewMode !== 'kanban') fragment.append(element('p', cards.length ? 'No cards match this view. Try another search or show all cards.' : 'No cards yet. Ask your orchestrator to prepare draft cards for this project.', 'empty'));
  $('queue').replaceChildren(fragment);
  $('total').textContent = `${visible.length} ${visible.length === 1 ? 'card' : 'cards'}`;
  if (focusedId) focusRow(focusedId);
  if (focusedColumn) $('queue').querySelector(`[data-column-toggle="${focusedColumn}"]`)?.focus({ preventScroll: true });
}

function focusRow(id, reveal = false) {
  const button = [...$('queue').querySelectorAll('button')].find((row) => row.dataset.id === id);
  button?.focus({ preventScroll: true });
  if (reveal) button?.scrollIntoView({ block: 'nearest' });
}

function inline(text) {
  const fragment = document.createDocumentFragment();
  for (const part of text.split(/(`[^`]+`)/g)) {
    fragment.append(part.startsWith('`') && part.endsWith('`') ? element('code', part.slice(1, -1)) : document.createTextNode(part));
  }
  return fragment;
}

function flushParagraph(state) {
  if (state.paragraph.length) {
    const paragraph = element('p');
    paragraph.append(inline(state.paragraph.join('\n')));
    state.container.append(paragraph);
    state.paragraph = [];
  }
  state.list = null;
}

function appendMarkdownLine(state, line) {
  if (state.code !== null) {
    if (line.trim() === state.fence) {
      state.container.append(element('pre', state.code.join('\n')));
      state.code = null;
    } else state.code.push(line);
    return;
  }
  const fence = line.match(/^\s*(`{3,}|~{3,})/);
  if (fence) { flushParagraph(state); state.fence = fence[1]; state.code = []; return; }
  if (!line.trim()) { flushParagraph(state); return; }
  const heading = line.match(/^(#{1,6})\s+(.+)$/);
  if (heading) {
    flushParagraph(state);
    const node = element(`h${Math.max(2, heading[1].length)}`);
    node.append(inline(heading[2]));
    state.container.append(node);
    return;
  }
  const item = line.match(/^\s*[-*+]\s+(.*)$/);
  if (item) {
    if (!state.list) { flushParagraph(state); state.list = element('ul'); state.container.append(state.list); }
    const node = element('li');
    node.append(inline(item[1]));
    state.list.append(node);
    return;
  }
  state.list = null;
  state.paragraph.push(line);
}

function markdown(body) {
  const state = { container: element('div', undefined, 'card-body'), paragraph: [], code: null, fence: '', list: null };
  for (const line of body.split('\n')) appendMarkdownLine(state, line);
  flushParagraph(state);
  if (state.code !== null) state.container.append(element('pre', state.code.join('\n')));
  return state.container;
}

function renderDetail(card) {
  const header = element('header', undefined, 'card-header');
  const topline = element('div', undefined, 'card-topline');
  const commentsLink = element('button', `Comments (${card.comments.length})`, 'quiet');
  commentsLink.id = 'comments-link';
  commentsLink.addEventListener('click', () => $('comments').scrollIntoView({ block: 'start' }));
  topline.append(element('span', card.id, 'card-id'), statusBadge(card), commentsLink);
  header.append(topline, element('h2', card.title || 'Untitled card'));
  const metadata = element('dl', undefined, 'metadata');
  for (const [key, value] of Object.entries(card.fields)) {
    if (['id', 'title'].includes(key) || !value || value === '[]') continue;
    const entry = element('div');
    const label = key.replaceAll('_', ' ');
    const description = element('dd');
    if (key === 'status') description.append(statusBadge(card));
    else description.textContent = value;
    entry.append(element('dt', label[0].toUpperCase() + label.slice(1)), description);
    metadata.append(entry);
  }
  header.append(metadata);
  const source = element('details', undefined, 'source');
  source.append(element('summary', 'View exact card source'), element('pre', card.raw));
  $('detail').replaceChildren(header, markdown(card.body), source, commentSection(card));
  updateComments(card);
  renderedRevision = card.revision;
}

function commentSection(card) {
  const section = element('section', undefined, 'comments');
  section.id = 'comments';
  section.setAttribute('aria-label', 'Card comments');
  const heading = element('h2', 'Comments');
  const list = element('div');
  list.id = 'comment-list';
  list.setAttribute('aria-live', 'polite');
  const form = element('form', undefined, 'comment-form');
  const label = element('label', 'Add a comment');
  label.htmlFor = 'comment-text';
  const input = element('textarea');
  input.id = 'comment-text';
  input.rows = 4;
  input.maxLength = 10000;
  input.placeholder = 'Ask a question or leave feedback on this card…';
  input.value = commentDrafts.get(card.id)?.text || '';
  input.addEventListener('input', () => {
    commentDrafts.set(card.id, { text: input.value, id: crypto.randomUUID() });
    updateCommentButton();
  });
  const button = element('button', 'Post comment', 'primary');
  button.id = 'post-comment';
  button.type = 'submit';
  form.addEventListener('submit', (event) => { event.preventDefault(); postComment(card); });
  form.append(label, input, element('p', 'Saved with this card for the orchestrator to read. Comments do not change its status.', 'comment-help'), button);
  section.append(heading, list, form);
  return section;
}

function updateCommentButton() {
  if (!$('post-comment')) return;
  $('post-comment').disabled = busy || !connected || !$('comment-text').value.trim();
}

function updateComments(card) {
  const list = $('comment-list');
  if (!list) return;
  const signature = JSON.stringify(card.comments);
  if (list.dataset.content !== signature) {
    const comments = card.comments.map((comment) => {
      const article = element('article', undefined, 'comment');
      const date = new Date(comment.created_at);
      const when = Number.isNaN(date.getTime()) ? comment.created_at : date.toLocaleString();
      article.append(element('p', `Owner · ${when}`, 'comment-meta'), element('p', comment.text, 'comment-text'));
      return article;
    });
    list.replaceChildren(...(comments.length ? comments : [element('p', 'No comments yet.', 'comment-help')]));
    list.dataset.content = signature;
  }
  $('comments-link').textContent = `Comments (${card.comments.length})`;
  updateCommentButton();
}

async function postComment(card) {
  const draft = commentDrafts.get(card.id);
  if (busy || !draft?.text.trim()) return;
  busy = true;
  updateCommentButton();
  renderActions(card);
  try {
    const result = await api('/api/comment', { id: card.id, revision: card.revision, comment_id: draft.id, text: draft.text });
    if (commentDrafts.get(card.id) === draft) {
      commentDrafts.delete(card.id);
      if (selected === card.id) $('comment-text').value = '';
    }
    notice(result.message);
  } catch (error) {
    notice(`${card.id}: ${error.message} Your comment has not been cleared.`, true);
  } finally {
    busy = false;
    const message = $('notice').textContent;
    const failed = $('notice').className === 'error';
    await refresh();
    if (connected) notice(message, failed);
    updateCommentButton();
  }
}

function actionDescription(card) {
  if (card.status === 'draft') return 'Approve this scope to move the card to ready. Dispatch is a separate action.';
  if (card.blocker) return card.blocker;
  if (card.status === 'ready') return `Dispatch opens ${card.fields.vendor === 'codex' ? 'Codex' : 'Claude'} in Terminal with its own worktree.`;
  if (card.status === 'in-flight') return 'An implementor is assigned. If its launch failed, use tower doctor to inspect the task before resuming.';
  if (card.status === 'in-review') return 'The implementation is awaiting PR review and merge.';
  return 'This card has been merged.';
}

function renderActions(card) {
  const view = JSON.stringify([card, busy, connected]);
  if (view === actionView) return;
  actionView = view;
  $('actions').hidden = !card;
  if (!card) return;
  document.querySelectorAll('.card-header .status-badge').forEach((badge) => badge.replaceWith(statusBadge(card)));
  const description = connected ? actionDescription(card) : 'Connection lost. Reconnect before approving or dispatching.';
  const nodes = [element('span', description, 'action-copy')];
  const action = { draft: 'approve', ready: 'dispatch' }[card.status];
  if (action) {
    const button = element('button', busy ? 'Working…' : { approve: 'Approve card', dispatch: 'Dispatch card' }[action], 'primary');
    button.disabled = busy || !connected || Boolean(card.blocker);
    button.addEventListener('click', () => act(card, action));
    nodes.push(button);
  }
  $('actions').replaceChildren(...nodes);
}

function selectCard(id, resetScroll = true, openDetail = resetScroll) {
  const card = cards.find((entry) => entry.id === id);
  selected = card ? id : '';
  renderQueue();
  if (card) {
    renderDetail(card);
    if (resetScroll) document.querySelector('.detail-pane').scrollTop = 0;
  } else {
    $('detail').replaceChildren(element('p', 'Select a card to read its full scope and acceptance criteria.', 'empty'));
    renderedRevision = '';
  }
  renderActions(card);
  if (card && openDetail) openCardDialog();
}

function notice(message, error = false) {
  $('notice').textContent = message;
  $('notice').className = error ? 'error' : '';
  $('notice').hidden = false;
}

async function refresh() {
  if (refreshing || busy) return;
  refreshing = true;
  $('refresh').disabled = true;
  try {
    const result = await api('/api/cards');
    cards = result.cards;
    connected = true;
    if (connectionError) { $('notice').hidden = true; connectionError = false; }
    $('project').textContent = result.project;
    $('project').title = result.path;
    $('connection').textContent = 'Connected';
    renderQueue();
    const card = cards.find((entry) => entry.id === selected);
    if (card && card.revision !== renderedRevision) {
      notice(`${card.id} changed. Review the updated card before taking an action.`);
      renderDetail(card);
    }
    if (!card) selectCard(orderedCards()[0]?.id || '', false);
    else { renderActions(card); updateComments(card); }
  } catch (error) {
    connected = false;
    connectionError = true;
    $('connection').textContent = 'Disconnected';
    notice(`${error.message} Keep tower-ui running, then press Refresh.`, true);
    renderActions(cards.find((entry) => entry.id === selected));
    updateCommentButton();
  } finally {
    refreshing = false;
    $('refresh').disabled = false;
  }
}

async function act(card, action) {
  if (busy) return;
  busy = true;
  renderActions(card);
  try {
    const result = await api('/api/action', { id: card.id, action, revision: card.revision });
    notice(result.message);
    renderedRevision = '';
  } catch (error) {
    notice(error.message, true);
    renderedRevision = '';
  } finally {
    busy = false;
    // The action result already explains the change; retain it during refresh.
    const message = $('notice').textContent;
    const failed = $('notice').className === 'error';
    await refresh();
    if (connected) notice(message, failed);
  }
}

function filterChanged() {
  renderQueue();
  if (!visibleCards().some((card) => card.id === selected)) selectCard(orderedCards()[0]?.id || '', true, false);
}

$('view-queue').addEventListener('click', () => setView('queue'));
$('view-kanban').addEventListener('click', () => setView('kanban'));
$('close-card').addEventListener('click', () => $('card-dialog').close());
$('card-dialog').addEventListener('close', () => { if (viewMode === 'kanban') focusRow(selected, true); });
$('search').addEventListener('input', filterChanged);
$('filter').addEventListener('change', filterChanged);
$('refresh').addEventListener('click', refresh);
document.addEventListener('keydown', (event) => {
  if (event.ctrlKey || event.metaKey || event.altKey || /INPUT|TEXTAREA|SELECT/.test(event.target.tagName)) return;
  if (event.key === '/') { event.preventDefault(); $('search').focus(); return; }
  if (!['j', 'k'].includes(event.key)) return;
  event.preventDefault();
  const visible = orderedCards();
  const index = visible.findIndex((card) => card.id === selected);
  const next = visible[Math.max(0, Math.min(visible.length - 1, index + (event.key === 'j' ? 1 : -1)))];
  if (next) {
    selectCard(next.id);
    if (viewMode === 'queue') focusRow(next.id, true);
  }
});
window.addEventListener('hashchange', () => {
  if (!location.hash) return;
  token = location.hash.slice(1);
  sessionStorage.setItem('tower-token', token);
  history.replaceState(null, '', location.pathname);
  refresh();
});
setView(sessionStorage.getItem('tower-view') === 'kanban' ? 'kanban' : 'queue');
refresh();
setInterval(refresh, 5000);
