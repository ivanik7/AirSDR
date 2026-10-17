// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/main.dart' show defaultDesktopAudioSink;
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/sdr_core.dart';

void main() {
  test('SSTV build excludes the unused Linux mirrored ringbuffer', () {
    final cmake = File('native/third_party/csdr_sstv.cmake').readAsStringSync();
    expect(cmake, isNot(contains(r'${CSDR_SSTV_ROOT}/src/ringbuffer.cpp')));
  });

  test('Windows CI resolves the toolchain from the checkout root', () {
    final workflow = File('.github/workflows/ci.yml').readAsStringSync();
    expect(
      workflow,
      contains(
        r'-DCMAKE_TOOLCHAIN_FILE="$GITHUB_WORKSPACE/native/cmake/llvm-mingw-x86_64.cmake"',
      ),
    );
  });

  test('desktop library candidates resolve within each Flutter bundle', () {
    expect(sdrCoreLibraryCandidates('linux', '/opt/AirSDR/airsdr'), [
      '/opt/AirSDR/lib/libsdrcore.so',
      'libsdrcore.so',
    ]);
    expect(
      sdrCoreLibraryCandidates(
        'macos',
        '/Applications/AirSDR.app/Contents/MacOS/AirSDR',
      ),
      [
        '/Applications/AirSDR.app/Contents/Frameworks/libsdrcore.dylib',
        'libsdrcore.dylib',
      ],
    );
    expect(sdrCoreLibraryCandidates('windows', r'C:\AirSDR\AirSDR.exe'), [
      r'C:\AirSDR\sdrcore.dll',
      'sdrcore.dll',
    ]);
    expect(sdrCoreLibraryCandidates('android', '/system/app'), [
      'libsdrcore.so',
    ]);
  });

  test(
    'desktop sink defaults retain Linux null and select miniaudio elsewhere',
    () {
      expect(defaultDesktopAudioSink('linux'), 'null');
      expect(defaultDesktopAudioSink('macos'), 'miniaudio');
      expect(defaultDesktopAudioSink('windows'), 'miniaudio');
      expect(
        defaultDesktopAudioSink('windows', override: 'wav:C:\\capture.wav'),
        'wav:C:\\capture.wav',
      );
    },
  );

  test('desktop USB error codes provide actionable messages', () {
    expect(
      SdrCoreError(SdrResult.hostAccessDenied).toString(),
      contains('USB access denied'),
    );
    expect(
      SdrCoreError(SdrResult.hostNotFound).toString(),
      contains('not found'),
    );
    expect(
      SdrCoreError(SdrResult.hostDriverUnsupported).toString(),
      contains('WinUSB'),
    );
    expect(SdrCoreError(SdrResult.hostBusy).toString(), contains('busy'));
  });

  test('host direct open on Linux is callable through the Dart FFI', () {
    final library = Platform.environment['SDRCORE_V3_PROBE_LIBRARY'];
    if (library == null) return;
    final api = FfiNativeRadioApi.open(
      libraryPath: library,
      directHostUsb: true,
    );
    final handle = api.create();
    try {
      expect(
        () => api.openHostUsb(handle, 255, 255, SdrSourceId.rtlsdr),
        throwsA(
          isA<SdrCoreError>().having(
            (e) => e.code,
            'code',
            SdrResult.hostNotFound,
          ),
        ),
      );
    } finally {
      api.destroy(handle);
    }
  });
}
