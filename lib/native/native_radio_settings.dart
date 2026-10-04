// SPDX-License-Identifier: GPL-3.0-or-later
//
// Persisted settings for [NativeRadioController] (docs/native-n2-adr.md,
// "N2 close-out: Android wiring and default engine").
//
// Pure-Dart model plus synchronous, never-throwing load/migrate/save
// functions, kept separate from the controller so they can be unit tested
// without any native/FFI dependency.
//
// File: `<configDir>/native_radio.json`. Holds the tuned frequency (center +
// VFO offset, so at rest it equals the center frequency), the demodulator
// mode, a per-mode bandwidth map (so switching modes restores the last
// bandwidth used in that mode instead of resetting to the default), the
// sample rate, gain, and squelch type/level/auto-offset. Mute is never
// persisted: every session starts muted. Volume is fixed at 1.0 by the
// controller and is not part of this file.
//
// Migration (first run, file absent): try the old Dart engine's
// `config.json` (+ `vfoOffsets.Radio`) and `radio_config.json`
// (lib/runtime/dsp_engine.dart, lib/sdrpp/modules/radio/radio_module.dart),
// else the L1 `linux_host_radio.json`
// (lib/platform/linux/host_iq_radio_controller.dart). Old files are never
// modified or deleted.
import 'dart:convert';
import 'dart:io';

import '../ui/radio_controller.dart';

/// Name of the persisted settings file inside `configDir`.
const String nativeRadioSettingsFileName = 'native_radio.json';

/// File format version of [nativeRadioSettingsFileName].
const int nativeRadioSettingsVersion = 1;

/// SDR++ demodulator name (`Demodulator.getName()`,
/// lib/sdrpp/modules/radio/demodulators/*.dart) per [DemodMode], used to
/// read the old engine's per-demod `radio_config.json` maps
/// (`conf['Radio'][<demodName>]`). Note NFM's name is `FM`, not `NFM`.
const Map<DemodMode, String> _legacyDemodName = <DemodMode, String>{
  DemodMode.wfm: 'WFM',
  DemodMode.nfm: 'FM',
  DemodMode.am: 'AM',
  DemodMode.usb: 'USB',
  DemodMode.lsb: 'LSB',
  DemodMode.dsb: 'DSB',
  DemodMode.cw: 'CW',
  DemodMode.raw: 'RAW',
};

/// Immutable, JSON-(de)serializable snapshot of the persisted radio settings.
class NativeRadioSettings {
  const NativeRadioSettings({
    required this.tunedFrequencyHz,
    required this.modeId,
    required this.bandwidthByMode,
    required this.sampleRateHz,
    required this.gainDb,
    required this.squelchKey,
    required this.squelchLevelDb,
    required this.autoOffsetDb,
  });

  factory NativeRadioSettings.defaults() => const NativeRadioSettings(
    tunedFrequencyHz: 100000000,
    modeId: 1, // DemodMode.wfm.id
    bandwidthByMode: <int, double>{},
    sampleRateHz: 2400000,
    gainDb: 20,
    squelchKey: 'off',
    squelchLevelDb: -50,
    autoOffsetDb: 0,
  );

  /// Tuned frequency in Hz (center frequency + VFO offset).
  final double tunedFrequencyHz;

  /// [DemodMode.id] of the last selected mode.
  final int modeId;

  /// Last bandwidth (Hz) used in each mode, keyed by [DemodMode.id].
  final Map<int, double> bandwidthByMode;

  final double sampleRateHz;
  final double gainDb;

  /// [SquelchType.key].
  final String squelchKey;
  final double squelchLevelDb;
  final double autoOffsetDb;

  DemodMode get mode => DemodMode.fromId(modeId);

