import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/sdr_core.dart';

// Build native/ with host CMake, then set SDRCORE_HOST_LIBRARY to the absolute
// path of its libsdrcore.so. No library is bundled with flutter test by default.
void main() {
  final libraryPath = Platform.environment['SDRCORE_HOST_LIBRARY'];
  test(
    'Linux host calls the real sdrcore C ABI through Dart FFI',
    () {
      final core = SdrCore.open(libraryPath: libraryPath);
      // ABI 3 extends ABI 2 without changing the older struct layouts.
      expect(
        core.version,
        inInclusiveRange(SdrCore.abiVersion, SdrCore.maxAbiVersion),
      ); // Calls native sdr_version.

      final first = core.create();
      final second = core.create();
      try {
        expect(first.isDisposed, isFalse);
        expect(second.isDisposed, isFalse);
        first.openSynthetic(2400000);
        first.configure(100000000, 2400000, 125);
        final configured = first.stats;
        expect(configured.frequencyHz, 100000000);
        expect(configured.sampleRate, 2400000);
        expect(configured.gainTenthsDb, 125);
        expect(configured.lastError, 0);
        expect(() => first.openUsb(-1, 3), throwsStateError);
        first.start();
        expect(first.stats.state, 2); // SDR_RUNNING
        sleep(const Duration(milliseconds: 50));
        first.stop();
        final stopped = first.stats;
        expect(stopped.state, 1); // SDR_OPEN
        expect(stopped.source, 2); // SDR_SYNTHETIC
        expect(stopped.checksum, isNot(0));
        expect(stopped.inputSamples, greaterThan(0));
        expect(
          stopped.inputSamples,
          stopped.processedSamples + stopped.droppedSamples,
        );
        first.close();
        expect(first.stats.state, 0); // SDR_IDLE
        expect(() => first.openFile(-1, 2400000), throwsStateError);
      } finally {
        first.dispose();
        second.dispose();
      }
      expect(first.isDisposed, isTrue);
      expect(second.isDisposed, isTrue);

      // Exercise the native allocator again after both handles were destroyed.
      final again = core.create();
      again.dispose();
    },
    skip: !Platform.isLinux
        ? 'Host libsdrcore.so is built for Linux (or Android separately)'
        : libraryPath == null || libraryPath.isEmpty
        ? 'Set SDRCORE_HOST_LIBRARY to the host CMake libsdrcore.so path'
        : false,
  );
}
