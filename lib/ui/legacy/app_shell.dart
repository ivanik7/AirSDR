// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../bands/bands.dart';
import '../channels/channel_controller.dart';
import '../channels/channel_scanner.dart';
import '../channels/channels.dart';
import '../channels/signal_meter.dart';
import '../favorites/favorites.dart';
import '../radio_controller.dart';
import '../sdr_ui_state.dart';
import 'centered_receiver.dart';
import 'receive_screen.dart';
import 'presets_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

class LegacyAppShell extends StatefulWidget {
  const LegacyAppShell({
    super.key,
    required this.controller,
    this.favorites,
    this.channels,
    this.bands,
    this.openReceive,
  });
  final RadioController controller;
  final FavoritesRepository? favorites;
  final ChannelsRepository? channels;
  final BandsRepository? bands;
  final Listenable? openReceive;
  @override
  State<LegacyAppShell> createState() => _LegacyAppShellState();
}

class _LegacyAppShellState extends State<LegacyAppShell> {
  late CenteredReceiver receiver;
  late SdrUiState spectrum;
  late FavoritesRepository favorites;
  late BandsRepository bands;
  late ChannelsRepository channelSlots;
  late ChannelController channels;
  late ChannelScanner scanner;
  late SignalMeter meter;
  bool ownFavorites = false;
  bool ownChannels = false;
  bool ownBands = false;
  bool radioReady = false;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    widget.openReceive?.addListener(_showReceive);
    _init();
  }

  void _showReceive() => setState(() => tab = 0);

  void _init() {
    radioReady = true;
    receiver = CenteredReceiver(widget.controller);
    bands = widget.bands ?? BandsRepository();
    ownBands = widget.bands == null;
    receiver.bands = bands;
    spectrum = SdrUiState(widget.controller, centerDisplayOnVfo: true);
    spectrum.loadSettings();
    favorites = widget.favorites ?? FavoritesRepository();
    ownFavorites = widget.favorites == null;
    channelSlots = widget.channels ?? ChannelsRepository();
    ownChannels = widget.channels == null;
    channels = ChannelController(
      radio: widget.controller,
      receiver: receiver,
      channels: channelSlots,
      favorites: favorites,
    );
    scanner = ChannelScanner(controller: channels);
    scanner.addListener(_scannerChanged);
    meter = SignalMeter(widget.controller);
    final radio = widget.controller;
    final slots = channelSlots;
    final bound = channels;
    final boundReceiver = receiver;
    // The step (= frequency grid) is persisted; snapping waits for it.
    final stepLoaded = receiver.loadStep();
    // NativeRadioController loads persisted tuning before its first device scan.
    receiver.resetOffset();
    final radioLoaded = stepLoaded.then((_) {
      if (mounted && identical(receiver, boundReceiver)) {
        receiver.resetOffset();
        setState(() {});
      }
    });
    favorites.load();
    final bandsLoaded = bands.load();
    // The active channel drives the receiver only once the radio's own
    // persisted state, the stored channel list and the bands are in (attach
    // marks the restored frequency's band as entered, without applying it).
    final slotsLoaded = slots.loaded ? Future<void>.value() : slots.load();
    Future.wait([radioLoaded, slotsLoaded, bandsLoaded]).then((_) {
      if (mounted && identical(channels, bound)) {
        bound.attach(seedFirstRun: true);
      }
    });
    radio.addListener(_radioChanged);
  }

  void _radioChanged() {
    // Resting receiver: LO centered on the VFO and on the step grid.
    if (radioReady && !receiver.dragging && receiver.needsRecenter) {
      receiver.resetOffset();
      return;
    }
    channels.onRadioChanged();
    if (!widget.controller.running) spectrum.waterfall.clear();
  }

  void _scannerChanged() {
    spectrum.holdDisplayAt(
      scanner.active ? channelSlots.active?.frequencyHz.toDouble() : null,
    );
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(LegacyAppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openReceive != widget.openReceive) {
      oldWidget.openReceive?.removeListener(_showReceive);
      widget.openReceive?.addListener(_showReceive);
    }
    if (oldWidget.controller == widget.controller &&
        oldWidget.favorites == widget.favorites &&
        oldWidget.channels == widget.channels &&
        oldWidget.bands == widget.bands) {
      return;
    }
    oldWidget.controller.removeListener(_radioChanged);
    scanner.removeListener(_scannerChanged);
    scanner.dispose();
    receiver.dispose();
    spectrum.dispose();
    meter.dispose();
    if (ownFavorites) favorites.dispose();
    if (ownChannels) channelSlots.dispose();
    if (ownBands) bands.dispose();
    _init();
  }

  @override
  void dispose() {
    widget.openReceive?.removeListener(_showReceive);
    widget.controller.removeListener(_radioChanged);
    scanner.removeListener(_scannerChanged);
    scanner.dispose();
    receiver.dispose();
    spectrum.dispose();
    meter.dispose();
    if (ownFavorites) favorites.dispose();
    if (ownChannels) channelSlots.dispose();
    if (ownBands) bands.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: tab,
              children: [
                ReceiveScreen(
                  controller: widget.controller,
                  receiver: receiver,
                  spectrum: spectrum,
                  favorites: favorites,
                  bands: bands,
                  channels: channels,
                  scanner: scanner,
                  meter: meter,
                ),
                PresetsScreen(
                  controller: widget.controller,
                  receiver: receiver,
                  favorites: favorites,
                  bands: bands,
                  onApplied: () => setState(() => tab = 0),
                ),
                SettingsScreen(
                  controller: widget.controller,
                  receiver: receiver,
                  spectrum: spectrum,
                  bands: bands,
                ),
              ],
            ),
          ),
          Container(
            height: 64,
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: LegacyColors.key)),
            ),
            child: Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Expanded(
                    child: InkWell(
                      key: ValueKey('tab-$i'),
                      onTap: () => setState(() => tab = i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 18,
                            height: 3,
                            color: tab == i
                                ? LegacyColors.accent
                                : LegacyColors.muted,
                          ),
                          const SizedBox(height: 5),
                          Text(
                            ['Приём', 'Пресеты', 'Настройки'][i],
                            style: plex(
                              size: 12,
                              color: tab == i
                                  ? LegacyColors.accent
                                  : LegacyColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
