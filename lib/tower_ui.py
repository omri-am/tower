"""Adapt Tower's files and commands for the local browser workspace."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
TASK_ID = re.compile(r'[Tt][0-9]+[A-Za-z0-9_-]*\Z')


class QueueError(Exception):
    pass


def run(args, cwd, env, data=None):
    return subprocess.run(args, cwd=cwd, env=env, input=data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def output(result):
    return (result.stdout + result.stderr).decode('utf-8', errors='replace').strip()


def fields_from(raw):
    lines = raw.splitlines(keepends=True)
    if not lines or lines[0].strip() != '---':
        raise QueueError('Card must start with frontmatter. Ask the orchestrator to repair it.')
    fields = {}
    for index, line in enumerate(lines[1:], 1):
        if line.strip() == '---':
            return fields, ''.join(lines[index + 1:])
        key, separator, value = line.partition(':')
        if not separator or key in fields:
            raise QueueError('Card has invalid or duplicate frontmatter fields.')
        fields[key] = value.strip().strip('"\'')
    raise QueueError('Card frontmatter is not closed.')


def replace_status(raw, status):
    frontmatter, body = raw.split('\n---', 1)
    frontmatter = re.sub(r'^status:.*$', 'status: ' + status, frontmatter, flags=re.MULTILINE)
    return frontmatter + '\n---' + body


def atomic_write(path, content):
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(content)
        os.chmod(temporary, path.stat().st_mode if path.exists() else 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Queue:
    def __init__(self, project, env=None):
        project = Path(project).resolve()
        self.project = (project / '.tower').resolve().parent if (project / '.tower').is_symlink() else project
        self.state = self.project / '.tower'
        self.tasks = self.state / 'tasks'
        self.env = dict(os.environ if env is None else env)
        self.env['TOWER_PROJECT_DIR'] = str(self.project)
        self.env['GIT_OPTIONAL_LOCKS'] = '0'
        self.env.pop('TOWER_TASK', None)
        self.repo = self.state if (self.state / '.git').is_dir() else self.project
        self.lock = Path(self.git('rev-parse', '--path-format=absolute', '--git-common-dir')) / 'tower-dispatch.lock'
        self.index = Path(self.git('rev-parse', '--path-format=absolute', '--git-path', 'index'))
        self.cached_key = None
        self.cached_snapshot = None

    def git(self, *args, data=None):
        result = run(['git', *args], self.repo, self.env, data)
        if result.returncode:
            raise QueueError(output(result) or 'Git operation failed. Check the project repository.')
        return result.stdout.decode().strip()

    def read_card(self, path):
        if path.is_symlink():
            raise QueueError('Task cards must be regular files: ' + path.name)
        raw = path.read_bytes()
        fields, body = fields_from(raw.decode('utf-8'))
        task = fields.get('id', '')
        if not TASK_ID.fullmatch(task):
            raise QueueError('Invalid task ID in ' + path.name)
        if not (path.name == task + '.md' or path.name.startswith(task + '-')):
            raise QueueError('Card filename does not match its ID: ' + path.name)
        prompt = self.state / 'prompts' / (task + '-prompt.md')
        prompt_bytes = prompt.read_bytes() if prompt.is_file() else b''
        revision = self.git('hash-object', '--stdin', data=raw + b'\0' + prompt_bytes)
        return {'id': task, 'title': fields.get('title', ''), 'status': fields.get('status', ''),
                'fields': fields, 'body': body, 'raw': raw.decode('utf-8'), 'revision': revision,
                'filename': path.name}

    def read_cards(self):
        cards = [self.read_card(path) for path in sorted(self.tasks.glob('*.md'))]
        ids = [card['id'] for card in cards]
        if len(ids) != len(set(ids)):
            raise QueueError('Found duplicate task IDs. Ask the orchestrator to repair the cards.')
        return cards

    def approval_blocker(self, card):
        path = self.tasks / card['filename']
        result = run(['git', 'ls-files', '--error-unmatch', '--', str(path)], self.repo, self.env)
        if result.returncode:
            return 'Ask the orchestrator to commit this draft before approval.'
        return ''

    def dispatch_blocker(self, card):
        result = run([str(ROOT / 'bin/tower-dispatch'), card['id'], '--print-only'], self.project, self.env)
        if result.returncode:
            return output(result).removeprefix('tower-dispatch: ')
        branch = card['fields'].get('branch') or 'tower/' + self.project_key() + '/' + Path(card['filename']).stem
        result = run(['git', 'show-ref', '--verify', '--quiet', 'refs/heads/' + branch], self.project, self.env)
        if result.returncode == 0:
            return 'The task branch already exists. Use tower doctor to inspect it before dispatching.'
        return ''

    def project_key(self):
        result = run(['git', 'rev-parse', '--show-toplevel'], self.project, self.env)
        root = Path(result.stdout.decode().strip())
        return 'root' if root == self.project else 'projects/' + str(self.project.relative_to(root))

    def classify(self, card):
        status = card['status']
        group = {'draft': 'approval', 'ready': 'ready', 'blocked': 'waiting',
                 'in-flight': 'active', 'in-review': 'active', 'merged': 'done'}.get(status, 'invalid')
        blocker = ''
        if status == 'draft':
            blocker = self.approval_blocker(card)
        if status == 'ready':
            blocker = self.dispatch_blocker(card)
        if status == 'blocked':
            blocker = 'Blocked by the implementor. Review the card and handoff with the orchestrator.'
        if group == 'invalid':
            blocker = 'Unknown card status. Ask the orchestrator to repair it.'
        if self.lock.exists() and status in ('draft', 'ready'):
            blocker = 'Another action holds the dispatch lock. Retry when it finishes; use tower doctor if it persists.'
        if status == 'ready' and blocker:
            group = 'waiting'
        return dict(card, group=group, blocker=blocker)

    def snapshot_key(self, cards):
        refs = run(['git', 'for-each-ref', '--format=%(refname)', 'refs/heads'], self.project, self.env)
        index_time = self.index.stat().st_mtime_ns if self.index.exists() else None
        revisions = tuple((card['filename'], card['revision']) for card in cards)
        return revisions, refs.stdout, self.lock.exists(), index_time

    def snapshot(self):
        cards = self.read_cards()
        key = self.snapshot_key(cards)
        if key != self.cached_key:
            with ThreadPoolExecutor(max_workers=4) as checks:
                classified = list(checks.map(self.classify, cards))
            self.cached_snapshot = {'project': self.project.name, 'path': str(self.project),
                                    'cards': classified}
            self.cached_key = key
        return dict(self.cached_snapshot, cards=[dict(card, comments=self.read_comments(card['id']))
                                                for card in self.cached_snapshot['cards']])

    def comments_directory(self, task):
        directory = self.state / 'comments' / task
        if directory.parent.is_symlink() or directory.is_symlink():
            raise QueueError('Comment directories must not be symlinks.')
        return directory

    def read_comments(self, task):
        comments = []
        for path in self.comments_directory(task).glob('*.md'):
            if path.is_symlink():
                raise QueueError('Comments must be regular files.')
            fields, body = fields_from(path.read_text(encoding='utf-8'))
            comments.append({'id': path.stem, 'created_at': fields.get('created_at', ''),
                             'revision': fields.get('card_revision', ''), 'text': body})
        return sorted(comments, key=lambda item: (item['created_at'], item['id']))

    def comment(self, task, revision, comment_id, text):
        try:
            if str(uuid.UUID(comment_id)) != comment_id:
                raise ValueError()
        except (ValueError, AttributeError):
            raise QueueError('Invalid comment ID.') from None
        text = text.strip()
        if not 1 <= len(text) <= 10000:
            raise QueueError('Write a comment between 1 and 10,000 characters.')
        with self.action_lock():
            self.find_card(task, revision)
            directory = self.comments_directory(task)
            directory.mkdir(parents=True, exist_ok=True)
            existing = next((item for item in self.read_comments(task) if item['id'] == comment_id), None)
            if existing:
                if existing['text'] != text or existing['revision'] != revision:
                    raise QueueError('This comment ID is already in use.')
                self.commit_comment(directory / (comment_id + '.md'), None, task)
                return {'message': task + ' comment saved.'}
            path = directory / (comment_id + '.md')
            created = datetime.now(timezone.utc).isoformat()
            content = f'---\nauthor: owner\ncreated_at: {created}\ncard_revision: {revision}\n---\n{text}'
            self.commit_comment(path, content, task)
        return {'message': task + ' comment saved. Card status is unchanged.'}

    def commit_comment(self, path, content, task):
        created = not path.exists()
        if created:
            atomic_write(path, content.encode('utf-8'))
        try:
            self.git('add', '--', str(path))
            unchanged = run(['git', 'diff', 'HEAD', '--quiet', '--', str(path)], self.repo, self.env)
            if unchanged.returncode == 0:
                return
            self.git('commit', '-q', '--only', '-m', 'tower: comment on ' + task, '--', str(path))
        except QueueError:
            if created:
                self.git('update-index', '--force-remove', '--', str(path))
                path.unlink()
            raise

    def find_card(self, task, revision):
        if not isinstance(task, str) or not TASK_ID.fullmatch(task):
            raise QueueError('Invalid task ID.')
        matches = [card for card in self.read_cards() if card['id'] == task]
        if not matches:
            raise QueueError('Card no longer exists. Refresh the queue.')
        card = matches[0]
        if card['revision'] != revision:
            raise QueueError('Card or prompt changed. Refresh and review before taking an action.')
        return card

    @contextmanager
    def action_lock(self):
        try:
            self.lock.mkdir()
        except FileExistsError:
            raise QueueError('The dispatch lock is held. Retry when the other action finishes.') from None
        try:
            yield
        finally:
            self.lock.rmdir()

    def approve(self, task, revision):
        with self.action_lock():
            card = self.find_card(task, revision)
            if card['status'] != 'draft':
                raise QueueError('Only draft cards can be approved. Refresh the queue.')
            blocker = self.approval_blocker(card)
            if blocker:
                raise QueueError(blocker)
            self.commit_approval(card)
        return {'message': task + ' approved. It is now ready; dispatch it when its prerequisites are complete.'}

    def commit_approval(self, card):
        path = self.tasks / card['filename']
        before = card['raw'].encode('utf-8')
        approved = replace_status(card['raw'], 'ready').encode('utf-8')
        atomic_write(path, approved)
        try:
            unchanged = run(['git', 'diff', 'HEAD', '--quiet', '--', str(path)], self.repo, self.env)
            if unchanged.returncode == 0:
                return
            self.git('commit', '-q', '--only', '-m', 'tower: approve ' + card['id'], '--', str(path))
        except QueueError:
            if path.read_bytes() == approved:
                atomic_write(path, before)
            raise

    def dispatch(self, task, revision):
        card = self.find_card(task, revision)
        if card['status'] != 'ready':
            raise QueueError('Only ready cards can be dispatched. Refresh the queue.')
        result = run([str(ROOT / 'bin/tower-dispatch'), task, '--expect-revision', revision], self.project, self.env)
        if result.returncode:
            raise QueueError(output(result) + '\nRefresh the queue. If the card is now in flight, inspect it with tower doctor before resuming.')
        return {'message': output(result)}

    def act(self, task, action, revision):
        handler = {'approve': self.approve, 'dispatch': self.dispatch}.get(action)
        if handler is None:
            raise QueueError('Unknown action. Use Approve card or Dispatch card.')
        return handler(task, revision)
