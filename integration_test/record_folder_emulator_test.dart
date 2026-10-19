// SPDX-License-Identifier: GPL-3.0-or-later
// On an Android emulator: flutter test integration_test/record_folder_emulator_test.dart -d <id>
// In the system picker, choose a writable directory and tap "Use this folder".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sdr_flutter/platform/record_folder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'SAF tree selection persists and performs actual document write/readback',
    (tester) async {
      if (!Platform.isAndroid) return;
      final store = RecordFolderStore();
      final folder = await store.choose();
      expect(
        folder,
        isNotNull,
        reason: 'Select a directory in the system picker',
      );
      expect(folder!.locator, startsWith('content:content://'));
      expect(await store.isAccessible(), isTrue);
      final restored = RecordFolderStore();
      expect((await restored.load())?.locator, folder.locator);
      expect(await restored.isAccessible(), isTrue);
    },
  );

  testWidgets('revoked SAF grant leaves saved tree inaccessible', (tester) async {
    if (!Platform.isAndroid) return;
    final store = RecordFolderStore();
    final locator = (await store.load())!.locator;
    await AndroidRecordFolderPlatform().release(locator);
    expect(await store.isAccessible(), isFalse);
    expect((await RecordFolderStore().load())?.locator, locator);
  });
}
