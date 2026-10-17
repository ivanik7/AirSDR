// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../decoders/decoder_contract.dart';
import '../decoders/decoder_panels.dart';
import '../decoders/decoder_session.dart';
import '../decoders/dmr_panel.dart';
import '../radio_controller.dart';
import 'centered_receiver.dart';
import 'theme.dart';

/// One flat choice list; v3 modes show live receiver controls and data
/// decoders show only their own result preview.
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
          if (selected?.id == 'rtl_433')
            Rtl433DecoderPanel(session: session)
          else if (selected?.id == 'dmr')
            DmrDecoderPanel(session: session)
          else if (selected == null || selected.voice)
            VoiceDecoderPanel(controller: controller, receiver: receiver)
          else
            DecoderPlaceholderPanel(descriptor: selected, session: session),
        ],
      );
    },
  );
}
