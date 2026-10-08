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
import '../legacy/step_grid.dart' show formatMhz;
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
  bool _scanning = false;
  bool _scanApplying = false;
  void Function()? cancelScan;

  bool get scanning => _scanning;
  void setScanning(bool value) => _scanning = value;

  /// Retune without activating or rewriting the selected slot. Band settings
  /// are never applied while scanning (the slot's own mode, current step).
  bool scanTo(ReceiverChannel c) {
    if (!_inRange(c.frequencyHz)) return false;
    _scanApplying = true;
    try {
      return _apply(c, restore: true);
    } finally {
      _scanApplying = false;
    }
  }

  void manualChange() {
    if (!_scanApplying) cancelScan?.call();
  }

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
    // Restoring the stored slot is not a band entry: the persisted step and
    // the slot's mode stay.
    if (c != null && !_apply(c, restore: true)) {
      // Out of range for this device: keep the slot as stored, stop driving.
      _applying = true;
      channels.activate(null);
      _applying = false;
    }
    if (c == null) receiver.markCurrentBand();
    onRadioChanged();
  }

  bool _inRange(int hz) {
    final d = radio.selectedDevice;
    return hz > 0 &&
        hz >= (d?.minFrequency ?? 1) &&
        hz <= (d?.maxFrequency ?? 999999999999);
  }

  /// [restore]: stored state / scanning (no band settings); otherwise a user
  /// selection (slot mode wins, band step on band entry).
  bool _apply(ReceiverChannel c, {bool restore = false}) {
    if (!_inRange(c.frequencyHz)) return false;
    _applying = true;
    try {
      if (restore) {
        receiver.restore(c.frequencyHz, c.mode);
      } else {
        receiver.apply(c.frequencyHz, c.mode);
      }
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
    cancelScan?.call();
    final i = channels.indexOf(id);
    if (i < 0) return false;
    final c = channels.channels[i];
    if (!_inRange(c.frequencyHz)) return false;
    _applying = true;
    channels.activate(id);
    _applying = false;
    return _apply(c);
  }

  /// Name shown for a slot. Channels have no names of their own: it is the
  /// name of the preset at exactly the same frequency (Hz), otherwise
  /// `<mode> <MHz>`. Stored names (older versions allowed renaming) are
  /// ignored, so the rule also holds for migrated slots.
  String displayName(ReceiverChannel c) =>
      channelDisplayName(c.frequencyHz, c.mode, favorites.entries);

  /// The second line of a tile is reserved for a matching preset only.
  String tileName(ReceiverChannel c) =>
      favorites.entries
          .where((f) => f.frequencyHz == c.frequencyHz)
          .firstOrNull
          ?.name ??
      '';

  /// "+ канал": a new slot with the current frequency/mode, made active.
  ReceiverChannel add() {
    cancelScan?.call();
    final hz = radio.tunedFrequency.round();
    return channels.add(
      frequencyHz: hz,
      mode: radio.mode,
      // Kept only for the storage format; the UI shows [displayName].
      name: channelDisplayName(hz, radio.mode, favorites.entries),
    );
  }

  /// Deletes a slot; if it was active, the neighbour becomes active and the
  /// receiver follows it. Without slots left the receiver stays where it is.
  void delete(String id) {
    cancelScan?.call();
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

  void move(String id, int toIndex) {
    cancelScan?.call();
    channels.move(id, toIndex);
  }

  /// Saves a slot into the presets under [name] (default: the slot's shown
  /// name). Returns an error text or null. [decoderId]/[decoderSettings]
  /// carry over a decoder currently previewed for this receiver (the
  /// Decoder tab's [DecoderSession]) so the new preset reopens with the
  /// same preview; null/omitted means plain voice/audio, same as before
  /// this parameter existed.
  String? saveAsPreset(
    String id, {
    String? name,
    String? decoderId,
    Map<String, Object>? decoderSettings,
  }) {
    final i = channels.indexOf(id);
    if (i < 0) return 'канал не найден';
    final c = channels.channels[i];
    try {
      favorites.add(
        frequencyHz: c.frequencyHz,
        name: name ?? displayName(c),
        mode: c.mode,
        category: presetCategoryFor(c.frequencyHz, c.mode),
        decoderId: decoderId,
        decoderSettings: decoderSettings,
      );
      return null;
    } on ArgumentError catch (e) {
      return favoriteErrorText(e);
    }
  }

  /// Receiver → active slot. Called on every radio notification.
  void onRadioChanged() {
    if (!_attached || _applying || _scanning || receiver.dragging) return;
    if (radio.vfoOffset != 0) return; // not at rest yet (centering pending)
    channels.updateActive(
      frequencyHz: radio.tunedFrequency.round(),
      mode: radio.mode,
    );
  }
}

/// See [ChannelController.displayName].
String channelDisplayName(int hz, DemodMode mode, Iterable<Favorite> presets) =>
    presets.where((f) => f.frequencyHz == hz).firstOrNull?.name ??
    '${mode.label} ${formatMhz(hz)}';

/// Storage category of a preset created from a channel. The Пресеты tab
/// groups presets by band (bands.dart) and no longer shows categories; the
/// field is kept only so the favorites storage format stays readable by older
/// builds, so any valid category would do. Kept deterministic by frequency.
String presetCategoryFor(int hz, DemodMode mode) {
  if (mode == DemodMode.wfm || (hz >= 87500000 && hz <= 108000000)) {
    return 'FM';
  }
  if (hz >= 108000000 && hz <= 137000000) return 'AIR';
  if (hz >= 156000000 && hz <= 163000000) return 'MAR';
  if (hz >= 300000000) return 'UHF';
  return 'VHF';
}
