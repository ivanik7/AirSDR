# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise release shell steps with fake artifacts and a recording gh client."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / '.github/workflows/ci.yml').read_text()


def step_script(name):
    step = WORKFLOW.split('      - name: ' + name + '\n', 1)[1]
    lines = step.split('        run: |\n', 1)[1].splitlines()
    script = []
    for line in lines:
        if line and not line.startswith('          '):
            break
        script.append(line[10:])
    return re.sub(r'\$\{\{.*?\}\}', '1.0.0-test', '\n'.join(script))


def nightly_runs(results, cancelled=False, event='push', ref='refs/heads/master'):
    job = WORKFLOW.split('\n  nightly:\n', 1)[1]
    expression = job.split('    if: >-\n', 1)[1].split('    needs:', 1)[0].strip()
    expression = expression.replace('!cancelled()', str(not cancelled))
    expression = expression.replace('github.event_name', repr(event)).replace('github.ref', repr(ref))
    expression = re.sub(r'needs\.([\w-]+)\.result', lambda m: repr(results[m[1]]), expression)
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    return eval(' '.join(expression.split()), {'__builtins__': {}}, {})


class ReleaseWorkflowTest(unittest.TestCase):
    def test_each_platform_may_fail_without_blocking_nightly(self):
        for failed in ['android', 'linux', 'linux-install', 'macos', 'windows']:
            with self.subTest(failed=failed):
                results = dict.fromkeys(['test', 'android', 'linux', 'linux-install', 'macos', 'windows'], 'success')
                results[failed] = 'failure'
                if failed == 'linux':
                    results['linux-install'] = 'skipped'
                self.assertTrue(nightly_runs(results))

    def test_no_successful_build_keeps_previous_nightly(self):
        results = dict.fromkeys(['test', 'android', 'linux', 'linux-install', 'macos', 'windows'], 'failure')
        results['test'] = 'success'
        self.assertFalse(nightly_runs(results))

    def test_cancelled_or_non_master_runs_do_not_publish(self):
        results = dict.fromkeys(['test', 'android', 'linux', 'linux-install', 'macos', 'windows'], 'success')
        self.assertFalse(nightly_runs(results, cancelled=True))
        self.assertFalse(nightly_runs(results, event='pull_request'))
        self.assertFalse(nightly_runs(results, ref='refs/heads/feature'))

    def test_empty_artifact_set_does_not_delete_previous_nightly(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'dist').mkdir()
            (root / 'tool').symlink_to(ROOT / 'tool', target_is_directory=True)
            (root / 'bin').mkdir()
            gh = root / 'bin/gh'
            gh.write_text('#!/bin/sh\ntouch "$RECORDED_CALL"\n')
            gh.chmod(0o755)
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                       RUNNER_TEMP=tmp, RECORDED_CALL=str(root / 'called'))
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c',
                                     step_script('Replace nightly pre-release')],
                                    cwd=root, env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('no release files found', result.stderr)
            self.assertFalse((root / 'called').exists())

    def test_release_steps_upload_only_packages_with_partial_artifacts(self):
        for name in ['Create release', 'Replace nightly pre-release']:
            with self.subTest(step=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / 'dist').mkdir()
                (root / 'dist/AirSDR-1.0.0-android-arm64-v8a.apk').write_text('apk')
                (root / 'assets/fonts').mkdir(parents=True)
                (root / 'assets/fonts/font.ttf').write_text('font')
                (root / 'tool').symlink_to(ROOT / 'tool', target_is_directory=True)
                (root / 'bin').mkdir()
                gh = root / 'bin/gh'
                gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1:3] == ['release', 'create']:
    assets = []
    for arg in sys.argv[4:]:
        if arg.startswith('-'):
            break
        if not pathlib.Path(arg).is_file():
            sys.exit('Upload argument is not a file: ' + arg)
        assets.append(arg)
    if not assets:
        sys.exit('No assets')
    pathlib.Path(os.environ['RECORDED_ASSETS']).write_text(json.dumps(assets))
''')
                gh.chmod(0o755)
                env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                           RUNNER_TEMP=tmp, GITHUB_REPOSITORY='test/AirSDR', GITHUB_SHA='abc123',
                           GITHUB_REF_NAME='v1.0.0', RECORDED_ASSETS=str(root / 'recorded.json'))
                result = subprocess.run(['bash', '-euo', 'pipefail', '-c', step_script(name)], cwd=root,
                                        env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                assets = json.loads((root / 'recorded.json').read_text())
                self.assertEqual([Path(p).name for p in assets], ['AirSDR-android-arm64-v8a.apk'])
                self.assertEqual((root / 'assets/fonts/font.ttf').read_text(), 'font')


if __name__ == '__main__':
    unittest.main()
