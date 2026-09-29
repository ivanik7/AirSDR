// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../runtime/sdr_radio_controller.dart';
import '../channels/channel_controller.dart';
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
    this.openReceive,
  });
  final RadioController controller;
  final FavoritesRepository? favorites;
  final ChannelsRepository? channels;
  final Listenable? openReceive;
  @override
  State<LegacyAppShell> createState() => _LegacyAppShellState();
}

class _LegacyAppShellState extends State<LegacyAppShell> {
  late CenteredReceiver receiver;
  late SdrUiState spectrum;
  late FavoritesRepository favorites;
  late ChannelsRepository channelSlots;
  late ChannelController channels;
  late SignalMeter meter;
  bool ownFavorites = false;
  bool ownChannels = false;
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
    radioReady = widget.controller is! SdrRadioController;
    receiver = CenteredReceiver(widget.controller);
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
    meter = SignalMeter(widget.controller);
    final radio = widget.controller;
    final slots = channelSlots;
    final bound = channels;
    final boundReceiver = receiver;
    // The step (= frequency grid) is persisted; snapping waits for it.
    final stepLoaded = receiver.loadStep();
    // The production controller loads persisted LO/offset asynchronously.
    // Recenter only after ready, not before its first persisted state arrives.
    final Future<void> radioLoaded;
    if (radio case final SdrRadioController real) {
      radioLoaded = Future.wait([real.ready, stepLoaded]).then((_) {
        if (mounted && identical(widget.controller, real)) {
          radioReady = true;
          receiver.resetOffset();
        }
      });
    } else {
      receiver.resetOffset();
      radioLoaded = stepLoaded.then((_) {
        if (mounted && identical(receiver, boundReceiver)) {
          receiver.resetOffset();
          setState(() {});
        }
      });
    }
    favorites.load();
    // The active channel drives the receiver only once both the radio's own
    // persisted state and the stored channel list are in.
    final slotsLoaded = slots.loaded ? Future<void>.value() : slots.load();
    Future.wait([radioLoaded, slotsLoaded]).then((_) {
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

  @override
  void didUpdateWidget(LegacyAppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openReceive != widget.openReceive) {
      oldWidget.openReceive?.removeListener(_showReceive);
      widget.openReceive?.addListener(_showReceive);
    }
    if (oldWidget.controller == widget.controller &&
        oldWidget.favorites == widget.favorites &&
        oldWidget.channels == widget.channels) {
      return;
    }
    oldWidget.controller.removeListener(_radioChanged);
    receiver.dispose();
    spectrum.dispose();
    meter.dispose();
    if (ownFavorites) favorites.dispose();
    if (ownChannels) channelSlots.dispose();
    _init();
  }

  @override
  void dispose() {
    widget.openReceive?.removeListener(_showReceive);
    widget.controller.removeListener(_radioChanged);
    receiver.dispose();
    spectrum.dispose();
    meter.dispose();
    if (ownFavorites) favorites.dispose();
    if (ownChannels) channelSlots.dispose();
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
                  channels: channels,
                  meter: meter,
                ),
                PresetsScreen(
                  controller: widget.controller,
                  receiver: receiver,
                  favorites: favorites,
                  onApplied: () => setState(() => tab = 0),
                ),
                SettingsScreen(
                  controller: widget.controller,
                  receiver: receiver,
                  spectrum: spectrum,
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
