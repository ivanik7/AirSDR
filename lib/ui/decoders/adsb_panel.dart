// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../legacy/centered_receiver.dart';
import '../legacy/theme.dart';
import 'adsb_snapshot.dart';
import 'decoder_session.dart';

/// A complete native track snapshot replaces the list; no positions are guessed.
class AdsbPanel extends StatefulWidget {
  const AdsbPanel({super.key, required this.session, required this.receiver});
  final DecoderSession session;
  final CenteredReceiver receiver;

  @override
  State<AdsbPanel> createState() => _AdsbPanelState();
}

class _AdsbPanelState extends State<AdsbPanel> {
  static const _latKey = 'adsb.receiver.latitude';
  static const _lonKey = 'adsb.receiver.longitude';
  ReceiverLocation? _location;
  bool _byDistance = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _loadLocation();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          widget.session.active &&
          widget.session.adsbSnapshot != null) {
        setState(() {});
      }
    });
  }

  Future<void> _loadLocation() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final lat = prefs.getDouble(_latKey);
    final lon = prefs.getDouble(_lonKey);
    if (lat != null && lon != null) {
      setState(() => _location = ReceiverLocation.parse('$lat', '$lon'));
    }
  }

  Future<void> _editLocation() async {
    var latitude = _location?.latitude.toString() ?? '';
    var longitude = _location?.longitude.toString() ?? '';
    final result = await showDialog<ReceiverLocation?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Receiver coordinates (optional)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('adsbLatitude'),
                initialValue: latitude,
                onChanged: (value) => latitude = value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(labelText: 'Latitude (−90…90)'),
              ),
              TextFormField(
                key: const ValueKey('adsbLongitude'),
                initialValue: longitude,
                onChanged: (value) => longitude = value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Longitude (−180…180)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              const ReceiverLocation(double.nan, double.nan),
            ),
            child: const Text('Delete'),
          ),
          TextButton(
            onPressed: () {
              final value = ReceiverLocation.parse(latitude, longitude);
              if (value != null) Navigator.pop(context, value);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (result.latitude.isNaN) {
      await prefs.remove(_latKey);
      await prefs.remove(_lonKey);
      if (mounted) {
        setState(() {
          _location = null;
          _byDistance = false;
        });
      }
    } else {
      await prefs.setDouble(_latKey, result.latitude);
      await prefs.setDouble(_lonKey, result.longitude);
      if (mounted) setState(() => _location = result);
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final radio = session.radio;
    final available = session.isAvailable('adsb');
    final ready = session.adsbInputReady;
    final active = session.active && ready;
    final snapshot = active ? session.adsbSnapshot : null;
    final now = DateTime.now();
    final aircraft =
        snapshot?.sorted(_byDistance ? _location : null, now: now) ??
        const <AdsbAircraft>[];
    final rates = radio.selectedDevice?.sampleRates ?? const <double>[];
    final compatibleRates = rates.where((rate) => rate >= 2400000).toList()
      ..sort();
    final targetRate = compatibleRates.isEmpty ? null : compatibleRates.first;
    final canSetRate = targetRate != null && targetRate != radio.sampleRate;
    final canTune =
        radio.selectedDevice != null &&
        radio.selectedDevice!.minFrequency <= 1090000000 &&
        radio.selectedDevice!.maxFrequency >= 1090000000;
    return Column(
      key: const ValueKey('decoderPanel-adsb'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        legacyCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ADS-B · aircraft', style: plex(size: 14)),
              const SizedBox(height: 5),
              Text(
                !available
                    ? 'Unavailable in the current native build'
                    : !ready
                    ? 'not ready: set sample rate 2.4 MS/s'
                    : !radio.running
                    ? 'Reception stopped'
                    : session.failureReason ??
                          (active
                              ? 'Decoding active'
                              : 'Decoder not running'),
                key: const ValueKey('adsbStatus'),
                style: plex(
                  size: 12,
                  color: active ? LegacyColors.accent : LegacyColors.muted,
                ),
              ),
              if (!available)
                Text(
                  'Decoder unavailable in the current native build',
                  key: const ValueKey('decoderUnavailable-adsb'),
                  style: plex(size: 11, color: LegacyColors.danger),
                ),
              Text(
                'Messages/s: ${snapshot?.messageRate.toStringAsFixed(1) ?? '—'} · CRC fixed: ${snapshot?.crcFixed ?? '—'}',
                key: const ValueKey('adsbMessageRate'),
                style: plex(size: 11, color: LegacyColors.muted),
              ),
              Text(
                'IQ: ${session.inputRateHz} Hz · Dropped events: ${session.droppedEvents}',
                style: plex(size: 11, color: LegacyColors.muted),
              ),
              Wrap(
                spacing: 4,
                children: [
                  OutlinedButton(
                    key: const ValueKey('adsbSetRate'),
                    onPressed: !ready && canSetRate
                        ? () => radio.setSampleRate(targetRate)
                        : null,
                    child: Text(
                      targetRate == null
                          ? '2.4 MS/s'
                          : '${(targetRate / 1e6).toStringAsFixed(2)} MS/s',
                    ),
                  ),
                  if (!ready && radio.sampleRate >= 2400000)
                    OutlinedButton(
                      key: const ValueKey('adsbRecenter'),
                      onPressed: () =>
                          widget.receiver.tune(radio.tunedFrequency),
                      child: const Text('Center VFO'),
                    ),
                  OutlinedButton(
                    key: const ValueKey('adsbQuickTune'),
                    onPressed: canTune
                        ? () => widget.receiver.tune(1090000000)
                        : null,
                    child: const Text('1090 MHz'),
                  ),
                ],
              ),
              if (!ready && !canSetRate)
                Text(
                  'Choose a compatible source or sample rate in the receiver settings.',
                  style: plex(size: 11, color: LegacyColors.muted),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            Text('Aircraft · ${aircraft.length}', style: plex(size: 14)),
            TextButton(
              key: const ValueKey('adsbLocation'),
              onPressed: _editLocation,
              child: Text(
                _location == null
                    ? 'Location (optional)'
                    : 'Location: edit',
              ),
            ),
            if (_location != null)
              TextButton(
                key: const ValueKey('adsbSort'),
                onPressed: () => setState(() => _byDistance = !_byDistance),
                child: Text(_byDistance ? 'By distance' : 'By recency'),
              ),
          ],
        ),
        KeyedSubtree(
          key: const ValueKey('decoderResult-adsb'),
          child: aircraft.isEmpty
              ? legacyCard(
                  child: Text(
                    'Aircraft list is empty',
                    style: plex(size: 12, color: LegacyColors.muted),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: aircraft.length,
                  itemBuilder: (context, index) {
                    final item = aircraft[index];
                    final distance = _location == null
                        ? null
                        : item.distanceKm(_location!);
                    final age = now
                        .difference(item.lastSeen)
                        .inSeconds
                        .clamp(0, 300);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Opacity(
                        opacity: item.isStale(now) ? 0.55 : 1,
                        child: legacyCard(
                          child: Material(
                            type: MaterialType.transparency,
                            child: ExpansionTile(
                              key: ValueKey('adsbAircraft-${item.icao}'),
                              tilePadding: EdgeInsets.zero,
                              title: Text(
                                '${item.callsign ?? item.icao} · ${item.icao}',
                                style: plex(size: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${age}s ago${distance == null ? '' : ' · ${distance.toStringAsFixed(1)} km'}',
                                style: plex(size: 11),
                              ),
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    [
                                      'ICAO: ${item.icao}',
                                      if (item.callsign != null)
                                        'Callsign: ${item.callsign}',
                                      if (item.squawk != null)
                                        'Squawk: ${item.squawk}',
                                      if (item.altitudeFt != null)
                                        'Altitude: ${item.altitudeFt} ft',
                                      if (item.groundSpeedKt != null)
                                        'Speed: ${item.groundSpeedKt} kt',
                                      if (item.trackDeg != null)
                                        'Heading: ${item.trackDeg}°',
                                      if (item.verticalRateFpm != null)
                                        'Vertical rate: ${item.verticalRateFpm} ft/min',
                                      if (item.latitude != null)
                                        'Position: ${item.latitude}, ${item.longitude}',
                                      if (distance != null)
                                        'Distance: ${distance.toStringAsFixed(1)} km',
                                      'Messages: ${item.messages}',
                                      if (item.rssi != null)
                                        'RSSI: ${item.rssi} dBFS',
                                    ].join('\n'),
                                    style: plex(size: 12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
