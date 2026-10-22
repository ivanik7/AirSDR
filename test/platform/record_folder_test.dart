// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/platform/record_folder.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeFolderPlatform implements RecordFolderPlatform {
  RecordFolder? selection;
  bool accessible = true;
  String? lastChecked;

  @override
  Future<RecordFolder?> choose() async => selection;

  @override
  Future<bool> validate(String locator) async {
    lastChecked = locator;
    return accessible;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('cancel preserves stored folder and restart restores locator', () async {
    final platform = FakeFolderPlatform()
      ..selection = const RecordFolder(
        'content:content://provider/tree/a',
        'Radio',
      );
    final store = RecordFolderStore(platform: platform);
    expect((await store.choose())?.displayName, 'Radio');
    platform.selection = null;
    expect(
      (await store.choose())?.locator,
      'content:content://provider/tree/a',
    );
    final restarted = RecordFolderStore(platform: platform);
    expect(
      (await restarted.load())?.locator,
      'content:content://provider/tree/a',
    );
    expect(await restarted.isAccessible(), isTrue);
    expect(platform.lastChecked, 'content:content://provider/tree/a');
  });

  test('revocation never silently replaces a folder', () async {
    final platform = FakeFolderPlatform()
      ..selection = const RecordFolder(
        'content:content://provider/tree/a',
        'Radio',
      );
    final store = RecordFolderStore(platform: platform);
    await store.choose();
    platform.accessible = false;
    platform.selection = null;
    expect(await store.isAccessible(), isFalse);
    expect(
      (await store.choose())?.locator,
      'content:content://provider/tree/a',
    );
    expect(await store.isAccessible(), isFalse);
  });

  test('failed validation cannot replace a valid folder', () async {
    final platform = FakeFolderPlatform()
      ..selection = const RecordFolder('file:/original', 'Original');
    final store = RecordFolderStore(platform: platform);
    await store.choose();
    platform.selection = const RecordFolder('file:/other', 'Other');
    platform.accessible = false;
    await expectLater(store.choose(), throwsA(isA<FolderAccessException>()));
    expect((await store.load())?.locator, 'file:/original');
  });

  test('desktop write/readback probe and missing directory', () async {
    final dir = await Directory.systemTemp.createTemp('airsdr-folder-test-');
    try {
      final platform = DesktopRecordFolderPlatform(
        chooseDirectory: () async => dir.path,
      );
      final folder = await platform.choose();
      expect(folder?.locator, 'file:${dir.absolute.path}');
      expect(await platform.validate(folder!.locator), isTrue);
      expect(await dir.list().toList(), isEmpty);
      await dir.delete();
      expect(await platform.validate(folder.locator), isFalse);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });
}
