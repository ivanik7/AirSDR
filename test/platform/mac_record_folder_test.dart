// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/platform/record_folder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/record_folder_macos');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final platform = MacRecordFolderPlatform(channel: channel);
  Map<String, String>? selection;
  bool bookmarkValid = true;
  String? validated;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('airsdr-mac-folder-');
    selection = {'locator': 'file:${dir.path}', 'displayName': 'Selected'};
    bookmarkValid = true;
    validated = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'choose') return selection;
      if (call.method == 'validate') {
        validated = call.arguments as String;
        return bookmarkValid;
      }
      throw MissingPluginException();
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('cancellation and native bookmark gating preserve the chosen path', () async {
    final folder = await platform.choose();
    expect(folder?.displayName, 'Selected');
    expect(await platform.validate(folder!.locator), isTrue);
    expect(validated, folder.locator);
    bookmarkValid = false;
    expect(await platform.validate(folder.locator), isFalse);
    selection = null;
    expect(await platform.choose(), isNull);
    expect(await dir.list().toList(), isEmpty);
  });

  test('path alone never grants access without a bookmark', () async {
    bookmarkValid = false;
    expect(await platform.validate('file:${dir.path}'), isFalse);
    expect(await platform.validate('content:content://tree'), isFalse);
    expect(validated, 'file:${dir.path}');
  });
}
