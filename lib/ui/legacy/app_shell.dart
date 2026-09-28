// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../runtime/sdr_radio_controller.dart';
import '../favorites/favorites.dart';
import '../radio_controller.dart';
import '../sdr_ui_state.dart';
import 'centered_receiver.dart';
import 'receive_screen.dart';
import 'presets_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

class LegacyAppShell extends StatefulWidget {
  const LegacyAppShell({super.key, required this.controller, this.favorites});
  final RadioController controller;
  final FavoritesRepository? favorites;
  @override
  State<LegacyAppShell> createState() => _LegacyAppShellState();
}

class _LegacyAppShellState extends State<LegacyAppShell> {
  late CenteredReceiver receiver;
  late SdrUiState spectrum;
  late FavoritesRepository favorites;
  bool ownFavorites = false;
  bool radioReady = false;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    _init();
  }

  void _init() {
    radioReady = widget.controller is! SdrRadioController;
    receiver = CenteredReceiver(widget.controller);
    spectrum = SdrUiState(widget.controller);
    favorites = widget.favorites ?? FavoritesRepository();
    ownFavorites = widget.favorites == null;
    // The production controller loads persisted LO/offset asynchronously.
    // Recenter only after ready, not before its first persisted state arrives.
    if (widget.controller case final SdrRadioController real) {
      real.ready.then((_) {
        if (mounted && identical(widget.controller, real)) {
          radioReady = true;
          receiver.resetOffset();
        }
      });
    } else {
      receiver.resetOffset();
    }
    favorites.load();
    widget.controller.addListener(_radioChanged);
  }

  void _radioChanged() {
    if (radioReady && !receiver.dragging && widget.controller.vfoOffset != 0) {
      receiver.resetOffset();
      return;
    }
    if (!widget.controller.running) spectrum.waterfall.clear();
  }

  @override
  void didUpdateWidget(LegacyAppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller &&
        oldWidget.favorites == widget.favorites) {
      return;
    }
    oldWidget.controller.removeListener(_radioChanged);
    spectrum.dispose();
    if (ownFavorites) favorites.dispose();
    _init();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_radioChanged);
    spectrum.dispose();
    if (ownFavorites) favorites.dispose();
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