  NativeRadioSettings copyWith({
    double? tunedFrequencyHz,
    int? modeId,
    Map<int, double>? bandwidthByMode,
    double? sampleRateHz,
    double? gainDb,
    String? squelchKey,
    double? squelchLevelDb,
    double? autoOffsetDb,
  }) => NativeRadioSettings(
    tunedFrequencyHz: tunedFrequencyHz ?? this.tunedFrequencyHz,
    modeId: modeId ?? this.modeId,
    bandwidthByMode: bandwidthByMode ?? this.bandwidthByMode,
    sampleRateHz: sampleRateHz ?? this.sampleRateHz,
    gainDb: gainDb ?? this.gainDb,
    squelchKey: squelchKey ?? this.squelchKey,
    squelchLevelDb: squelchLevelDb ?? this.squelchLevelDb,
    autoOffsetDb: autoOffsetDb ?? this.autoOffsetDb,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': nativeRadioSettingsVersion,
    'tunedFrequencyHz': tunedFrequencyHz,
    'modeId': modeId,
    'bandwidthByMode': <String, Object?>{
      for (final e in bandwidthByMode.entries) '${e.key}': e.value,
    },
    'sampleRateHz': sampleRateHz,
    'gainDb': gainDb,
    'squelchKey': squelchKey,
    'squelchLevelDb': squelchLevelDb,
    'autoOffsetDb': autoOffsetDb,
  };

  /// Parses a decoded JSON object, validating every field; any missing or
  /// invalid value falls back to the matching field of [NativeRadioSettings.defaults].
  /// Never throws.
  factory NativeRadioSettings._fromJson(Map<Object?, Object?> data) {
    final defaults = NativeRadioSettings.defaults();

    double numOr(Object? v, double fallback) =>
        (v is num && v.isFinite) ? v.toDouble() : fallback;

    final tuned = numOr(data['tunedFrequencyHz'], defaults.tunedFrequencyHz);

    // DemodMode.fromId already falls back to wfm for an unknown id, which
    // is exactly the "known mode id" validation this field needs.
    final modeIdRaw = data['modeId'];
    final mode = (modeIdRaw is num)
        ? DemodMode.fromId(modeIdRaw.toInt())
        : DemodMode.wfm;

    final bandwidthByMode = <int, double>{};
    final bwRaw = data['bandwidthByMode'];
    if (bwRaw is Map) {
      for (final entry in bwRaw.entries) {
        final id = int.tryParse('${entry.key}');
        if (id == null) continue;
        final entryMode = DemodMode.values.where((m) => m.id == id).firstOrNull;
        if (entryMode == null) continue;
        final value = entry.value;
        if (value is num && value.isFinite) {
          bandwidthByMode[id] = entryMode.params.clampBandwidth(
            value.toDouble(),
          );
        }
      }
    }

    final sampleRateRaw = data['sampleRateHz'];
    final sampleRate =
        (sampleRateRaw is num && sampleRateRaw.isFinite && sampleRateRaw > 0)
        ? sampleRateRaw.toDouble()
        : defaults.sampleRateHz;

    final gain = numOr(data['gainDb'], defaults.gainDb);

    var squelch = (data['squelchKey'] is String)
        ? SquelchType.fromKey(data['squelchKey'])
        : SquelchType.off;
    if (squelch == SquelchType.auto && mode.params.autoSquelch == null) {
      // Auto squelch is unavailable in this mode; never restore a state the
      // UI could not have produced for it.
      squelch = SquelchType.off;
    }

    final squelchLevel = numOr(
      data['squelchLevelDb'],
      defaults.squelchLevelDb,
    ).clamp(-100.0, 0.0).toDouble();
    final autoOffset = numOr(
      data['autoOffsetDb'],
      defaults.autoOffsetDb,
    ).clamp(-10.0, 20.0).toDouble();

    return NativeRadioSettings(
      tunedFrequencyHz: tuned,
      modeId: mode.id,
      bandwidthByMode: bandwidthByMode,
      sampleRateHz: sampleRate,
      gainDb: gain,
      squelchKey: squelch.key,
      squelchLevelDb: squelchLevel,
      autoOffsetDb: autoOffset,
    );
  }
}

String _settingsPath(String configDir) =>
    '$configDir${Platform.pathSeparator}$nativeRadioSettingsFileName';

