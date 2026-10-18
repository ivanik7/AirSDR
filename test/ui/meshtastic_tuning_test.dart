// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:sdr_flutter/ui/decoders/meshtastic_tuning.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';

void main() {
  test('firmware modem presets retain bandwidth spreading and coding', () {
    expect(meshtasticPresets.length, 16);
    expect(meshtasticPreset('LongFast').bandwidthHz, 250000);
    expect(meshtasticPreset('LongFast').sf, 11);
    expect(meshtasticPreset('LongFast').cr, 5);
    expect(meshtasticPreset('MediumSlow').bandwidthHz, 250000);
    expect(meshtasticPreset('ShortFast').bandwidthHz, 250000);
    expect(meshtasticPreset('LongMod').cr, 8);
    expect(meshtasticPreset('NarrowFast').bandwidthHz, 62500);
    expect(meshtasticPreset('LongSlow').supported, isFalse);
    expect(meshtasticPreset('TinyFast').supported, isFalse);
  });

  test('firmware slot hash yields checked LongFast centers', () {
    final preset = meshtasticPreset('LongFast');
    final eu = meshtasticChannelFrequency(meshtasticRegion('EU_868'), preset);
    final us = meshtasticChannelFrequency(meshtasticRegion('US'), preset);
    expect(eu.frequencyHz, 869525000);
    expect(eu.verified, isTrue);
    expect(us.frequencyHz, 906875000);
    expect(us.verified, isTrue);
    final ru = meshtasticChannelFrequency(meshtasticRegion('RU'), preset);
    expect(ru.frequencyHz, 869075000);
    expect(ru.verified, isFalse);
    expect(ru.verificationLabel, contains('Unverified'));
    final other = meshtasticChannelFrequency(meshtasticRegion('US'), preset,
        channelName: 'Ops');
    expect(other.verified, isFalse);
    expect(other.frequencyHz, isNot(us.frequencyHz));
  });

  test('Kazakhstan regions follow firmware v2.8.1 RDEF(KZ_433/KZ_863)', () {
    final preset = meshtasticPreset('LongFast');
    final kz863 = meshtasticRegion('KZ_863');
    expect(kz863.startHz, 863000000);
    expect(kz863.endHz, 868000000);
    final c863 = meshtasticChannelFrequency(kz863, preset);
    // 20 slots of 250 kHz; djb2("LongFast") % 20 + 1 = 16.
    expect(c863.slot, 16);
    expect(c863.frequencyHz, 866875000);
    expect(c863.verified, isFalse);
    final c433 = meshtasticChannelFrequency(meshtasticRegion('KZ_433'), preset);
    // round(1.7 MHz / 250 kHz) = 7 slots; hash slot 6.
    expect(c433.slot, 6);
    expect(c433.frequencyHz, 434450000);
    expect(c433.verified, isFalse);
    expect(kz863.presets, contains('ShortTurbo'));
    expect(kz863.presets, isNot(contains('LiteFast')));
  });

  test('override slots and preset restrictions are not silently changed', () {
    final narrow = meshtasticChannelFrequency(
        meshtasticRegion('EU_N_868'), meshtasticPreset('NarrowSlow'));
    expect(narrow.slot, 1);
    expect(narrow.frequencyHz, 869441650);
    expect(
        () => meshtasticChannelFrequency(
            meshtasticRegion('EU_868'), meshtasticPreset('ShortTurbo')),
        throwsArgumentError);
    expect(
        () => meshtasticChannelFrequency(
            meshtasticRegion('US'), meshtasticPreset('LongFast'), slot: 0),
        throwsRangeError);
  });

  test('unsupported PHY and source limits return explicit reasons', () {
    expect(meshtasticInputLimit(meshtasticPreset('LongSlow'), 2400000, 0),
        contains('SF12'));
    expect(meshtasticInputLimit(meshtasticPreset('LongFast'), 960000, 0),
        contains('1 MS/s'));
    expect(meshtasticInputLimit(meshtasticPreset('LongFast'), 1000000, 1),
        contains('window'));
    expect(meshtasticInputLimit(meshtasticPreset('LongFast'), 2400000, 0),
        isNull);
  });

  test('region quick tune follows the single centered receiver VFO', () {
    final radio = DemoRadioController();
    final receiver = CenteredReceiver(radio);
    radio.setTuning(centerFrequency: 868000000, vfoOffset: 100000);
    final tuned = tuneMeshtasticRegion(receiver, meshtasticRegion('EU_868'),
        meshtasticPreset('LongFast'));
    expect(tuned, 869525000);
    expect(radio.centerFrequency, tuned);
    expect(radio.vfoOffset, 0);
    radio.dispose();
  });
}
