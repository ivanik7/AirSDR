// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/platform/record_folder.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/record_folder');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final platform = AndroidRecordFolderPlatform(channel: channel);
  Map<String, String>? selection;
  bool access = true;
  final released = <String>[];

  setUp(() {
    selection = null;
    access = true;
    released.clear();
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'choose') return selection;
      if (call.method == 'validate') return access;
      if (call.method == 'release') {
        released.add(call.arguments as String);
        return null;
      }
      throw MissingPluginException();
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('picker cancellation returns null', () async {
    expect(await platform.choose(), isNull);
  });

  test('tree locator is opaque; revocation returns false', () async {
    selection = {
      'locator': 'content:content://authority/tree/test',
      'displayName': 'test',
    };
    final chosen = await platform.choose();
    expect(chosen?.locator, 'content:content://authority/tree/test');
    access = false;
    expect(await platform.validate(chosen!.locator), isFalse);
    expect(await platform.validate('/storage/test'), isFalse);
  });

  test('rejects a POSIX path disguised as SAF', () async {
    selection = {'locator': 'file:/tmp/recordings', 'displayName': 'test'};
    await expectLater(platform.choose(), throwsA(isA<FolderAccessException>()));
  });

  test('replacement releases only the previous grant after persistence', () async {
    final store = RecordFolderStore(platform: platform);
    selection = {
      'locator': 'content:content://authority/tree/first',
      'displayName': 'First',
    };
    await store.choose();
    selection = {
      'locator': 'content:content://authority/tree/second',
      'displayName': 'Second',
    };
    await store.choose();
    expect(released, ['content:content://authority/tree/first']);
    expect((await store.load())?.locator, selection!['locator']);
    selection = null;
    await store.choose();
    expect(released, hasLength(1));
  });

  test('failed write probe releases rejected grant but preserves old', () async {
    final store = RecordFolderStore(platform: platform);
    selection = {
      'locator': 'content:content://authority/tree/first',
      'displayName': 'First',
    };
    await store.choose();
    selection = {
      'locator': 'content:content://authority/tree/rejected',
      'displayName': 'Rejected',
    };
    access = false;
    await expectLater(store.choose(), throwsA(isA<FolderAccessException>()));
    expect(released, ['content:content://authority/tree/rejected']);
    expect((await store.load())?.locator, 'content:content://authority/tree/first');
  });
}
