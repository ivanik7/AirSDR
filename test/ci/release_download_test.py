# SPDX-License-Identifier: GPL-3.0-or-later
"""Release/nightly artifact download regression.

Replays the artifacts the CI build jobs upload through the
actions/download-artifact@v8 steps of the `release` and `nightly` jobs, then
runs their real publish shell step with a recording gh client.

The download emulation follows actions/toolkit's artifact download: the
server returns one blob per artifact. An upload-artifact default artifact is
a zip of the uploaded files; an `archive: false` artifact is the uploaded
file itself, named after it. The blob is extracted when it is a zip (by
content type or a `.zip` file name) unless `skip-decompress` is true, and
written under its file name otherwise. So an `archive: false` upload of a
file that already is a .zip (the Windows app) gets unpacked by default.
With `merge-multiple: true` or a single match, files land directly in
`path`, otherwise in `path/<artifact name>`. Patterns support minimatch's
`*` and `{a,b}` braces.
"""
import fnmatch
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / '.github/workflows/ci.yml').read_text()
VERSION = '1.0.0+git1.gabc'
PLATFORMS = ['android', 'linux', 'macos', 'windows']
EXPECTED = {
    'android': ['AirSDR-android-arm64-v8a.apk', 'AirSDR-android-armeabi-v7a.apk',
                'AirSDR-android-x86_64.apk'],
    'linux': ['AirSDR-linux-amd64.deb', 'AirSDR-linux-x86_64.pkg.tar.zst',
              'AirSDR-linux-x86_64.rpm', 'AirSDR-linux-x86_64.tar.gz'],
    'macos': ['AirSDR-macos.dmg'],
    'windows': ['AirSDR-windows-x86_64.zip'],
}


