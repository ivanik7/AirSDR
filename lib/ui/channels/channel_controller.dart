// SPDX-License-Identifier: GPL-3.0-or-later
//
// Binds the channel slots to the single receiver:
//   * selecting a slot tunes the receiver (CenteredReceiver: tune + mode,
//     centered);
//   * while a slot is active, the receiver's resting frequency/mode is written
//     back into that slot only (not during a drag — once, on release).
import '../favorites/favorites.dart';
import '../legacy/centered_receiver.dart';
import '../legacy/presets_screen.dart' show favoriteErrorText;
import '../radio_controller.dart';
import 'channels.dart';

class ChannelController {
  ChannelController({
    required this.radio,
    required this.receiver,
    required this.channels,
    required this.favorites,
  });
  final RadioController radio;
  final CenteredReceiver receiver;
  final ChannelsRepository channels;
  final FavoritesRepository favorites;

  bool _attached = false;
  bool _applying = false;

  /// True once the persisted active slot has been applied to the receiver;
  /// before that nothing is written back (the backend may still be loading
  /// its own persisted state).
  bool get attached => _attached;

  /// Tunes the receiver to the (restored) active slot and starts write-back.
  /// With [seedFirstRun], a first launch (nothing stored yet) gets one slot
  /// holding the current frequency/mode, like the old UI's initial channel.
  void attach({bool seedFirstRun = false}) {
    if (_attached) return;
    _attached = true;
    if (seedFirstRun && !channels.hadStoredData && channels.length == 0) {
      add();
    }
    final c = channels.active;
    if (c != null && !_apply(c)) {
      // Out of range for this device: keep the slot as stored, stop driving.
      _applying = true;
      channels.activate(null);
      _applying = false;
    }
    onRadioChanged();
  }

  bool _inRange(int hz) {
    final d = radio.selectedDevice;
    return hz > 0 &&
        hz >= (d?.minFrequency ?? 1) &&
        hz <= (d?.maxFrequency ?? 999999999999);
  }

  bool _apply(ReceiverChannel c) {
    if (!_inRange(c.frequencyHz)) return false;
    _applying = true;
    try {
      receiver.apply(c.frequencyHz, c.mode);
    } on ArgumentError {
      return false;
    } finally {
      _applying = false;
    }
    return true;
  }

  /// Tap on a tile. Returns false when the slot cannot be tuned (out of the
  /// device range); then nothing changes.
  bool select(String id) {
    final i = channels.indexOf(id);
    if (i < 0) return false;
    final c = channels.channels[i];
    if (!_inRange(c.frequencyHz)) return false;
    _applying = true;
    channels.activate(id);
    _applying = false;
    return _apply(c);
  }

  /// "+ канал": a new slot with the current frequency/mode, made active.
  ReceiverChannel add() {
    final hz = radio.tunedFrequency.round();
    final preset = favorites.entries
        .where((f) => f.frequencyHz == hz)
        .firstOrNull;
    return channels.add(
      frequencyHz: hz,
      mode: radio.mode,
      name:
          preset?.name ??
          '${radio.mode.label} ${(hz / 1000000).toStringAsFixed(3)}',
    );
  }

  /// Deletes a slot; if it was active, the neighbour becomes active and the
  /// receiver follows it. Without slots left the receiver stays where it is.
  void delete(String id) {
    final wasActive = channels.activeId == id;
    _applying = true;
    channels.delete(id);
    _applying = false;
    final next = channels.active;
    if (wasActive && next != null && !_apply(next)) {
      _applying = true;
      channels.activate(null);
      _applying = false;
    }
  }

  void rename(String id, String name) => channels.rename(id, name);

  void move(String id, int toIndex) => channels.move(id, toIndex);

  /// Saves a slot into the presets. Returns an error text or null.
  String? saveAsPreset(String id) {
    final i = channels.indexOf(id);
    if (i < 0) return 'канал не найден';
    final c = channels.channels[i];
    try {
      favorites.add(
        frequencyHz: c.frequencyHz,
        name: c.name,
        mode: c.mode,
        category: presetCategoryFor(c.frequencyHz, c.mode),
      );
      return null;
    } on ArgumentError catch (e) {
      return favoriteErrorText(e);
    }
  }

  /// Receiver → active slot. Called on every radio notification.
  void onRadioChanged() {
    if (!_attached || _applying || receiver.dragging) return;
    if (radio.vfoOffset != 0) return; // not at rest yet (centering pending)
    channels.updateActive(
      frequencyHz: radio.tunedFrequency.round(),
      mode: radio.mode,
    );
  }
}

/// Preset category for a channel (the favorites list needs one).
String presetCategoryFor(int hz, DemodMode mode) {
  if (mode == DemodMode.wfm || (hz >= 87500000 && hz <= 108000000)) {
    return 'FM';
  }
  if (hz >= 108000000 && hz <= 137000000) return 'AIR';
  if (hz >= 156000000 && hz <= 163000000) return 'MAR';
  if (hz >= 300000000) return 'UHF';
  return 'VHF';
}
