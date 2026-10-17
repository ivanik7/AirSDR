// SPDX-License-Identifier: GPL-3.0-or-later
// Shared helpers for Meshtastic UI tests: real native parser events from
// fixtures/meshtastic_native_events.json (regenerated and checked by native
// ctest sdrcore_meshtastic_ui_fixture) and a recording decoder backend.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sdr_flutter/ui/decoders/decoder_contract.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';

Map<String, List<Map<String, Object?>>> loadNativeEvents() {
  final file = File('test/ui/fixtures/meshtastic_native_events.json');
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final g in data['groups'] as List)
      (g as Map)['name'] as String: [
        for (final e in g['events'] as List) (e as Map).cast<String, Object?>(),
      ],
  };
}

Map<String, Object?> event(String group, String fixture) =>
    loadNativeEvents()[group]!.firstWhere((e) => e['fixture'] == fixture);

class MeshBackend implements DecoderBackend {
  final calls = <(String?, Map<String, Object>)>[];
  final events = <DecoderEvent>[];
  @override
  Set<String> get availableIds => {'meshtastic', 'rtl_433'};
  @override
  bool select(String? id, Map<String, Object> config) {
    calls.add((id, config));
    return true;
  }

  @override
  DecoderEvent? poll(int afterSequence) {
    for (final e in events) {
      if (e.sequence > afterSequence) return e;
    }
    return null;
  }

  int _seq = 0;
  void add(Map<String, Object?> data, {int generation = 1}) => events.add(
    DecoderEvent(
      ++_seq,
      generation,
      DecoderResult.message,
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
    ),
  );
}

class MeshRadio extends DemoRadioController {
  MeshRadio(this.backend);
  final MeshBackend backend;
  @override
  DecoderBackend get decoderBackend => backend;
}
