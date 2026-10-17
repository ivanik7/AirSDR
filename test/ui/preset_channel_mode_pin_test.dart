// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Save as preset" from a channel tile must carry an explicit
// voice/demod-mode decoder id (decoderIdForMode) when the preset is
// created from the actively-receiving channel in plain voice (never an
// implicit/ambiguous "no decoder" for the one channel that was truly
// live); an inactive channel keeps using its own stored mode only, never
// contaminated by whatever preview belongs to the currently tuned
// receiver.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/channels/channels.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/app_shell.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> saveAsPresetViaLongPress(
    WidgetTester tester,
    String channelId,
    String name,
  ) async {
    await tester.longPress(find.byKey(ValueKey('channel-$channelId')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save as preset'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('presetName')), name);
    await tester.tap(find.byKey(const ValueKey('presetNameSave')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the actively-receiving channel in plain voice saves with an explicit '
    'mode-pinned decoderId',
    (tester) async {
      final radio = DemoRadioController();
      final favorites = FavoritesRepository();
      await favorites.load();
      final channels = ChannelsRepository();
      await channels.load();
      channels.add(frequencyHz: 145500000, mode: DemodMode.nfm, name: 'A');
      channels.add(frequencyHz: 433500000, mode: DemodMode.am, name: 'B');
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(
            controller: radio,
            favorites: favorites,
            channels: channels,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The last-added channel (B) is active and drives the receiver.
      final active = channels.active!;
      expect(active.frequencyHz, 433500000);
      expect(radio.tunedFrequency, 433500000);
      expect(radio.mode, DemodMode.am);

      await saveAsPresetViaLongPress(tester, active.id, 'Active voice save');
      final saved = favorites.entries.firstWhere(
        (e) => e.name == 'Active voice save',
      );
      expect(saved.frequencyHz, 433500000);
      expect(saved.mode, DemodMode.am);
      expect(
        saved.decoderId,
        decoderIdForMode(DemodMode.am),
        reason: 'the live channel pins its receive mode explicitly',
      );
      expect(saved.decoderSettings, isEmpty);

      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
      channels.dispose();
    },
  );

  testWidgets(
    'an inactive channel saves with its own stored mode and no explicit '
    'decoderId, even though the receiver is tuned elsewhere',
    (tester) async {
      final radio = DemoRadioController();
      final favorites = FavoritesRepository();
      await favorites.load();
      final channels = ChannelsRepository();
      await channels.load();
      channels.add(frequencyHz: 145500000, mode: DemodMode.nfm, name: 'A');
      channels.add(frequencyHz: 433500000, mode: DemodMode.am, name: 'B');
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyAppShell(
            controller: radio,
            favorites: favorites,
            channels: channels,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // B is active (receiver tuned to AM 433.5); A is inactive NFM.
      final inactive = channels.channels.first;
      expect(inactive.frequencyHz, 145500000);
      expect(inactive.mode, DemodMode.nfm);
      expect(channels.activeId, isNot(inactive.id));
      expect(radio.mode, DemodMode.am, reason: 'receiver is on B, not A');

      await saveAsPresetViaLongPress(
        tester,
        inactive.id,
        'Inactive channel save',
      );
      final saved = favorites.entries.firstWhere(
        (e) => e.name == 'Inactive channel save',
      );
      expect(saved.frequencyHz, 145500000);
      expect(
        saved.mode,
        DemodMode.nfm,
        reason: "uses the channel's own mode, not the active receiver's",
      );
      expect(saved.decoderId, isNull);

      await tester.pumpWidget(const SizedBox());
      radio.dispose();
      favorites.dispose();
      channels.dispose();
    },
  );
}
