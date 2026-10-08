// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../decoders/decoder_contract.dart';
import '../decoders/decoder_panels.dart';
import '../decoders/decoder_session.dart';
import '../radio_controller.dart';
import 'centered_receiver.dart';
import 'theme.dart';

/// Decoder tab: a selector (decoder_contract.dart `decoderCatalog`) plus
/// exactly one panel for the currently previewed decoder
/// (decoders/decoder_session.dart `DecoderSession`). Voice/audio
/// ([DecoderSession.voiceId]) is the pre-existing receiver-controls panel;
/// every other id is an honest unavailable-by-default placeholder until a
/// native decoder backend exists.
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
    builder: (context, _) {
      final selected = decoderById(session.selectedId);
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          Text('Decoder', style: plex(size: 22, weight: FontWeight.w600)),
          const SizedBox(height: 10),
          DecoderSelector(session: session),
          const SizedBox(height: 14),
          if (selected == null || session.selectedId == DecoderSession.voiceId)
            VoiceDecoderPanel(controller: controller, receiver: receiver)
          else
            DecoderPlaceholderPanel(descriptor: selected, session: session),
        ],
      );
    },
  );
}
