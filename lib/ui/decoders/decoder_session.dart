// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shell-scoped preview/session state for the optional decoder backends
// (decoder_contract.dart). This class is UI-only and deliberately
// conservative:
//   * previewing a decoder NEVER changes the radio's frequency/mode, mutes
//     or starts audio — the voice path (normal demodulation + audio) keeps
//     running exactly as before regardless of what is previewed here;
//   * [RadioController.decoderBackend] is the only source of truth for real
//     availability ([availableIds]); an id the backend does not report is
//     never sent to [DecoderBackend.select], so a missing/placeholder
//     backend can never be "started";
//   * no event polling happens here — this session never synthesizes a fake
//     [DecoderEvent]; reading real decode results is future backend work.
import 'package:flutter/foundation.dart';

import '../radio_controller.dart';
import 'decoder_contract.dart';

class DecoderSession extends ChangeNotifier {
  DecoderSession(this.radio);
  final RadioController radio;

  static const String voiceId = 'voice';

  String _selectedId = voiceId;
  final Map<String, Map<String, Object>> _settings = {};

  /// Currently previewed decoder id. Always valid (defaults to [voiceId],
  /// the plain audio/demod path, which is not a backend decoder).
  String get selectedId => _selectedId;

  /// Ids the real backend reports as installed right now, plus [voiceId]
  /// (always available: it is the existing receive path, not a decoder
  /// engine). Empty backend availability never implies a fake capability.
  Set<String> get availableIds => <String>{
    voiceId,
    ...(radio.decoderBackend?.availableIds ?? const <String>{}),
  };

  bool isAvailable(String id) => availableIds.contains(id);

  /// A real backend with a compatible live audio input can accept settings.
  /// Installed full-band engines remain preview-only until explicit handoff.
  bool canConfigure(String id) => _canAttach(id);

  // Preview is never permission to displace the sole listening receiver.
  // Audio decoders may attach only to the matching already-running demod.
  // Exclusive decoders need an explicit receiver handoff (not implemented).
  bool _canAttach(String id) {
    final descriptor = decoderById(id);
    return descriptor != null &&
        !descriptor.exclusiveReceiver &&
        radio.running &&
        (descriptor.requiredMode == null ||
            descriptor.requiredMode == radio.mode.id) &&
        isAvailable(id);
  }

  Map<String, Object> _config(String id) => {
    'version': 1,
    'settings': settingsFor(id),
  };

  /// Fully resolved (defaulted) settings of decoder [id]; empty for an
  /// unknown id.
  Map<String, Object> settingsFor(String id) {
    final descriptor = decoderById(id);
    if (descriptor == null) return const <String, Object>{};
    final stored = _settings[id];
    return <String, Object>{
      for (final spec in descriptor.settings)
        spec.key: stored?[spec.key] ?? spec.defaultValue,
    };
  }

  /// Settings of the currently previewed decoder.
  Map<String, Object> get currentSettings => settingsFor(_selectedId);

  /// Switches the preview. An unknown id is ignored. Only a real, available
  /// id is ever handed to [DecoderBackend.select] — switching to an
  /// unavailable id (or back to [voiceId]) only updates local preview state
  /// and tells the backend (if any) to stop any previous data decoder.
  void selectPreview(String id) {
    if (decoderById(id) == null) return;
    if (id == _selectedId) return;
    _selectedId = id;
    final backend = radio.decoderBackend;
    if (backend != null) {
      if (id != voiceId && _canAttach(id)) {
        backend.select(id, _config(id));
      } else {
        backend.select(null, const <String, Object>{});
      }
    }
    notifyListeners();
  }

  /// Updates one setting of [id]'s preview; out-of-range values (per
  /// [DecoderSetting.allowed]) and unknown keys are ignored rather than
  /// stored invalid. Re-selects the backend only if [id] is both the
  /// current preview and actually available (never "starts" an
  /// unavailable decoder just because a setting changed).
  void setSetting(String id, String key, Object value) {
    final descriptor = decoderById(id);
    final spec = descriptor?.settings.where((s) => s.key == key).firstOrNull;
    if (spec == null) return;
    if (spec.allowed.isNotEmpty && !spec.allowed.contains(value)) return;
    final map = _settings.putIfAbsent(id, () => <String, Object>{});
    map[key] = value;
    final backend = radio.decoderBackend;
    if (backend != null &&
        id == _selectedId &&
        id != voiceId &&
        _canAttach(id)) {
      backend.select(id, _config(id));
    }
    notifyListeners();
  }

  /// Adopts a stored selection (e.g. a favorite/channel's saved decoder) as
  /// the new preview — used when applying a preset so the Decoder tab
  /// reflects what was saved with it. Still never starts an unavailable
  /// decoder; an unknown [id] or disallowed setting values fall back
  /// exactly like the favorites-storage normalization.
  void applyStored(String? id, Map<String, Object> settings) {
    final resolvedId = (id != null && decoderById(id) != null) ? id : voiceId;
    final descriptor = decoderById(resolvedId);
    final normalized = <String, Object>{
      for (final spec in descriptor?.settings ?? const <DecoderSetting>[])
        spec.key:
            (settings[spec.key] != null &&
                (spec.allowed.isEmpty ||
                    spec.allowed.contains(settings[spec.key])))
            ? settings[spec.key]!
            : spec.defaultValue,
    };
    _settings[resolvedId] = normalized;
    _selectedId = resolvedId;
    final backend = radio.decoderBackend;
    if (backend != null) {
      if (resolvedId != voiceId && _canAttach(resolvedId)) {
        backend.select(resolvedId, _config(resolvedId));
      } else {
        backend.select(null, const <String, Object>{});
      }
    }
    notifyListeners();
  }
}
