// SPDX-License-Identifier: GPL-3.0-or-later
// Real FFI/controller path against a local rtl_tcp v1 server fed generated IQ.
// Opt in with SDRCORE_V3_PROBE_LIBRARY=<host libsdrcore.so>.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_radio_api.dart';
import 'package:sdr_flutter/native/native_radio_controller.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

class _NoUsb implements NativeDeviceSource {
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Future<List<NativeDevice>> list() async => [];
  @override
  Future<NativeDevice> open(NativeDevice device) async => device;
  @override
  Future<void> close(NativeDevice device) async {}
}

Future<void> _until(bool Function() condition, String Function() status) async {
  for (var attempt = 0; attempt < 160; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('Timed out waiting for the local rtl_tcp stream: ${status()}');
}

void main() {
  final library = Platform.environment['SDRCORE_V3_PROBE_LIBRARY'];
  test(
    'network selection streams generated IQ to FFT, retunes, stops and restarts',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final timers = <Timer>[];
      final commands = <int>[];
      // 60 kHz complex tone at 250 kS/s. The radio app never sees these IQ
      // bytes through Dart: they enter the native receiver through TCP only.
      const rate = 250000;
      const frequency = 60000;
      final iq = Uint8List(8192);
      for (var n = 0; n < iq.length ~/ 2; n++) {
        final phase = 2 * math.pi * frequency * n / rate;
        iq[2 * n] = (127.5 + 70 * math.cos(phase)).round();
        iq[2 * n + 1] = (127.5 + 70 * math.sin(phase)).round();
      }
      final accepted = server.listen((socket) {
        sockets.add(socket);
        // The client intentionally closes twice (Stop, then restart). A
        // server-side write racing that close may fail asynchronously.
        unawaited(socket.done.catchError((Object _) {}));
        socket.add([82, 84, 76, 48, 0, 0, 0, 0, 0, 0, 0, 0]); // RTL0
        var bytes = 0;
        Timer? feeder;
        socket.listen(
          (data) {
            commands.addAll(data);
            bytes += data.length;
            if (bytes >= 20 && feeder == null) {
              feeder = Timer.periodic(const Duration(milliseconds: 10), (_) {
                try {
                  socket.add(iq);
                } on SocketException {
                  feeder?.cancel();
                }
              });
              timers.add(feeder!);
            }
          },
          onDone: () => feeder?.cancel(),
          onError: (_) => feeder?.cancel(),
        );
      });
      final radio = NativeRadioController(
        api: FfiNativeRadioApi.open(libraryPath: library),
        source: _NoUsb(),
        autoStart: false,
        pollInterval: const Duration(milliseconds: 30),
        fftInterval: const Duration(milliseconds: 30),
        discoveryInterval: const Duration(seconds: 30),
      );
      final rows = <FftRow>[];
      final sub = radio.fftRows.listen(rows.add);
      try {
        await radio.selectNetworkSource('127.0.0.1', server.port);
        radio.setSampleRate(rate.toDouble());
        radio.setFftWidth(128);
        await radio.start();
        await _until(
          () =>
              radio.linkState == DeviceLinkState.receiving &&
              (radio.stats['inputSamples'] as int? ?? 0) > 0 &&
              rows.isNotEmpty,
          () =>
              'link=${radio.linkState} error=${radio.lastError} stats=${radio.stats} sockets=${sockets.length} commands=${commands.length} rows=${rows.length}',
        );
        expect(radio.selectedDevice?.id, startsWith('rtltcp:'));
        expect(rows.last.width, 128);
        expect(commands.length, greaterThanOrEqualTo(20));
        radio.setTuning(centerFrequency: 101300000, vfoOffset: 0);
        await _until(
          () => commands.length >= 25,
          () => 'commands=${commands.length} error=${radio.lastError}',
        );
        expect(commands[20], 1); // retune opcode
        expect(radio.centerFrequency, 101300000);
        expect(radio.vfoOffset, 0);
        await radio.stop();
        expect(radio.running, isFalse);
        expect(radio.linkState, DeviceLinkState.stoppedByUser);
        await radio.refreshDevices();
        expect(radio.running, isFalse);
        await radio.start();
        await _until(
          () =>
              sockets.length == 2 &&
              radio.linkState == DeviceLinkState.receiving,
          () =>
              'link=${radio.linkState} error=${radio.lastError} sockets=${sockets.length}',
        );
        expect(radio.networkSelected, isTrue);
        await radio.stop();
      } finally {
        await sub.cancel();
        radio.dispose();
        for (final timer in timers) {
          timer.cancel();
        }
        for (final socket in sockets) {
          socket.destroy();
        }
        await accepted.cancel();
        await server.close();
      }
    },
    skip: library == null
        ? 'Set SDRCORE_V3_PROBE_LIBRARY to a host v3 build'
        : null,
  );
}
