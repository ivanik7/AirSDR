// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../legacy/centered_receiver.dart';
import '../legacy/step_grid.dart';
import '../legacy/theme.dart';
import 'decoder_session.dart';
import 'meshtastic_tuning.dart';

/// Receive-only regional quick tunes; decoder output is unavailable until the
/// upstream LoRa PHY/backend supplies a real native factory.
class MeshtasticModePanel extends StatelessWidget {
  const MeshtasticModePanel({super.key, required this.session,
      required this.receiver});
  final DecoderSession session;
  final CenteredReceiver receiver;

  @override
  Widget build(BuildContext context) {
    final preset = meshtasticPreset('LongFast');
    return Column(
      key: const ValueKey('decoderPanel-meshtastic'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        legacyCard(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Meshtastic · receive only', style: plex(size: 14)),
            const SizedBox(height: 4),
            Text(session.isAvailable('meshtastic')
                ? (session.failureReason ?? 'LoRa receiver selected')
                : 'Decoder unavailable: native LoRa PHY not installed',
                key: const ValueKey('meshtasticStatus'),
                style: plex(size: 12, color: LegacyColors.muted)),
            Text('LongFast: BW 250 kHz · SF11 · CR 4/5 · 1 MS/s IQ required',
                style: plex(size: 11, color: LegacyColors.muted)),
            if (session.isAvailable('meshtastic') && receiver.radio.sampleRate < 1000000)
              Text('Not ready: requires at least 1 MS/s source IQ',
                  style: plex(size: 12, color: LegacyColors.muted)),
          ],
        )),
        const SizedBox(height: 8),
        Text('LongFast region quick tune', style: plex(size: 14)),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final code in ['EU_868', 'US', 'RU'])
            Builder(builder: (context) {
              final region = meshtasticRegion(code);
              final channel = meshtasticChannelFrequency(region, preset);
              return OutlinedButton(
                key: ValueKey('meshtasticTune-$code'),
                onPressed: () {
                  try {
                    final tuned = tuneMeshtasticRegion(receiver, region, preset);
                    if (context.mounted && tuned != channel.frequencyHz) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:
                          Text('Receiver step snapped ${formatMhz(channel.frequencyHz)} '
                              'to ${formatMhz(tuned)} MHz')));
                    }
                  } on ArgumentError {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Frequency outside receiver range')));
                    }
                  }
                },
                child: Text('$code · ${formatMhz(channel.frequencyHz)} MHz'
                    '${channel.verified ? '' : ' · Unverified frequency'}'),
              );
            }),
        ]),
        const SizedBox(height: 8),
        Text('Firmware presets: ${meshtasticPresets.map((p) =>
            '${p.name} ${p.bandwidthHz / 1000}k/SF${p.sf}/4/${p.cr}'
            '${p.supported ? '' : ' (unsupported)'}').join(' · ')}',
            style: plex(size: 11, color: LegacyColors.muted)),
      ],
    );
  }
}
