// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_radio_settings.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'native_radio_settings_test_',
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String dir() => tempDir.path;

  test('defaults when no file and no legacy files exist', () {
    final settings = loadNativeRadioSettings(dir());
    final defaults = NativeRadioSettings.defaults();
    expect(settings.tunedFrequencyHz, defaults.tunedFrequencyHz);
    expect(settings.modeId, defaults.modeId);
    expect(settings.sampleRateHz, defaults.sampleRateHz);
    expect(settings.gainDb, defaults.gainDb);
    expect(settings.squelchKey, defaults.squelchKey);
    // No file should have been created by a plain load.
    expect(File('${dir()}/$nativeRadioSettingsFileName').existsSync(), isFalse);
  });

  test('round-trips every persisted field through save and load', () {
    final settings = NativeRadioSettings(
      tunedFrequencyHz: 101300000,
      modeId: DemodMode.nfm.id,
      bandwidthByMode: {DemodMode.nfm.id: 25000, DemodMode.usb.id: 2400},
      sampleRateHz: 3200000,
      gainDb: 32.5,
      squelchKey: SquelchType.auto.key,
      squelchLevelDb: -42,
      autoOffsetDb: 5,
      stereo: true,
    );
    saveNativeRadioSettingsSync(dir(), settings);

    final loaded = loadNativeRadioSettings(dir());
    expect(loaded.tunedFrequencyHz, 101300000);
    expect(loaded.modeId, DemodMode.nfm.id);
    expect(loaded.bandwidthByMode[DemodMode.nfm.id], 25000);
    expect(loaded.bandwidthByMode[DemodMode.usb.id], 2400);
    expect(loaded.sampleRateHz, 3200000);
    expect(loaded.gainDb, 32.5);
    expect(loaded.squelchKey, SquelchType.auto.key);
    expect(loaded.squelchLevelDb, -42);
    expect(loaded.autoOffsetDb, 5);
    expect(loaded.stereo, isTrue);
  });

  test(
    'network endpoint and source survive save, offline restart and USB switch',
    () {
      final defaults = NativeRadioSettings.defaults();
      expect(defaults.networkSelected, isFalse);
      expect(defaults.networkHost, '127.0.0.1');
      expect(defaults.networkPort, 1234);
      saveNativeRadioSettingsSync(
        dir(),
        defaults.copyWith(
          networkSelected: true,
          networkHost: '::1',
          networkPort: 8765,
        ),
      );
      final offline = loadNativeRadioSettings(dir());
      expect(offline.networkSelected, isTrue);
      expect(offline.networkHost, '::1');
      expect(offline.networkPort, 8765);
      saveNativeRadioSettingsSync(
        dir(),
        offline.copyWith(networkSelected: false),
      );
      final usb = loadNativeRadioSettings(dir());
      expect(usb.networkSelected, isFalse);
      expect(usb.networkHost, '::1');
      expect(usb.networkPort, 8765);
    },
  );

  test('invalid saved endpoint falls back to safe defaults', () {
    File('${dir()}/$nativeRadioSettingsFileName').writeAsStringSync(
      jsonEncode({
        'networkSelected': true,
        'networkHost': '   ',
        'networkPort': 65536,
      }),
    );
    final settings = loadNativeRadioSettings(dir());
    expect(settings.networkSelected, isFalse);
    expect(settings.networkHost, '127.0.0.1');
    expect(settings.networkPort, 1234);
  });

  test('stereo defaults to false when absent from the file', () {
    File('${dir()}/$nativeRadioSettingsFileName')
        .writeAsStringSync(jsonEncode({'version': 1, 'modeId': 1}));
    final loaded = loadNativeRadioSettings(dir());
    expect(loaded.stereo, isFalse);
  });

  test('malformed stereo field falls back to false, never throws', () {
    File('${dir()}/$nativeRadioSettingsFileName').writeAsStringSync(
      jsonEncode({'version': 1, 'modeId': 1, 'stereo': 'yes'}),
    );
    expect(() => loadNativeRadioSettings(dir()), returnsNormally);
    final loaded = loadNativeRadioSettings(dir());
    expect(loaded.stereo, isFalse);
  });

  test('saved file includes a version field', () {
    saveNativeRadioSettingsSync(dir(), NativeRadioSettings.defaults());
    final decoded = jsonDecode(
      File('${dir()}/$nativeRadioSettingsFileName').readAsStringSync(),
    );
    expect(decoded['version'], 1);
  });

  test('unknown mode id falls back to WFM default', () {
    File('${dir()}/$nativeRadioSettingsFileName')
        .writeAsStringSync(jsonEncode({'version': 1, 'modeId': 999}));
    final loaded = loadNativeRadioSettings(dir());
    expect(loaded.modeId, DemodMode.wfm.id);
  });

  test('auto squelch is dropped when the mode does not support it', () {
    // WFM has no auto squelch detector (demodParams[DemodMode.wfm].autoSquelch == null).
    File('${dir()}/$nativeRadioSettingsFileName').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'modeId': DemodMode.wfm.id,
        'squelchKey': 'auto',
      }),
    );
    final loaded = loadNativeRadioSettings(dir());
    expect(loaded.squelchKey, isNot('auto'));
  });

  test('bandwidth is clamped per-mode on load', () {
    File('${dir()}/$nativeRadioSettingsFileName').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'modeId': DemodMode.nfm.id,
        'bandwidthByMode': {'${DemodMode.nfm.id}': 999999},
      }),
    );
    final loaded = loadNativeRadioSettings(dir());
    expect(
      loaded.bandwidthByMode[DemodMode.nfm.id],
      DemodMode.nfm.params.maxBandwidth,
    );
  });

  test('corrupt JSON falls back to defaults and never throws', () {
    File('${dir()}/$nativeRadioSettingsFileName')
        .writeAsStringSync('{not valid json');
    expect(() => loadNativeRadioSettings(dir()), returnsNormally);
    final loaded = loadNativeRadioSettings(dir());
    expect(
      loaded.tunedFrequencyHz,
      NativeRadioSettings.defaults().tunedFrequencyHz,
    );
  });

  test('non-object JSON (e.g. a JSON array) falls back to defaults', () {
    File('${dir()}/$nativeRadioSettingsFileName').writeAsStringSync('[1,2,3]');
    final loaded = loadNativeRadioSettings(dir());
    expect(loaded.modeId, NativeRadioSettings.defaults().modeId);
  });

  test('negative/garbage sample rate falls back to default sample rate', () {
    File('${dir()}/$nativeRadioSettingsFileName')
        .writeAsStringSync(jsonEncode({'version': 1, 'sampleRateHz': -5}));
    final loaded = loadNativeRadioSettings(dir());
    expect(loaded.sampleRateHz, NativeRadioSettings.defaults().sampleRateHz);
  });

  group('migration from the old Dart engine files', () {
    test(
      'upgrade keeps legacy settings and ignores a stored engine selector',
      () {
        final core = jsonEncode({
          'engine': 'dart',
          'frequency': 118180000,
          'vfoOffsets': {'Radio': 5000},
          'sources': {
            'rtl_sdr': {
              'devices': {
                'Blog V4': {'sampleRate': 2400000, 'gain': 7},
              },
            },
          },
        });
        final radio = jsonEncode({
          'Radio': {
            'selectedDemodId': DemodMode.am.id,
            'AM': {
              'bandwidth': 9000,
              'squelchMode': 'power',
              'squelchLevel': -35,
            },
          },
        });
        File('${dir()}/config.json').writeAsStringSync(core);
        File('${dir()}/radio_config.json').writeAsStringSync(radio);
        final first = loadNativeRadioSettings(dir());
        expect(first.tunedFrequencyHz, 118185000);
        expect(first.modeId, DemodMode.am.id);
        expect(first.bandwidthByMode[DemodMode.am.id], 9000);
        expect(first.sampleRateHz, 2400000);
        expect(first.gainDb, NativeRadioSettings.defaults().gainDb);
        expect(first.squelchKey, SquelchType.manual.key);
        expect(first.squelchLevelDb, -35);
        expect(File('${dir()}/config.json').readAsStringSync(), core);
        expect(File('${dir()}/radio_config.json').readAsStringSync(), radio);
        // An upgrade/restart uses the native snapshot; the legacy files remain
        // available for rollback, but never select an old engine.
        final second = loadNativeRadioSettings(dir());
        expect(second.toJson(), first.toJson());
      },
    );

    test('migrates tuned frequency (center + vfoOffsets.Radio)', () {
      File('${dir()}/config.json').writeAsStringSync(
        jsonEncode({
          'frequency': 100000000.0,
          'vfoOffsets': {'Radio': 250000.0},
        }),
      );
      final migrated = migrateFromDartEngineFiles(dir());
      expect(migrated, isNotNull);
      expect(migrated!.tunedFrequencyHz, 100250000.0);
    });

    test(
      'migrates selected mode and per-mode bandwidth from radio_config.json',
      () {
        File('${dir()}/config.json')
            .writeAsStringSync(jsonEncode({'frequency': 100e6}));
        File('${dir()}/radio_config.json').writeAsStringSync(
          jsonEncode({
            'Radio': {
              'selectedDemodId': DemodMode.usb.id,
              'WFM': {'bandwidth': 150000.0},
              'USB': {
                'bandwidth': 2700.0,
                'squelchMode': 'power',
                'squelchLevel': -35.0,
              },
            },
          }),
        );
        final migrated = migrateFromDartEngineFiles(dir());
        expect(migrated, isNotNull);
        expect(migrated!.modeId, DemodMode.usb.id);
        expect(migrated.bandwidthByMode[DemodMode.usb.id], 2700.0);
        expect(migrated.bandwidthByMode[DemodMode.wfm.id], 150000.0);
        expect(migrated.squelchKey, SquelchType.manual.key);
        expect(migrated.squelchLevelDb, -35.0);
      },
    );

    test(
      'migrates legacy squelchEnabled boolean when squelchMode is absent',
      () {
        File('${dir()}/radio_config.json').writeAsStringSync(
          jsonEncode({
            'Radio': {
              'selectedDemodId': DemodMode.nfm.id,
              'FM': {'squelchEnabled': true, 'squelchLevel': -60.0},
            },
          }),
        );
        final migrated = migrateFromDartEngineFiles(dir());
        expect(migrated, isNotNull);
        expect(migrated!.squelchKey, SquelchType.manual.key);
        expect(migrated.squelchLevelDb, -60.0);
      },
    );

    test('migrates auto squelch only for a mode that supports it (NFM)', () {
      File('${dir()}/radio_config.json').writeAsStringSync(
        jsonEncode({
          'Radio': {
            'selectedDemodId': DemodMode.nfm.id,
            'FM': {'squelchMode': 'auto', 'squelchAutoOffset': 4.0},
          },
        }),
      );
      final migrated = migrateFromDartEngineFiles(dir());
      expect(migrated, isNotNull);
      expect(migrated!.squelchKey, SquelchType.auto.key);
      expect(migrated.autoOffsetDb, 4.0);
    });

    test('migrates rtl_sdr sample rate from config.json sources', () {
      File('${dir()}/config.json').writeAsStringSync(
        jsonEncode({
          'frequency': 100e6,
          'sources': {
            'rtl_sdr': {
              'device': 'Some RTL-SDR',
              'devices': {
                'Some RTL-SDR': {'sampleRate': 3200000, 'gain': 5},
              },
            },
          },
        }),
      );
      final migrated = migrateFromDartEngineFiles(dir());
      expect(migrated, isNotNull);
      expect(migrated!.sampleRateHz, 3200000.0);
      // Gain is a hardware gain-table index, not dB: must stay at default.
      expect(migrated.gainDb, NativeRadioSettings.defaults().gainDb);
      expect(migrated.legacyRtlGainIndex, 5);
      expect(migrated.legacyRtlDeviceName, 'Some RTL-SDR');
    });

    test(
      'pending RTL gain survives restart and cannot be confused with dB',
      () {
        File('${dir()}/config.json').writeAsStringSync(
          jsonEncode({
            'sources': {
              'rtl_sdr': {
                'device': 'RTL Blog [00000001]',
                'devices': {
                  'RTL Blog [00000001]': {'gain': 12},
                },
              },
            },
          }),
        );
        final first = loadNativeRadioSettings(dir());
        final second = loadNativeRadioSettings(dir());
        expect(first.legacyRtlGainIndex, 12);
        expect(second.legacyRtlGainIndex, 12);
        expect(second.legacyRtlDeviceName, 'RTL Blog [00000001]');
        expect(second.gainDb, NativeRadioSettings.defaults().gainDb);
      },
    );

    test('returns null when neither legacy file exists', () {
      expect(migrateFromDartEngineFiles(dir()), isNull);
    });

    test('leaves the legacy files untouched', () {
      final coreContent = jsonEncode({'frequency': 97e6});
      final radioContent = jsonEncode({
        'Radio': {'selectedDemodId': DemodMode.am.id},
      });
      File('${dir()}/config.json').writeAsStringSync(coreContent);
      File('${dir()}/radio_config.json').writeAsStringSync(radioContent);
      migrateFromDartEngineFiles(dir());
      expect(File('${dir()}/config.json').readAsStringSync(), coreContent);
      expect(
        File('${dir()}/radio_config.json').readAsStringSync(),
        radioContent,
      );
    });

    test('loadNativeRadioSettings migrates and persists native_radio.json', () {
      File('${dir()}/config.json')
          .writeAsStringSync(jsonEncode({'frequency': 97e6}));
      final loaded = loadNativeRadioSettings(dir());
      expect(loaded.tunedFrequencyHz, 97e6);
      expect(
        File('${dir()}/$nativeRadioSettingsFileName').existsSync(),
        isTrue,
      );
      // config.json is untouched (migration source, not a sink).
      expect(
        jsonDecode(
          File('${dir()}/config.json').readAsStringSync(),
        )['frequency'],
        97e6,
      );
    });
  });

  group('migration from the L1 linux_host_radio.json', () {
    test('migrates frequency, sample rate, gain, mode and bandwidth', () {
      File('${dir()}/linux_host_radio.json').writeAsStringSync(
        jsonEncode({
          'frequency': 433900000.0,
          'sampleRate': 2400000.0,
          'gain': 28.0,
          'mode': {'id': DemodMode.am.id, 'label': 'AM'},
          'bandwidth': 9000.0,
        }),
      );
      final migrated = migrateFromLinuxHostFile(dir());
      expect(migrated, isNotNull);
      expect(migrated!.tunedFrequencyHz, 433900000.0);
      expect(migrated.sampleRateHz, 2400000.0);
      expect(migrated.gainDb, 28.0);
      expect(migrated.modeId, DemodMode.am.id);
      expect(migrated.bandwidthByMode[DemodMode.am.id], 9000.0);
    });

    test(
      'used by loadNativeRadioSettings only when Dart-engine files are absent',
      () {
        File('${dir()}/linux_host_radio.json')
            .writeAsStringSync(jsonEncode({'frequency': 144390000.0}));
        final loaded = loadNativeRadioSettings(dir());
        expect(loaded.tunedFrequencyHz, 144390000.0);
      },
    );

    test('returns null when the file does not exist', () {
      expect(migrateFromLinuxHostFile(dir()), isNull);
    });

    test('leaves the legacy file untouched', () {
      final content = jsonEncode({'frequency': 7100000.0});
      File('${dir()}/linux_host_radio.json').writeAsStringSync(content);
      migrateFromLinuxHostFile(dir());
      expect(
        File('${dir()}/linux_host_radio.json').readAsStringSync(),
        content,
      );
    });
  });
}
