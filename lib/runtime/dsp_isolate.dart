// SPDX-License-Identifier: GPL-3.0-or-later
// The DSP isolate: hosts a [DspEngine] (SignalPath + SourceManager + RadioModule + audio
// output) and speaks the protocol of dsp_protocol.dart with the UI isolate.
//
// Usage (UI isolate):
//   final dsp = await DspIsolate.spawn(options: DspEngineOptions(configDir: dir),
//                                      registerSources: registerDeviceSources);
//   dsp.events.listen(...);                  // fft / state / stats / error / audio
//   await dsp.request({'cmd': DspCmd.selectSource, 'id': 'synth', 'params': {...}});
//   dsp.send({'cmd': DspCmd.tune, 'center': 101.1e6});
//   await dsp.close();
//
// Commands are executed strictly in arrival order (async ones — start/stop/selectSource — are
// awaited before the next command runs), exactly like SDR++'s GUI thread calling into the
// signal path while holding the relevant locks.
import 'dart:async';
import 'dart:isolate';

import 'dsp_engine.dart';
import 'dsp_protocol.dart';
import 'source_registry.dart';

class _SpawnArgs {
  _SpawnArgs(this.port, this.options, this.registerSources);
  final SendPort port;
  final DspEngineOptions options;
  final SourceRegistryHook? registerSources;
}

class DspIsolate {
  DspIsolate._(this._isolate, this._send, this._rx, this._events);

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _rx;
  final StreamController<Map<Object?, Object?>> _events;
  final Map<int, Completer<void>> _pending = <int, Completer<void>>{};
  int _nextReq = 1;
  bool _closed = false;

  /// All DSP → UI events (broadcast). Acks are consumed internally.
  Stream<Map<Object?, Object?>> get events => _events.stream;

  bool get isClosed => _closed;

  /// Spawns the isolate. [registerSources] (top-level function) runs inside the isolate after
  /// the built-in sources are registered: the integrator's hook for USB sources.
  static Future<DspIsolate> spawn(
      {DspEngineOptions options = const DspEngineOptions(), SourceRegistryHook? registerSources}) async {
    final rx = ReceivePort('sdr-dsp-events');
    final events = StreamController<Map<Object?, Object?>>.broadcast();
    final ready = Completer<SendPort>();
    late DspIsolate self;
    rx.listen((dynamic msg) {
      if (msg is List) {
        // Uncaught isolate error (addErrorListener): [error, stackTrace].
        events.add(<Object?, Object?>{DspMsg.evt: DspEvt.error, 'message': '${msg.isNotEmpty ? msg[0] : msg}', 'fatal': true});
        return;
      }
      if (msg is! Map) return;
      final evt = msg[DspMsg.evt];
      if (evt == DspEvt.ready && !ready.isCompleted) {
        ready.complete(msg['port'] as SendPort);
        return;
      }
      if (!ready.isCompleted) return;
      if (evt == DspEvt.ack) {
        final c = self._pending.remove(msg[DspMsg.req]);
        if (c != null) {
          if (msg['ok'] == true) {
            c.complete();
          } else {
            c.completeError(DspCommandException(msg['error'] as String? ?? 'error'));
          }
        }
        return;
      }
      if (evt == DspEvt.closed) {
        self._closed = true;
      }
      events.add(msg.cast<Object?, Object?>());
    });
    final isolate = await Isolate.spawn(_main, _SpawnArgs(rx.sendPort, options, registerSources),
        debugName: 'sdr-dsp', errorsAreFatal: false);
    isolate.addErrorListener(rx.sendPort); // uncaught errors arrive as [message, stack] lists
    final port = await ready.future.timeout(const Duration(seconds: 20));
    self = DspIsolate._(isolate, port, rx, events);
    return self;
  }

  /// Fire-and-forget command.
  void send(Map<String, Object?> msg) {
    if (_closed) return;
    _send.send(msg);
  }

  /// Command with an acknowledgement; throws [DspCommandException] on failure.
  Future<void> request(Map<String, Object?> msg, {Duration timeout = const Duration(seconds: 20)}) {
    if (_closed) return Future<void>.error(StateError('DSP isolate closed'));
    final id = _nextReq++;
    final c = Completer<void>();
    _pending[id] = c;
    _send.send(<String, Object?>{...msg, DspMsg.req: id});
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw TimeoutException('DSP command ${msg[DspMsg.cmd]} timed out');
    });
  }

  /// Graceful shutdown (saves configs), then kills the isolate.
  Future<void> close() async {
    if (!_closed) {
      try {
        await request(<String, Object?>{DspMsg.cmd: DspCmd.shutdown}, timeout: const Duration(seconds: 5));
      } catch (_) {}
    }
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _rx.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('DSP isolate closed'));
    }
    _pending.clear();
    await _events.close();
  }

  // ---------------------------------------------------------------------------
  // Isolate side
  // ---------------------------------------------------------------------------

  static void _main(_SpawnArgs args) {
    final out = args.port;
    final registry = SourceRegistry.withBuiltins();
    args.registerSources?.call(registry);
    final engine = DspEngine(out.send, options: args.options, registry: registry);
    final rx = ReceivePort('sdr-dsp-commands');
    out.send(<String, Object?>{DspMsg.evt: DspEvt.ready, 'port': rx.sendPort});
    engine.handle(const <Object?, Object?>{DspMsg.cmd: DspCmd.getState});

    Future<void> chain = Future<void>.value();
    rx.listen((dynamic msg) {
      if (msg is! Map) return;
      chain = chain.then((_) => engine.handle(msg)).then((_) {
        if (msg[DspMsg.cmd] == DspCmd.shutdown) {
          out.send(<String, Object?>{DspMsg.evt: DspEvt.closed});
          rx.close();
        }
      });
    });
  }
}

class DspCommandException implements Exception {
  DspCommandException(this.message);
  final String message;
  @override
  String toString() => message;
}
