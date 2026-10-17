// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../decoders/decoder_panels.dart';
import '../decoders/decoder_session.dart';
import '../radio_controller.dart';
import 'centered_receiver.dart';
import 'theme.dart';

/// Decoder selector plus exactly one panel for the selected decoder id
/// (see [decoderPanels]); panels of different decoders never coexist.
class DecoderScreen extends StatelessWidget {
  const DecoderScreen({
    super.key,
    required this.controller,
    required this.receiver,
    required this.session,
  });

  final RadioController controller;
  final CenteredReceiver receiver;
  final DecoderSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, session]),
    builder: (context, _) => ListView(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      children: [
        Text('Decoder', style: plex(size: 22, weight: FontWeight.w600)),
        const SizedBox(height: 10),
        DecoderSelector(session: session),
        const SizedBox(height: 14),
        buildDecoderPanel(
          selectedId: session.selectedId,
          controller: controller,
          receiver: receiver,
          session: session,
        ),
      ],
    ),
  );
}
