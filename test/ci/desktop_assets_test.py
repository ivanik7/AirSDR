# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate desktop icons against the Android geometry and DMG layout."""
import importlib.util
import json
from pathlib import Path
import struct
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('icons', ROOT / 'tool/branding/generate_icons.py')
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)


class DesktopAssetsTest(unittest.TestCase):
    def test_mac_catalog_uses_android_icon_geometry_at_every_scale(self):
        catalog = ROOT / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
        manifest = json.loads((catalog / 'Contents.json').read_text())
        for entry in manifest['images']:
            size = int(entry['size'].split('x')[0]) * int(entry['scale'][0])
            with self.subTest(size=size):
                self.assertEqual((catalog / entry['filename']).read_bytes(), icons.draw_icon(size))

    def test_windows_ico_contains_all_android_geometry_representations(self):
        data = (ROOT / 'windows/runner/resources/app_icon.ico').read_bytes()
        reserved, kind, count = struct.unpack_from('<HHH', data)
        self.assertEqual((reserved, kind, count), (0, 1, len(icons.WINDOWS_SIZES)))
        for i, size in enumerate(icons.WINDOWS_SIZES):
            width, height, _, _, _, _, length, offset = struct.unpack_from('<BBBBHHII', data, 6 + i * 16)
            self.assertEqual((width or 256, height or 256), (size, size))
            self.assertEqual(data[offset:offset + length], icons.draw_icon(size))

    @unittest.skipUnless(shutil.which("ditto"), "DMG staging requires macOS ditto")
    def test_dmg_staging_contains_app_and_applications_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app = root / 'AirSDR.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/marker').write_text('app')
            subprocess.run(['bash', str(ROOT / 'packaging/macos/stage-dmg.sh'),
                            str(app), str(root / 'image')], check=True)
            self.assertEqual((root / 'image/AirSDR.app/Contents/marker').read_text(), 'app')
            self.assertEqual((root / 'image/Applications').readlink(), Path('/Applications'))
            self.assertIn('Privacy & Security', (root / 'image/README.txt').read_text())
            self.assertIn('Open Anyway', (root / 'image/README.txt').read_text())


if __name__ == '__main__':
    unittest.main()