/// Loads `<configDir>/native_radio.json`. Missing or corrupt -> migration
/// from the legacy Dart-engine files, else the L1 host file, else defaults.
/// A successful migration is written to `native_radio.json`. Never throws.
NativeRadioSettings loadNativeRadioSettings(String configDir) {
  try {
    final file = File(_settingsPath(configDir));
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        return NativeRadioSettings._fromJson(decoded);
      }
    }
  } catch (_) {
    // Corrupt file: fall through to migration/defaults, never throw.
  }

  NativeRadioSettings? migrated;
  try {
    migrated =
        migrateFromDartEngineFiles(configDir) ??
        migrateFromLinuxHostFile(configDir);
  } catch (_) {
    migrated = null;
  }
  if (migrated != null) {
    saveNativeRadioSettingsSync(configDir, migrated);
    return migrated;
  }
  return NativeRadioSettings.defaults();
}

/// Migrates from the old Dart engine's `config.json` (tuned frequency,
/// `sources.rtl_sdr` sample rate) and `radio_config.json` (selected mode,
/// per-mode bandwidth, squelch of the selected mode). Returns null if
/// neither file exists. Never modifies the legacy files. Never throws.
///
/// Gain is intentionally NOT migrated: `rtl_sdr_source.dart` stores gain as
/// an index into a hardware-discovered gain table (`gainList`, populated
/// from `RtlSdrDev.getTunerGains()`), which is not known without opening the
/// device; migrating the raw index as a dB value would be meaningless.
NativeRadioSettings? migrateFromDartEngineFiles(String configDir) {
  final coreFile = File('$configDir${Platform.pathSeparator}config.json');
  final radioFile = File(
    '$configDir${Platform.pathSeparator}radio_config.json',
  );
  final hasCore = coreFile.existsSync();
  final hasRadio = radioFile.existsSync();
  if (!hasCore && !hasRadio) return null;

  var settings = NativeRadioSettings.defaults();

  if (hasCore) {
    try {
      final data = jsonDecode(coreFile.readAsStringSync());
      if (data is Map) {
        final freq = data['frequency'];
        final vfoOffsets = data['vfoOffsets'];
        final offset = (vfoOffsets is Map && vfoOffsets['Radio'] is num)
            ? (vfoOffsets['Radio'] as num).toDouble()
            : 0.0;
        if (freq is num && freq.isFinite) {
          settings = settings.copyWith(
            tunedFrequencyHz: freq.toDouble() + offset,
          );
        }
        final sources = data['sources'];
        if (sources is Map && sources['rtl_sdr'] is Map) {
          final rtl = sources['rtl_sdr'] as Map;
          final devices = rtl['devices'];
          if (devices is Map) {
            for (final v in devices.values) {
              if (v is Map && v['sampleRate'] is num) {
                final sr = (v['sampleRate'] as num).toDouble();
                if (sr.isFinite && sr > 0) {
                  settings = settings.copyWith(sampleRateHz: sr);
                }
                break; // one Android USB device is expected
              }
            }
          }
        }
      }
    } catch (_) {
      // Keep whatever was already migrated; never throw.
    }
  }

  if (hasRadio) {
    try {
      final data = jsonDecode(radioFile.readAsStringSync());
      if (data is Map && data['Radio'] is Map) {
        final radio = data['Radio'] as Map;
        final selId = radio['selectedDemodId'];
        final mode = (selId is num)
            ? DemodMode.fromId(selId.toInt())
            : settings.mode;

        final bandwidthByMode = Map<int, double>.from(settings.bandwidthByMode);
        for (final entry in _legacyDemodName.entries) {
          final demodConf = radio[entry.value];
          if (demodConf is Map && demodConf['bandwidth'] is num) {
            final bw = (demodConf['bandwidth'] as num).toDouble();
            if (bw.isFinite) {
              bandwidthByMode[entry.key.id] = entry.key.params.clampBandwidth(
                bw,
              );
            }
          }
        }

        var squelch = SquelchType.off;
        double squelchLevel = settings.squelchLevelDb;
        double autoOffset = settings.autoOffsetDb;
        final selectedName = _legacyDemodName[mode];
        final selConf = selectedName != null ? radio[selectedName] : null;
        if (selConf is Map) {
          final sqMode = selConf['squelchMode'];
          if (sqMode is String) {
            squelch = switch (sqMode) {
              'off' => SquelchType.off,
              'auto' => SquelchType.auto,
              'power' || 'ctcss_mute' || 'ctcss_decode' => SquelchType.manual,
              _ => SquelchType.off,
            };
          } else if (selConf['squelchEnabled'] is bool) {
            squelch = (selConf['squelchEnabled'] as bool)
                ? SquelchType.manual
                : SquelchType.off;
          }
          if (squelch == SquelchType.auto && mode.params.autoSquelch == null) {
            // No auto-squelch detector for this mode in the current app;
            // fall back to the closest supported mode (manual power squelch).
            squelch = SquelchType.manual;
          }
          final level = selConf['squelchLevel'];
          if (level is num && level.isFinite) {
            squelchLevel = level.toDouble().clamp(-100.0, 0.0).toDouble();
          }
          final auto = selConf['squelchAutoOffset'];
          if (auto is num && auto.isFinite) {
            autoOffset = auto.toDouble().clamp(-10.0, 20.0).toDouble();
          }
        }

        settings = settings.copyWith(
          modeId: mode.id,
          bandwidthByMode: bandwidthByMode,
          squelchKey: squelch.key,
          squelchLevelDb: squelchLevel,
          autoOffsetDb: autoOffset,
        );
      }
    } catch (_) {
      // Keep whatever was already migrated; never throw.
    }
  }

  return settings;
}

