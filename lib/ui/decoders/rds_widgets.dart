// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../radio_controller.dart';
import '../legacy/theme.dart';
import 'decoder_contract.dart';
import 'decoder_session.dart';

/// RDS station details and the RBDS switch; shown only by the WFM decoder
/// panel, never on the Receive screen.
class RdsDetailsPanel extends StatelessWidget {
  const RdsDetailsPanel({super.key, required this.session});
  final DecoderSession session;

  @override
  Widget build(BuildContext context) {
    final station = session.rds;
    final fields = station.fields;
    final af = fields['alt_frequencies_a'] ?? fields['alt_frequencies_b'];
    final di = fields['di'];
    final labels = <String, Object?>{
      'PI': station.text('pi'),
      'PS': station.text('ps'),
      'RadioText': station.text('radiotext'),
      'PTY': station.text('prog_type'),
      'TP': fields['tp'],
      'TA': fields['ta'],
      'Музыка': fields['is_music'],
      'DI / стерео': di is Map ? di['stereo'] ?? di : di,
      'AF (кГц)': af,
      'Страна': fields['country'],
      'CT': fields['clock_time'],
      'Позывной': fields['callsign'],
      'RT+': fields['radiotext_plus'],
      'BLER': station.bler,
    };
    return Column(
      key: const ValueKey('rdsDetails'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          'RDS · ${station.synced ? 'синхронизация' : 'нет сигнала'}',
          key: const ValueKey('rdsSync'),
          style: plex(size: 14),
        ),
        for (final entry in labels.entries)
          if (entry.value != null)
            Text(
              '${entry.key}: ${entry.value}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: plex(size: 12),
            ),
        if (session.rbdsAvailable)
          SwitchListTile(
            key: const ValueKey('rdsRbds'),
            contentPadding: EdgeInsets.zero,
            title: const Text('RBDS (США)'),
            value:
                session.settingsFor(decoderIdForMode(DemodMode.wfm))['rbds'] ==
                true,
            onChanged: (value) => session.setSetting(
              decoderIdForMode(DemodMode.wfm),
              'rbds',
              value,
            ),
          )
        else
          Text(
            'RBDS недоступен в текущем нативном приёмнике',
            style: plex(size: 11, color: LegacyColors.muted),
          ),
      ],
    );
  }
}