def zip_of(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        for name, data in files.items():
            z.writestr(name, data)
    return buf.getvalue()


def ci_artifacts(platforms):
    """Artifacts as the build jobs upload them: name -> (served file name, blob)."""
    v = VERSION
    out = {'sdrcore-windows-x86_64': ('sdrcore-windows-x86_64.zip', zip_of({'sdrcore.dll': 'dll'}))}
    if 'android' in platforms:
        for abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']:
            name = f'AirSDR-{v}-android-{abi}.apk'
            out[name] = (name, b'apk')                                   # archive: false
    if 'linux' in platforms:
        for kind, file in [('deb', f'airsdr_{v}_amd64.deb'), ('rpm', f'airsdr-{v}-1.x86_64.rpm'),
                           ('arch', 'airsdr-1.0.0.r1.gabc-1-x86_64.pkg.tar.zst'),
                           ('tar', f'airsdr-{v}-linux-x86_64.tar.gz')]:
            name = f'AirSDR-{v}-linux-x86_64-{kind}'
            out[name] = (name + '.zip', zip_of({file: kind}))           # default zip container
    if 'macos' in platforms:
        name = f'AirSDR-{v}-macos.dmg'
        out[name] = (name, b'dmg')                                       # archive: false
    if 'windows' in platforms:
        name = f'AirSDR-{v}-windows-x86_64.zip'                          # archive: false, a .zip
        out[name] = (name, zip_of({'sdr_flutter.exe': 'exe', 'sdrcore.dll': 'dll',
                                   'data/icudtl.dat': 'icu'}))
    return out


def job_lines(job):
    lines = WORKFLOW.split('\njobs:\n', 1)[1].splitlines()
    start = lines.index(f'  {job}:') + 1
    end = next((i for i in range(start, len(lines)) if re.match(r'  [\w-]+:$', lines[i])), len(lines))
    return lines[start:end]


def steps(job):
    """Steps of a job, each as its lines with the 8-space step indent removed."""
    body = job_lines(job)
    body = body[body.index('    steps:') + 1:]
    out = []
    for line in body:
        if line.startswith('      - '):
            out.append([line[8:]])
        elif out and (line.startswith(' ' * 8) or not line.strip()):
            out[-1].append(line[8:])
    return out


def block(step, key):
    """A `key:` mapping of a step; plain, quoted and folded (>-) scalars."""
    if key + ':' not in step:
        return {}
    values = {}
    folded = None
    for line in step[step.index(key + ':') + 1:]:
        m = re.match(r'  ([\w-]+): *(.*)$', line)
        if m:
            folded = m[1] if m[2].strip() == '>-' else None
            values[m[1]] = '' if folded else m[2].strip().strip('"')
        elif folded and line.startswith('    '):
            values[folded] = (values[folded] + ' ' + line.strip()).strip()
        else:
            break
    return values


def expand_braces(pattern):
    m = re.search(r'\{([^{}]*)\}', pattern)
    if not m:
        return [pattern]
    return [p for alt in m[1].split(',')
            for p in expand_braces(pattern[:m.start()] + alt + pattern[m.end():])]


def download(step, artifacts, workspace):
    opts = block(step, 'with')
    if 'name' in opts:
        matched = [opts['name']] if opts['name'] in artifacts else []
    else:
        patterns = expand_braces(opts['pattern'])
        matched = [n for n in artifacts if any(fnmatch.fnmatchcase(n, p) for p in patterns)]
    root = workspace / opts.get('path', '.')
    merge = opts.get('merge-multiple') == 'true' or 'name' in opts or len(matched) == 1
    for name in matched:
        file_name, blob = artifacts[name]
        dest = root if merge else root / name
        dest.mkdir(parents=True, exist_ok=True)
        if file_name.endswith('.zip') and opts.get('skip-decompress') != 'true':
            with zipfile.ZipFile(io.BytesIO(blob)) as z:
                z.extractall(dest)
        else:
            (dest / file_name).write_bytes(blob)


def run_script(step):
    script = []
    for line in step[step.index('run: |') + 1:]:
        if line and not line.startswith('  '):
            break
        script.append(line[2:])
    return '\n'.join(script)


def expression(text, results):
    """Substitutes ${{ needs.<job>.result }}; other expressions become the version."""
    text = re.sub(r'\$\{\{ *needs\.([\w-]+)\.result *\}\}', lambda m: results[m[1]], text)
    return re.sub(r'\$\{\{.*?\}\}', VERSION, text)


GH = '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
if sys.argv[1:3] == ['release', 'create']:
    for arg in sys.argv[4:]:
        if arg.startswith('-'):
            break
        p = pathlib.Path(arg)
        if not p.is_file():
            sys.exit('Upload argument is not a file: ' + arg)
        shutil.copy(p, pathlib.Path(os.environ['UPLOADED']) / p.name)
'''


def publish(test, job, built, results=None):
    """Downloads `built` platforms' artifacts as `job` does and runs its publish step."""
    results = results or dict.fromkeys(PLATFORMS + ['test', 'linux-install'], 'success')
    artifacts = ci_artifacts(built)
    root = Path(tempfile.mkdtemp(prefix='airsdr-release-test.'))
    test.addCleanup(shutil.rmtree, root)
    (root / 'tool').symlink_to(ROOT / 'tool', target_is_directory=True)
    (root / 'bin').mkdir()
    (root / 'uploaded').mkdir()
    (root / 'bin/gh').write_text(GH)
    (root / 'bin/gh').chmod(0o755)
    publish_step = None
    for step in steps(job):
        if step[0].startswith('uses: actions/download-artifact@'):
            download(step, artifacts, root)
        if step[0] in ('name: Create release', 'name: Replace nightly pre-release'):
            publish_step = step
    env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
               RUNNER_TEMP=str(root), GITHUB_REPOSITORY='test/AirSDR', GITHUB_SHA='abc123',
               GITHUB_REF_NAME='v1.0.0', UPLOADED=str(root / 'uploaded'))
    env.update({k: expression(v, results) for k, v in block(publish_step, 'env').items()})
    proc = subprocess.run(['bash', '-euo', 'pipefail', '-c', expression(run_script(publish_step), results)],
                          cwd=root, env=env, text=True, capture_output=True)
    return proc, root / 'uploaded'


class ReleaseDownloadTest(unittest.TestCase):
    def test_windows_job_uploads_a_raw_zip(self):
        # ci_artifacts models the Windows app as an archive: false .zip upload.
        upload = [s for s in steps('windows') if s[0] == 'name: Upload zip'][0]
        self.assertEqual(block(upload, 'with').get('archive'), 'false')

    def test_every_built_platform_is_published_with_windows_zip_intact(self):
        for job in ['release', 'nightly']:
            with self.subTest(job=job):
                proc, uploaded = publish(self, job, PLATFORMS)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                self.assertEqual(sorted(p.name for p in uploaded.iterdir()),
                                 sorted(sum(EXPECTED.values(), [])))
                with zipfile.ZipFile(uploaded / 'AirSDR-windows-x86_64.zip') as z:
                    self.assertIn('sdr_flutter.exe', z.namelist())
                    self.assertIn('sdrcore.dll', z.namelist())
                self.assertEqual((uploaded / 'AirSDR-linux-amd64.deb').read_bytes(), b'deb')
                self.assertEqual((uploaded / 'AirSDR-macos.dmg').read_bytes(), b'dmg')

    def test_failed_optional_platform_does_not_block_the_others(self):
        for job in ['release', 'nightly']:
            for failed in ['macos', 'windows']:
                with self.subTest(job=job, failed=failed):
                    results = dict.fromkeys(PLATFORMS + ['test', 'linux-install'], 'success')
                    results[failed] = 'failure'
                    proc, uploaded = publish(self, job, [p for p in PLATFORMS if p != failed], results)
                    self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                    self.assertEqual(sorted(p.name for p in uploaded.iterdir()),
                                     sorted(sum((v for k, v in EXPECTED.items() if k != failed), [])))

    def test_successful_build_without_its_asset_fails_publishing(self):
        for job in ['release', 'nightly']:
            for missing in PLATFORMS:
                with self.subTest(job=job, missing=missing):
                    # The build job succeeded, but its files never reached dist.
                    proc, uploaded = publish(self, job, [p for p in PLATFORMS if p != missing])
                    self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                    self.assertIn(EXPECTED[missing][0], proc.stderr)
                    self.assertEqual(list(uploaded.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