/// Migrates from the L1 `linux_host_radio.json`
/// (lib/platform/linux/host_iq_radio_controller.dart). That file has no
/// squelch fields, so squelch stays at the default. Returns null if the file
/// is absent or unreadable. Never modifies the legacy file. Never throws.
NativeRadioSettings? migrateFromLinuxHostFile(String configDir) {
  final file = File('$configDir${Platform.pathSeparator}linux_host_radio.json');
  if (!file.existsSync()) return null;
  try {
    final data = jsonDecode(file.readAsStringSync());
    if (data is! Map) return null;
    var settings = NativeRadioSettings.defaults();

    final freq = data['frequency'];
    if (freq is num && freq.isFinite) {
      settings = settings.copyWith(tunedFrequencyHz: freq.toDouble());
    }
    final rate = data['sampleRate'];
    if (rate is num && rate.isFinite && rate > 0) {
      settings = settings.copyWith(sampleRateHz: rate.toDouble());
    }
    final gain = data['gain'];
    if (gain is num && gain.isFinite) {
      settings = settings.copyWith(gainDb: gain.toDouble());
    }

    var mode = DemodMode.wfm;
    final modeMap = data['mode'];
    if (modeMap is Map && modeMap['id'] is num) {
      mode = DemodMode.fromId((modeMap['id'] as num).toInt());
    }
    final bw = data['bandwidth'];
    final clampedBw = (bw is num && bw.isFinite)
        ? mode.params.clampBandwidth(bw.toDouble())
        : mode.params.defaultBandwidth;
    settings = settings.copyWith(
      modeId: mode.id,
      bandwidthByMode: <int, double>{
        ...settings.bandwidthByMode,
        mode.id: clampedBw,
      },
    );
    return settings;
  } catch (_) {
    return null;
  }
}

/// Writes `<configDir>/native_radio.json` atomically (temp file + rename).
/// Never throws.
void saveNativeRadioSettingsSync(
  String configDir,
  NativeRadioSettings settings,
) {
  try {
    final dir = Directory(configDir);
    dir.createSync(recursive: true);
    final target = File(_settingsPath(configDir));
    final tmp = File('${target.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(settings.toJson()));
    tmp.renameSync(target.path);
  } catch (_) {
    // Saving must never throw.
  }
}
