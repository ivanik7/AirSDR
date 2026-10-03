// Opt-in, no-audio USB IQ hardware diagnostic. Build with -t lib/n1_qa.dart only.
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MaterialApp(home: NativeQa()));

class NativeQa extends StatefulWidget {
  const NativeQa({super.key});

  @override
  State<NativeQa> createState() => _NativeQaState();
}

class _NativeQaState extends State<NativeQa> {
  static const usb = MethodChannel('sdr/usb');
  static const events = EventChannel('sdr/usb/events');
  String? device;
  String status = 'Idle';
  Timer? timer;
  StreamSubscription<dynamic>? subscription;
  bool pending = false;
  int polls = 0;

  @override
  void initState() {
    super.initState();
    subscription = events.receiveBroadcastStream().listen((event) {
      report('USB event $event');
      if (event is Map && event['event'] == 'detached') {
        timer?.cancel();
      }
    });
    discover();
  }

  void report(String message) {
    final line = '${DateTime.now().toUtc().toIso8601String()} N1QA $message';
    debugPrint(line);
    if (mounted) setState(() => status = line);
  }

  Future<Map<dynamic, dynamic>> command(String method, [Map<String, Object>? extra]) async {
    final args = <String, Object>{'deviceName': device!, ...?extra};
    final response = await usb.invokeMethod<Map<dynamic, dynamic>>(method, args);
    report('$method $response');
    return response ?? {};
  }

  Future<void> discover() async {
    try {
      final devices = await usb.invokeListMethod<Map<dynamic, dynamic>>('listDevices');
      final matches = devices?.where((d) => d['vid'] == 0x0bda && d['pid'] == 0x2838).toList() ?? [];
      if (matches.length != 1) throw StateError('Expected exactly one Blog V4: $devices');
      device = matches.single['deviceName'] as String;
      report('Blog V4 $device');
    } catch (e) {
      report('discover error $e');
    }
  }

  Future<void> run(String action, Future<void> Function() task) async {
    if (pending) return;
    setState(() => pending = true);
    try {
      if (device == null) await discover();
      if (device == null) throw StateError('Blog V4 not found');
      await task();
    } catch (e, stack) {
      report('$action error $e $stack');
    } finally {
      if (mounted) setState(() => pending = false);
    }
  }

  void ensureOk(Map<dynamic, dynamic> result, String method) {
    if (result['result'] != 0) throw StateError('$method failed: $result');
  }

  Future<void> openAndStart() => run('openAndStart', () async {
    ensureOk(await command('nativeOpen', {'source': 'rtlsdr'}), 'nativeOpen');
    ensureOk(await command('nativeConfigure', {
      'frequencyHz': 101400000,
      'samplesPerSecond': 2400000,
      'gainTenthsDb': 200,
    }), 'nativeConfigure');
    ensureOk(await command('nativeStart'), 'nativeStart');
    await stats();
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => stats());
  });

  Future<void> stats() async {
    if (device == null) return;
    try {
      final snapshot = await usb.invokeMethod<Map<dynamic, dynamic>>(
        'nativeStats', {'deviceName': device});
      report('poll=${++polls} stats=$snapshot');
    } catch (e) {
      report('stats error $e');
    }
  }

  Future<void> retuneAndRestart() => run('retuneAndRestart', () async {
    timer?.cancel();
    ensureOk(await command('nativeStop'), 'nativeStop');
    await stats();
    ensureOk(await command('nativeConfigure', {
      'frequencyHz': 99500000,
      'samplesPerSecond': 2400000,
      'gainTenthsDb': 380,
    }), 'nativeConfigure');
    ensureOk(await command('nativeStart'), 'nativeStart');
    await stats();
    timer = Timer.periodic(const Duration(seconds: 30), (_) => stats());
  });

  Future<void> close() => run('close', () async {
    timer?.cancel();
    ensureOk(await command('nativeClose'), 'nativeClose');
    await stats();
  });

  @override
  void dispose() {
    timer?.cancel();
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('N1 USB IQ diagnostic (no audio)')),
    body: SafeArea(child: Column(children: [
      for (final (label, action) in [
        ('Discover Blog V4', discover),
        ('Open + configure 2.4 MSPS + start', openAndStart),
        ('Stats', stats),
        ('Stop + retune 99.5 MHz/gain 38 dB + restart', retuneAndRestart),
        ('Close and release USB', close),
      ])
        Padding(padding: const EdgeInsets.all(8), child: ElevatedButton(
          onPressed: pending ? null : action,
          child: Text(label),
        )),
      Expanded(child: SingleChildScrollView(child: SelectableText(status))),
    ])),
  );
}
