import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'lib'))


def git(directory, *args):
    return subprocess.check_output(['git', '-C', str(directory), *args], text=True).strip()


class QueueFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tower-ui 'test ")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / 'project'
        script = '''source "$1/tests/tower-fixtures.sh"
new_repo "$2"
new_project "$2"
new_card "$2" T001
new_card "$2" T002
'''
        subprocess.run(['bash', '-c', script, '_', str(ROOT), str(self.project)], check=True)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        self.env.pop('TOWER_PROJECT_DIR', None)
        self.env.pop('TOWER_TASK', None)
        self.module = __import__('tower_ui')
        self.queue = self.module.Queue(self.project, env=self.env)

    def path(self, task='T001'):
        return self.project / '.tower/tasks' / (task + '-test.md')

    def edit(self, old, new, task='T001'):
        path = self.path(task)
        path.write_text(path.read_text().replace(old, new))

    def card(self, task='T001'):
        return next(card for card in self.queue.snapshot()['cards'] if card['id'] == task)

    def make_draft(self):
        self.edit('status: ready', 'status: draft')
        self.queue.git('commit', '-q', '--only', '-m', 'tower: draft T001', '--', str(self.path()))

    def fake_terminal(self):
        fake = Path(self.temp.name) / 'bin'
        fake.mkdir()
        terminal = fake / 'osascript'
        terminal.write_text('#!/bin/sh\nexit 0\n')
        terminal.chmod(0o755)
        self.queue.env['PATH'] = str(fake) + os.pathsep + self.env['PATH']
        self.env['PATH'] = self.queue.env['PATH']


