"""Throwaway T031 launch-hook probe. Run only from a mktemp -d directory.

For live runs set CODEX_BIN=/Users/omriam/.codex/packages/standalone/releases/0.159.3-aarch64-apple-darwin/bin/codex.
"""
import json
import shlex
import sys
import time

from common import guard, parser


def main():
    options = parser('Launch notify and hook probe')
    options.add_argument('mode', choices=('notify', 'hook'))
    args = options.parse_args()
    run = guard('p6_launch_hooks_' + args.mode, args.deadline)
    try:
        extra = ()
        if args.mode == 'hook':
            capture = run.cwd / 'record_hook.py'
            capture.write_text('import json, os, pathlib, sys, time\n'
                               'payload = sys.stdin.read()\n'
                               'with pathlib.Path("hook-session-start.jsonl").open("a") as out:\n'
                               '    out.write(json.dumps({"time": time.time(), "payload": payload, '
                               '"environment": dict(os.environ)}) + "\\n")\n'
                               '    out.flush()\n')
            command = shlex.join([sys.executable, str(capture)])
            # CLI -c parses the right side as TOML; the hook source stays in scratch.
            config = 'hooks.SessionStart=[{matcher="startup",hooks=[{type="command",command=' + json.dumps(command) + '}]}]'
            extra = ('-c', config)
            run.log('hook_config', {'config': config, 'feature_hooks_default': True,
                                    'trust': 'Do not answer a hook trust prompt'})
        launched = time.time()
        run.log('launch_time', launched)
        prompt = 'Reply HOOK_READY. No tools.'
        run.launch(prompt, extra)
        event = run.wait_marker('HOOK_READY', prompt)
        notified = event.get('time')
        thread = run.thread_id(event)
        run.log('notify_result', {'thread_id': thread, 'launch_time': launched,
                                  'notify_time': notified,
                                  'payload_keys': sorted(event.get('payload', {}))})
        if args.mode == 'hook':
            file = run.cwd / 'hook-session-start.jsonl'
            if not file.exists():
                run.log('hook_result', {'fired': False, 'possible_untrusted_skip': True})
            else:
                events = [json.loads(line) for line in file.read_text().splitlines()]
                summary = []
                for item in events:
                    try:
                        payload = json.loads(item['payload'])
                    except json.JSONDecodeError:
                        payload = {'raw': item['payload']}
                    summary.append({'time': item['time'], 'payload': payload,
                                    'environment': item['environment'],
                                    'matches_notify': payload.get('session_id') == thread,
                                    'before_notify': item['time'] < notified})
                run.log('hook_result', {'fired': True, 'events': summary})
    finally:
        run.stop()


if __name__ == '__main__':
    main()
