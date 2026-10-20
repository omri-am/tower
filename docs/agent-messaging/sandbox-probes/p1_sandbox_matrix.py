"""Throwaway T045 sandbox matrix probe."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lifetime-probes'))
from common import finish, guard, parser


TESTS = {
    'tower_help': ['tower', '--help'],
    'register_help': ['tower-register', '--help'],
    'python': ['python3', '-c', 'import sys; print(sys.executable); print(sys.base_prefix)'],
    'bash_git': ['/bin/bash', '-c', 'git rev-parse --show-toplevel'],
}
DENIAL_MARKER = '=== Sandbox denials ==='


def entries_from_args(values):
    entries = {}
    for value in values:
        label, path = value.split('=', 1)
        if not label or not Path(path).is_absolute() or label in entries:
            raise ValueError('expected a unique --entry LABEL=ABSPATH: ' + value)
        entries[label] = path
    return entries


def profile_override(run, entries):
    config = (Path.home() / '.codex' / 'config.toml').read_text()
    for section, expected in (
            ('[permissions.workspace.filesystem]', '":minimal" = "read"'),
            ('[permissions.workspace.filesystem.":project_roots"]', '"." = "write"')):
        parts = config.split(section + '\n', 1)
        body = [line for line in parts[1].split('\n[', 1)[0].splitlines()
                if line.strip()] if config.count(section + '\n') == 1 else []
        if body != [expected]:
            raise RuntimeError(section + ' changed: ' + repr(body))
    fields = ['":minimal"="read"', '":project_roots"={"."="write"}']
    fields.extend(json.dumps(path) + '="read"' for path in entries.values())
    override = 'permissions.workspace.filesystem={' + ', '.join(fields) + '}'
    run.log('profile_override', {'entries': entries, 'override': override})
    return override


def run_test(run, argv, env, override=None):
    cmd = argv if override is None else [
        run.codex, 'sandbox', '-P', 'workspace', '-c', 'check_for_update_on_startup=false',
        '-c', override, '-C', str(run.cwd), '--log-denials', '--', *argv]
    result = subprocess.run(cmd, cwd=str(run.cwd), env=env, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=60)
    lines = result.stderr.splitlines()
    return {'returncode': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr,
            'denials': lines[lines.index(DENIAL_MARKER) + 1:] if DENIAL_MARKER in lines else []}


def derived_path(name, path):
    found = shutil.which(name, path=path)
    hops = []
    current = Path(found) if found else None
    while current and current.is_symlink():
        target = os.readlink(current)
        hops.append({'path': str(current), 'target': target})
        current = Path(target) if os.path.isabs(target) else current.parent / target
    return {'which': found, 'realpath': os.path.realpath(found) if found else None,
            'symlink_hops': hops}


def main():
    options = parser('T045 sandbox matrix probe')
    options.add_argument('--tool-path', required=True)
    options.add_argument('--entry', action='append', default=[])
    args = options.parse_args()
    lib_dir = os.path.realpath(os.path.join(
        os.path.dirname(os.path.realpath(shutil.which('tower-register', path=args.tool_path))),
        '..', 'lib'))
    tests = dict(TESTS)
    tests['runtime_root'] = ['python3', '-c',
                             'import sys; sys.path.insert(0, sys.argv[1]); import tower_msg; print(tower_msg.runtime_root())',
                             lib_dir]
    entries = entries_from_args(args.entry)
    run, _ = guard('p1_sandbox_matrix', 900)
    try:
        env = {key: os.environ[key] for key in ('HOME', 'USER', 'LOGNAME', 'TERM', 'LANG')}
        env.update(SHELL='/bin/zsh', PATH=args.tool_path)
        run.log('environment', env)
        references = {}
        for name, argv in tests.items():
            references[name] = run_test(run, argv, env)
            run.log('reference', {'test': name, 'argv': argv, **references[name]})
        python_lines = references['python']['stdout'].splitlines()
        run.log('derived', {'tower_lib': lib_dir,
                            'tools': {name: derived_path(name, args.tool_path)
                                     for name in ('tower', 'tower-register', 'python3')},
                            'python': {name: {'value': value, 'realpath': os.path.realpath(value)}
                                       for name, value in zip(('sys.executable', 'sys.base_prefix'),
                                                              python_lines)}})
        cases = {'none': {}}
        cases['all'] = entries
        cases.update({'minus-' + label: {key: path for key, path in entries.items()
                                          if key != label} for label in entries})
        summary = {}
        for case, selected in cases.items():
            override = profile_override(run, selected)
            results = {}
            for name, argv in tests.items():
                results[name] = run_test(run, argv, env, override)
                run.log('test', {'case': case, 'test': name, 'argv': argv, **results[name]})
            matches = results['tower_help']['stdout'] == references['tower_help']['stdout']
            runtime_matches = (results['runtime_root']['stdout'] ==
                               references['runtime_root']['stdout'])
            bash_git_matches = (results['bash_git']['stdout'] ==
                                references['bash_git']['stdout'])
            verdict = 'pass' if matches and runtime_matches and bash_git_matches and all(
                item['returncode'] == 0 for item in results.values()) else 'fail'
            run.log('case_verdict', {'case': case,
                                     'returncodes': {name: item['returncode']
                                                     for name, item in results.items()},
                                     'tower_help_matches_reference': matches,
                                     'runtime_root_matches_reference': runtime_matches,
                                     'bash_git_matches_reference': bash_git_matches,
                                     'verdict': verdict})
            summary[case] = verdict
        run.log('summary', summary)
    except BaseException as error:
        run.log('exception', repr(error))
        raise
    finally:
        finish(run)


if __name__ == '__main__':
    main()
