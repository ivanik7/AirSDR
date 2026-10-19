// SPDX-License-Identifier: GPL-3.0-or-later
// Tests ABI marshalling against a C fixture, NOT recording functionality.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/native/native_record_api.dart';
import 'package:sdr_flutter/native/sdr_core.dart';

void main() {
  test('record v1 Dart layout and optional unavailable extension', () {
    expect(FfiNativeRecordApi.layoutSizes, [48, 136]);
    expect(FfiNativeRecordApi.tryOpen(DynamicLibrary.process()), isNull);
  });

  test(
    'C boundary copies config, status, provider error and notification',
    () async {
      if (!Platform.isLinux) {
        return; // C fixture uses host cc; CI for others later.
      }
      final scratch = await Directory(Platform.environment['TMPDIR']!)
          .createTemp('record_abi_');
      try {
        final output = '${scratch.path}/librecord_abi.so';
        final cc = await Process.run('cc', [
          '-std=c11',
          '-fPIC',
          '-shared',
          '-Inative/include',
          'test/native/record_abi_fixture.c',
          '-o',
          output,
        ]);
        expect(cc.exitCode, 0, reason: '${cc.stdout}\n${cc.stderr}');
        final library = DynamicLibrary.open(output);
        final api = FfiNativeRecordApi.tryOpen(library);
        expect(api, isNotNull);
        expect(
          api!.capabilities().supports(
            SdrRecordStream.iq,
            SdrRecordFormat.none,
          ),
          isTrue,
        );
        expect(
          api.capabilities().supports(
            SdrRecordStream.audio,
            SdrRecordFormat.wav,
          ),
          isTrue,
        );
        expect(
          api.capabilities().supports(
            SdrRecordStream.audio,
            SdrRecordFormat.mp3,
          ),
          isFalse,
        );

        final handle = calloc<Uint8>().cast<SdrHandle>();
        var callbackCount = 0;
        final callbackStates = <int>[];
        var capturedProviderFolder = '';
        var capturedProviderName = '';
        var capturedProviderMime = '';
        Object? providerFailure;
        final notification =
            NativeCallable<
              Void Function(Pointer<Void>, Pointer<Void>)
            >.isolateLocal((Pointer<Void> context, Pointer<Void> status) {
              expect(context.address, 3);
              expect(status.address, isNot(0));
              callbackStates.add((status.cast<Uint32>() + 2).value);
              callbackCount++;
            });
        final provider =
            NativeCallable<
              Int32 Function(
                Pointer<Void>,
                Pointer<Char>,
                Uint32,
                Pointer<Char>,
                Uint32,
                Pointer<Char>,
                Pointer<Int32>,
              )
            >.isolateLocal((
              Pointer<Void> context,
              Pointer<Char> folder,
              int folderBytes,
              Pointer<Char> name,
              int nameBytes,
              Pointer<Char> mime,
              Pointer<Int32> outFd,
            ) {
              try {
                capturedProviderFolder = folder.cast<Utf8>().toDartString(
                  length: folderBytes,
                );
                capturedProviderName = name.cast<Utf8>().toDartString(
                  length: nameBytes,
                );
                capturedProviderMime = mime.cast<Utf8>().toDartString();
                outFd.value = -1;
                return SdrRecordError.folderUnavailable;
              } catch (error) {
                providerFailure = error;
                return SdrResult.internalError;
              }
            }, exceptionalReturn: SdrResult.internalError);
        try {
          final setNotify = library
              .lookupFunction<
                Int32 Function(
                  Pointer<SdrHandle>,
                  Pointer<
                    NativeFunction<Void Function(Pointer<Void>, Pointer<Void>)>
                  >,
                  Pointer<Void>,
                ),
                int Function(
                  Pointer<SdrHandle>,
                  Pointer<
                    NativeFunction<Void Function(Pointer<Void>, Pointer<Void>)>
                  >,
                  Pointer<Void>,
                )
              >('sdr_record_set_notify');
          final setProvider = library
              .lookupFunction<
                Int32 Function(
                  Pointer<Char>,
                  Uint32,
                  Pointer<
                    NativeFunction<
                      Int32 Function(
                        Pointer<Void>,
                        Pointer<Char>,
                        Uint32,
                        Pointer<Char>,
                        Uint32,
                        Pointer<Char>,
                        Pointer<Int32>,
                      )
                    >
                  >,
                  Pointer<Void>,
                ),
                int Function(
                  Pointer<Char>,
                  int,
                  Pointer<
                    NativeFunction<
                      Int32 Function(
                        Pointer<Void>,
                        Pointer<Char>,
                        Uint32,
                        Pointer<Char>,
                        Uint32,
                        Pointer<Char>,
                        Pointer<Int32>,
                      )
                    >
                  >,
                  Pointer<Void>,
                )
              >('sdr_record_set_provider');
          final scheme = 'content'.toNativeUtf8();
          try {
            expect(
              setProvider(
                scheme.cast(),
                7,
                provider.nativeFunction,
                Pointer.fromAddress(7),
              ),
              0,
            );
          } finally {
            calloc.free(scheme);
          }
          expect(
            setNotify(
              handle,
              notification.nativeFunction,
              Pointer.fromAddress(3),
            ),
            0,
          );
          const config = SdrRecordConfig(
            streams: SdrRecordStream.audio | SdrRecordStream.decoderLog,
            audioFormat: SdrRecordFormat.wav,
            audioBitrateKbps: 96,
            startUnixMs: 1234567890000,
            utcOffsetMinutes: 300,
          );
          expect(
            api.start(handle, config, 'content:tree', ['rds', 'rtl_433']),
            0,
          );
          final failed = api.status(handle);
          expect(failed.state, SdrRecordState.failed);
          expect(failed.stopReason, 3);
          expect(providerFailure, isNull);
          expect(failed.lastError, SdrRecordError.folderUnavailable);
          expect(capturedProviderFolder, 'content:tree');
          expect(capturedProviderName, 'record.wav');
          expect(capturedProviderMime, 'audio/wav');
          expect(failed.errorStream, SdrRecordStream.audio);
          expect(failed.streams, config.streams);
          expect(failed.audioFormat, config.audioFormat);
          expect(failed.sessionId, config.startUnixMs);
          expect(failed.elapsedMs, config.utcOffsetMinutes);
          expect(failed.bytesWritten, config.audioBitrateKbps);
          final capturedFolder = library
              .lookupFunction<
                Pointer<Utf8> Function(),
                Pointer<Utf8> Function()
              >('sdr_record_test_folder');
          final capturedIds = library
              .lookupFunction<
                Pointer<Utf8> Function(),
                Pointer<Utf8> Function()
              >('sdr_record_test_ids');
          expect(capturedFolder().toDartString(), 'content:tree');
          expect(capturedIds().toDartString(), 'rds,rtl_433');
          expect(callbackCount, 1);
          expect(api.stop(handle), 0); // acknowledge failure
          expect(api.status(handle).state, SdrRecordState.idle);
          expect(
            callbackCount,
            1,
          ); // no duplicate transition on acknowledgement
          expect(api.stop(handle), SdrResult.invalidState);

          expect(api.start(handle, config, 'file:/recordings', []), 0);
          expect(api.status(handle).state, SdrRecordState.active);
          expect(api.stop(handle), 0);
          expect(api.status(handle).stopReason, 1);
          expect(callbackCount, 2);
          expect(callbackStates, [SdrRecordState.failed, SdrRecordState.idle]);
          expect(setNotify(handle, nullptr, nullptr), 0);
          final unregisterScheme = 'content'.toNativeUtf8();
          try {
            expect(
              setProvider(unregisterScheme.cast(), 7, nullptr, nullptr),
              0,
            );
          } finally {
            calloc.free(unregisterScheme);
          }
        } finally {
          provider.close();
          notification.close();
          calloc.free(handle);
        }
      } finally {
        await scratch.delete(recursive: true);
      }
    },
  );
}