class QueueTest(QueueFixture):
    def test_read_preserves_full_card_and_git_state(self):
        before = git(self.project / '.tower', 'status', '--porcelain')
        card = self.card()
        self.assertEqual(card['raw'], self.path().read_text())
        self.assertEqual(card['group'], 'ready')
        self.assertEqual(card['blocker'], '')
        self.assertEqual(git(self.project / '.tower', 'status', '--porcelain'), before)
        self.assertFalse((self.project / '.tower/.git/tower-dispatch.lock').exists())

    def test_dependency_waiting_and_missing_prompt_use_dispatch_checks(self):
        self.edit('depends_on: []', 'depends_on: [T002]')
        self.assertEqual(self.card()['group'], 'waiting')
        self.assertIn('T002', self.card()['blocker'])
        self.edit('status: ready', 'status: merged', 'T002')
        (self.project / '.tower/prompts/T001-prompt.md').unlink()
        self.assertIn('prompt', self.card()['blocker'])

    def test_active_ownership_prevents_dispatch(self):
        self.edit('src/T002.sh', 'src/T001.sh', 'T002')
        self.edit('status: ready', 'status: in-flight', 'T002')
        self.assertIn('overlap', self.card()['blocker'])
        self.assertEqual(self.card()['group'], 'waiting')

    def test_approval_commits_only_reviewed_card(self):
        self.make_draft()
        other = self.project / '.tower/unrelated.txt'
        other.write_text('keep staged\n')
        git(other.parent, 'add', 'unrelated.txt')
        self.queue.act('T001', 'approve', self.card()['revision'])
        self.assertIn('status: ready', self.path().read_text())
        self.assertEqual(git(other.parent, 'diff', '--cached', '--name-only'), 'unrelated.txt')
        self.assertEqual(git(other.parent, 'show', '--pretty=', '--name-only', 'HEAD'), 'tasks/T001-test.md')

    def test_stale_approval_rejects_card_and_prompt_changes(self):
        self.make_draft()
        revision = self.card()['revision']
        self.edit('Implement T001.', 'Changed scope.')
        with self.assertRaisesRegex(self.module.QueueError, 'changed'):
            self.queue.act('T001', 'approve', revision)
        revision = self.card()['revision']
        (self.project / '.tower/prompts/T001-prompt.md').write_text('Changed prompt')
        with self.assertRaisesRegex(self.module.QueueError, 'changed'):
            self.queue.act('T001', 'approve', revision)
        self.assertIn('status: draft', self.path().read_text())

    def test_lock_blocks_approval_without_changing_card(self):
        self.make_draft()
        lock = self.project / '.tower/.git/tower-dispatch.lock'
        lock.mkdir()
        before = self.path().read_bytes()
        with self.assertRaisesRegex(self.module.QueueError, 'lock'):
            self.queue.act('T001', 'approve', self.card()['revision'])
        self.assertEqual(self.path().read_bytes(), before)
        self.assertTrue(lock.is_dir())

    def test_failed_approval_commit_restores_draft(self):
        self.make_draft()
        hook = self.project / '.tower/.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        before = self.path().read_bytes()
        with self.assertRaises(self.module.QueueError):
            self.queue.act('T001', 'approve', self.card()['revision'])
        self.assertEqual(self.path().read_bytes(), before)
        self.assertEqual(git(hook.parents[2], 'diff', '--cached', '--name-only'), '')

    def test_dispatch_creates_real_worktree_and_preserves_other_staged_files(self):
        self.fake_terminal()
        other = self.project / '.tower/unrelated.txt'
        other.write_text('keep staged\n')
        git(other.parent, 'add', 'unrelated.txt')
        self.queue.act('T001', 'dispatch', self.card()['revision'])
        self.assertIn('status: in-flight', self.path().read_text())
        self.assertIn('tower/root/T001-test', git(self.project, 'worktree', 'list', '--porcelain'))
        self.assertEqual(git(other.parent, 'diff', '--cached', '--name-only'), 'unrelated.txt')

    def test_dispatch_rechecks_changed_revision_under_lock(self):
        self.fake_terminal()
        revision = self.card()['revision']
        self.edit('Implement T001.', 'Changed scope.')
        result = subprocess.run([str(ROOT / 'bin/tower-dispatch'), 'T001', '--expect-revision', revision],
                                cwd=self.project, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('changed', result.stderr)
        self.assertIn('status: ready', self.path().read_text())
        self.assertNotIn('tower/root/T001', git(self.project, 'worktree', 'list', '--porcelain'))

    def test_ids_cannot_escape_task_directory(self):
        with self.assertRaises(self.module.QueueError):
            self.queue.act('../T001', 'approve', '')

    def test_duplicate_ids_disable_actions(self):
        duplicate = self.path().with_name('T001-duplicate.md')
        duplicate.write_text(self.path().read_text())
        with self.assertRaisesRegex(self.module.QueueError, 'duplicate'):
            self.queue.snapshot()

    def test_empty_project_is_a_valid_queue(self):
        for card in self.path().parent.glob('*.md'):
            card.unlink()
        self.assertEqual(self.queue.snapshot()['cards'], [])

    def test_suffixed_task_ids_can_be_reviewed(self):
        path = self.path()
        path.write_text(path.read_text().replace('T001', 'T073a'))
        path.rename(path.with_name('T073a-test.md'))
        prompt = self.project / '.tower/prompts/T001-prompt.md'
        prompt.rename(prompt.with_name('T073a-prompt.md'))
        self.assertEqual(self.card('T073a')['group'], 'ready')

    def test_changed_dependency_rejects_dispatch_without_mutating_card(self):
        self.fake_terminal()
        self.edit('depends_on: []', 'depends_on: [T002]')
        self.edit('status: ready', 'status: merged', 'T002')
        revision = self.card()['revision']
        self.edit('status: merged', 'status: ready', 'T002')
        with self.assertRaisesRegex(self.module.QueueError, 'dependency T002'):
            self.queue.act('T001', 'dispatch', revision)
        self.assertIn('status: ready', self.path().read_text())

    def test_cached_readiness_changes_when_prompt_is_removed(self):
        self.assertEqual(self.card()['group'], 'ready')
        (self.project / '.tower/prompts/T001-prompt.md').unlink()
        self.assertEqual(self.card()['group'], 'waiting')

    def test_cached_readiness_changes_when_lock_appears_and_disappears(self):
        self.assertEqual(self.card()['group'], 'ready')
        self.queue.lock.mkdir()
        self.assertEqual(self.card()['group'], 'waiting')
        self.queue.lock.rmdir()
        self.assertEqual(self.card()['group'], 'ready')

    def test_existing_branch_requires_inspection(self):
        self.assertEqual(self.card()['group'], 'ready')
        git(self.project, 'branch', 'tower/root/T001-test')
        self.assertEqual(self.card()['group'], 'waiting')
        self.assertIn('branch', self.card()['blocker'])

    def test_terminal_launch_failure_reports_in_flight_state(self):
        self.fake_terminal()
        (Path(self.temp.name) / 'bin/osascript').write_text('#!/bin/sh\nexit 1\n')
        with self.assertRaisesRegex(self.module.QueueError, 'doctor'):
            self.queue.act('T001', 'dispatch', self.card()['revision'])
        self.assertIn('status: in-flight', self.path().read_text())

    def test_linked_monorepo_worktree_uses_canonical_state(self):
        subproject = self.project / 'services/api'
        script = 'source "$1/tests/tower-fixtures.sh"; new_project "$2"; new_card "$2" T009'
        subprocess.run(['bash', '-c', script, '_', str(ROOT), str(subproject)], check=True)
        linked = Path(self.temp.name) / 'linked'
        git(self.project, 'worktree', 'add', '-q', '-b', 'linked', str(linked))
        linked_project = linked / 'services/api'
        linked_project.mkdir(parents=True)
        (linked_project / '.tower').symlink_to(subproject / '.tower')
        queue = self.module.Queue(linked_project, env=self.env)
        self.assertEqual(queue.project, subproject.resolve())
        self.assertEqual(queue.snapshot()['cards'][0]['group'], 'ready')

    def test_tracked_state_allows_approval_but_requires_cli_dispatch(self):
        tracked = Path(self.temp.name) / 'tracked'
        script = 'source "$1/tests/tower-fixtures.sh"; new_repo "$2"'
        subprocess.run(['bash', '-c', script, '_', str(ROOT), str(tracked)], check=True)
        tasks = tracked / '.tower/tasks'
        tasks.mkdir(parents=True)
        card = tasks / 'T001-test.md'
        card.write_text(self.path().read_text().replace('status: ready', 'status: draft'))
        prompts = tracked / '.tower/prompts'
        prompts.mkdir()
        (prompts / 'T001-prompt.md').write_text('Implement T001.')
        queue = self.module.Queue(tracked, env=self.env)
        queue.git('add', '.tower')
        queue.git('commit', '-q', '-m', 'tower: draft')
        revision = queue.snapshot()['cards'][0]['revision']
        queue.act('T001', 'approve', revision)
        self.assertIn('status: ready', card.read_text())
        self.assertIn('--in-place', queue.snapshot()['cards'][0]['blocker'])

    def test_symlink_card_is_not_editable_through_queue(self):
        original = self.path()
        outside = Path(self.temp.name) / 'outside.md'
        original.rename(outside)
        original.symlink_to(outside)
        with self.assertRaisesRegex(self.module.QueueError, 'regular files'):
            self.queue.snapshot()


class CommentTest(QueueFixture):
    def post(self, text='Please clarify the acceptance criteria.', comment_id='11111111-1111-4111-8111-111111111111'):
        return self.queue.comment('T001', self.card()['revision'], comment_id, text)

    def test_comment_is_persisted_without_changing_card_or_other_staged_files(self):
        card = self.path().read_bytes()
        other = self.queue.state / 'unrelated.txt'
        other.write_text('keep staged')
        git(self.queue.state, 'add', 'unrelated.txt')
        self.post('First line.\n\n<script>literal text</script>')
        comments = self.card()['comments']
        self.assertEqual(comments[0]['text'], 'First line.\n\n<script>literal text</script>')
        self.assertEqual(self.path().read_bytes(), card)
        self.assertEqual(git(self.queue.state, 'diff', '--cached', '--name-only'), 'unrelated.txt')
        self.assertEqual(git(self.queue.state, 'show', '--pretty=', '--name-only', 'HEAD'),
                         'comments/T001/11111111-1111-4111-8111-111111111111.md')
        self.assertEqual(self.module.Queue(self.project, env=self.env).snapshot()['cards'][0]['comments'], comments)

    def test_retried_comment_is_saved_once(self):
        self.post()
        head = git(self.queue.state, 'rev-parse', 'HEAD')
        self.post()
        self.assertEqual(len(self.card()['comments']), 1)
        self.assertEqual(git(self.queue.state, 'rev-parse', 'HEAD'), head)

    def test_comment_on_changed_card_is_rejected(self):
        revision = self.card()['revision']
        self.edit('Implement T001.', 'Changed scope.')
        with self.assertRaisesRegex(self.module.QueueError, 'changed'):
            self.queue.comment('T001', revision, '11111111-1111-4111-8111-111111111111', 'Feedback')
        self.assertEqual(self.card()['comments'], [])

    def test_blank_and_oversized_comments_are_rejected(self):
        for text in ['  \n ', 'x' * 10001]:
            with self.assertRaises(self.module.QueueError):
                self.post(text)
        self.assertEqual(self.card()['comments'], [])

    def test_failed_comment_commit_leaves_no_saved_comment(self):
        hook = self.queue.state / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\nexit 1\n')
        hook.chmod(0o755)
        with self.assertRaises(self.module.QueueError):
            self.post()
        self.assertEqual(self.card()['comments'], [])
        self.assertEqual(git(self.queue.state, 'diff', '--cached', '--name-only'), '')

    def test_retry_commits_a_comment_left_by_an_interrupted_save(self):
        revision = self.card()['revision']
        directory = self.queue.state / 'comments/T001'
        directory.mkdir(parents=True)
        comment = directory / '11111111-1111-4111-8111-111111111111.md'
        comment.write_text('---\nauthor: owner\ncreated_at: 2026-09-09T12:00:00+00:00\n'
                           + 'card_revision: ' + revision + '\n---\nFeedback')
        self.post('Feedback')
        self.assertEqual(git(self.queue.state, 'show', '--pretty=', '--name-only', 'HEAD'),
                         'comments/T001/11111111-1111-4111-8111-111111111111.md')
        self.assertEqual(len(self.card()['comments']), 1)

    def test_symlink_comment_directory_is_rejected(self):
        outside = Path(self.temp.name) / 'outside'
        outside.mkdir()
        (self.queue.state / 'comments').symlink_to(outside)
        with self.assertRaisesRegex(self.module.QueueError, 'symlinks'):
            self.post()
        self.assertEqual(list(outside.iterdir()), [])

    def test_comment_path_cannot_escape_state(self):
        with self.assertRaises(self.module.QueueError):
            self.post(comment_id='../outside')

    def test_comments_refresh_independently_of_card_revision(self):
        revision = self.card()['revision']
        self.post('First')
        self.post('Second', '22222222-2222-4222-8222-222222222222')
        self.assertEqual([item['text'] for item in self.card()['comments']], ['First', 'Second'])
        self.assertEqual(self.card()['revision'], revision)


class ServerTest(QueueFixture):
    def setUp(self):
        super().setUp()
        server_module = __import__('tower_ui_server')
        self.server = server_module.create_server(self.queue, 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=10)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def headers(self):
        return {'X-Tower-Token': self.server.token, 'Content-Type': 'application/json',
                'Origin': 'http://127.0.0.1:' + str(self.server.server_port)}

    def test_api_requires_session_token_and_rejects_foreign_origin(self):
        self.assertEqual(self.request('GET', '/api/cards')[0], 403)
        self.assertEqual(self.request('GET', '/api/cards', headers=self.headers())[0], 200)
        headers = dict(self.headers(), Origin='https://unrelated.example')
        self.assertEqual(self.request('GET', '/api/cards', headers=headers)[0], 403)
        headers = dict(self.headers(), Host='unrelated.example')
        self.assertEqual(self.request('GET', '/api/cards', headers=headers)[0], 403)

    def test_http_approval_and_repeat_click(self):
        self.make_draft()
        body = json.dumps({'id': 'T001', 'action': 'approve', 'revision': self.card()['revision']})
        self.assertEqual(self.request('POST', '/api/action', body, self.headers())[0], 200)
        self.assertEqual(self.request('POST', '/api/action', body, self.headers())[0], 409)

    def test_comment_endpoint_requires_token_and_persists_feedback(self):
        body = json.dumps({'id': 'T001', 'revision': self.card()['revision'],
                           'comment_id': '11111111-1111-4111-8111-111111111111', 'text': 'Clarify scope.'})
        self.assertEqual(self.request('POST', '/api/comment', body)[0], 403)
        self.assertEqual(self.request('POST', '/api/comment', body, self.headers())[0], 200)
        self.assertEqual(self.card()['comments'][0]['text'], 'Clarify scope.')
        self.assertEqual(self.request('POST', '/api/comment', '{}', self.headers())[0], 400)

    def test_malformed_actions_do_not_mutate_state(self):
        before = self.path().read_bytes()
        for body in ['[]', '{', '{}', '{"id":"../T001","action":"dispatch","revision":"x"}']:
            self.assertIn(self.request('POST', '/api/action', body, self.headers())[0], (400, 409))
        self.assertEqual(self.path().read_bytes(), before)
        self.assertEqual(self.request('GET', '/../.tower/tasks/T001-test.md')[0], 404)


if __name__ == '__main__':
    if not (ROOT / 'bin/tower-ui').exists():
        sys.exit('FAIL: tower-ui command is missing')
    unittest.main()
