// SPDX-License-Identifier: GPL-3.0-or-later
// Frequency bands (task t_7b20878c): model, validation, storage, band lookup,
// automatic mode/step on entering a band, preset grouping.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdr_flutter/ui/bands/bands.dart';
import 'package:sdr_flutter/ui/channels/channel_controller.dart';
import 'package:sdr_flutter/ui/channels/channels.dart';
import 'package:sdr_flutter/ui/demo_radio_controller.dart';
import 'package:sdr_flutter/ui/favorites/favorites.dart';
import 'package:sdr_flutter/ui/legacy/centered_receiver.dart';
import 'package:sdr_flutter/ui/legacy/step_grid.dart';
import 'package:sdr_flutter/ui/radio_controller.dart';

/// Counts mode switches and LO retunes.
class _Radio extends DemoRadioController {
  final modes = <DemodMode>[];
  final centers = <double>[];
  @override
  void setMode(DemodMode mode) {
    if (mode != this.mode) modes.add(mode);
    super.setMode(mode);
  }

  @override
  void setTuning({required double centerFrequency, required double vfoOffset}) {
    if (centerFrequency != this.centerFrequency) centers.add(centerFrequency);
    super.setTuning(centerFrequency: centerFrequency, vfoOffset: vfoOffset);
  }
}

BandValidationException _issue(void Function() f) {
  try {
    f();
  } on BandValidationException catch (e) {
    return e;
  }
  fail('expected BandValidationException');
}

void _typeMhz(CenteredReceiver r, String mhz) {
  for (final k in [...mhz.split(''), 'OK']) {
    r.pressKey(k);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('steps', () {
    test('the common step list includes 10 kHz (CB) and 200 kHz (GSM)', () {
      expect(CenteredReceiver.steps, [
        5000,
        6250,
        10000,
        12500,
        25000,
        100000,
        200000,
        1000000,
      ]);
      expect(receiverSteps, CenteredReceiver.steps);
      // Default step is still 12.5 kHz.
      expect(CenteredReceiver(DemoRadioController()).stepHz, 12500);
    });

    test('step labels', () {
      expect(formatStepKhz(5000), '5 kHz');
      expect(formatStepKhz(6250), '6.25 kHz');
      expect(formatStepKhz(12500), '12.5 kHz');
      expect(formatStepKhz(200000), '200 kHz');
    });
  });

  group('defaults', () {
    test('sorted, non-overlapping, steps from the list, on their grid', () {
      expect(defaultBands.map((b) => b.name), [
        'CB 27 MHz',
        'FM',
        'Aircraft',
        '2 m (amateur)',
        'Marine',
        'ISM 433',
        'PMR446',
        'ISM 868',
        'GSM 900',
        'GSM 1800',
      ]);
      for (var i = 0; i < defaultBands.length; i++) {
        final b = defaultBands[i];
        expect(b.startHz < b.endHz, isTrue, reason: b.name);
        expect(receiverSteps, contains(b.stepHz), reason: b.name);
        // The lower edge anchors the band's grid (not necessarily zero Hz).
        if (i > 0) {
          expect(defaultBands[i - 1].endHz < b.startHz, isTrue, reason: b.name);
        }
        expect(defaultBands.where((o) => o.id == b.id), hasLength(1));
      }
      final fm = defaultBands[1];
      expect(
        (fm.startHz, fm.endHz, fm.mode, fm.stepHz),
        (87500000, 108000000, DemodMode.wfm, 100000),
      );
      // CB (CEPT grid C) channels are 26.965 + 10 kHz·n.
      final cb = defaultBands[0];
      expect(
        (cb.startHz, cb.endHz, cb.mode, cb.stepHz),
        (26965000, 27405000, DemodMode.am, 10000),
      );
      for (var ch = 26965000; ch <= 27405000; ch += 10000) {
        expect(
          snapToStep(ch, cb.stepHz, origin: cb.startHz),
          ch,
          reason: '$ch',
        );
      }
      // Channel grids of the other defaults are nodes of their steps.
      for (final (name, first, spacing, count) in [
        ('Marine', 156025000, 25000, 57),
        ('ISM 433', 433075000, 25000, 69), // LPD69
        ('PMR446', 446006250, 12500, 16),
        ('2 m (amateur)', 144000000, 12500, 161),
      ]) {
        final b = defaultBands.firstWhere((b) => b.name == name);
        for (var i = 0; i < count; i++) {
          final ch = first + i * spacing;
          expect(b.contains(ch), isTrue, reason: '$name $ch');
          expect(snapToStep(ch, b.stepHz), ch, reason: '$name $ch');
        }
      }
      final air = defaultBands[2];
      expect(
        (air.startHz, air.endHz, air.mode, air.stepHz),
        (118000000, 136975000, DemodMode.am, 25000),
      );
    });

    test('clean install gets the default set', () async {
      final repo = BandsRepository();
      await repo.load();
      expect(repo.entries.map((b) => b.id), defaultBands.map((b) => b.id));
      await repo.flush();
    });

    test('existing install without stored bands gets the default set, '
        'without touching other keys', () async {
      SharedPreferences.setMockInitialValues({
        'receiver_step_hz_v1': 25000,
        'single_vfo_favorites_v1': '{"version":2,"entries":[]}',
      });
      final repo = BandsRepository();
      await repo.load();
      expect(repo.entries, hasLength(defaultBands.length));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('receiver_step_hz_v1'), 25000);
    });

    test('a deleted default band does not come back after restart', () async {
      final repo = BandsRepository();
      await repo.load();
      repo.delete('band-fm');
      await repo.flush();
      final reopened = BandsRepository();
      await reopened.load();
      expect(reopened.entries.any((b) => b.id == 'band-fm'), isFalse);
      expect(reopened.entries.any((b) => b.name == 'FM'), isFalse);
      expect(reopened.entries, hasLength(defaultBands.length - 1));
      // Deleting all of them leaves an empty list after restart.
      for (final b in reopened.entries) {
        reopened.delete(b.id);
      }
      await reopened.flush();
      final third = BandsRepository();
      await third.load();
      expect(third.entries, isEmpty);
    });

    test('corrupt storage falls back to the defaults, no crash', () async {
      for (final bad in [
        'not json',
        '{"entries": 5}',
        '[]',
        '{"version":1,"entries":[{"id":1}]}',
      ]) {
        SharedPreferences.setMockInitialValues({
          BandsRepository.storageKey: bad,
        });
        final repo = BandsRepository();
        await repo.load();
        expect(
          repo.entries.map((b) => b.id),
          defaultBands.map((b) => b.id),
          reason: bad,
        );
      }
    });

    test('invalid stored entries (overlap, bad step) are skipped', () async {
      SharedPreferences.setMockInitialValues({
        BandsRepository.storageKey: jsonEncode({
          'version': 1,
          'nextId': 3,
          'seenDefaults': [for (final b in defaultBands) b.id],
          'entries': [
            {
              'id': 'user-0',
              'name': 'A',
              'startHz': 100000000,
              'endHz': 101000000,
              'mode': 'NFM',
              'stepHz': 12500,
            },
            {
              'id': 'user-1',
              'name': 'B overlaps A',
              'startHz': 101000000,
              'endHz': 102000000,
              'mode': 'NFM',
              'stepHz': 12500,
            },
            {
              'id': 'user-2',
              'name': 'bad step',
              'startHz': 200000000,
              'endHz': 201000000,
              'mode': 'NFM',
              'stepHz': 7000,
            },
          ],
        }),
      });
      final repo = BandsRepository();
      await repo.load();
      expect(repo.entries.map((b) => b.name), ['A']);
    });
  });

  group('validation', () {
    late BandsRepository repo;
    setUp(() async {
      repo = BandsRepository();
      await repo.load();
      for (final b in repo.entries) {
        repo.delete(b.id);
      }
    });

    Band addA() => repo.add(
      name: 'A',
      startHz: 100000000,
      endHz: 101000000,
      mode: DemodMode.nfm,
      stepHz: 12500,
    );

    test('empty name, start ≥ end, out of range, step not in the list', () {
      expect(
        _issue(
          () => repo.add(
            name: '  ',
            startHz: 1,
            endHz: 2,
            mode: DemodMode.am,
            stepHz: 5000,
          ),
        ).issue,
        BandIssue.name,
      );
      expect(
        _issue(
          () => repo.add(
            name: 'x',
            startHz: 2000000,
            endHz: 2000000,
            mode: DemodMode.am,
            stepHz: 5000,
          ),
        ).issue,
        BandIssue.order,
      );
      expect(
        _issue(
          () => repo.add(
            name: 'x',
            startHz: 3000000,
            endHz: 2000000,
            mode: DemodMode.am,
            stepHz: 5000,
          ),
        ).issue,
        BandIssue.order,
      );
      expect(
        _issue(
          () => repo.add(
            name: 'x',
            startHz: 0,
            endHz: 2000000,
            mode: DemodMode.am,
            stepHz: 5000,
          ),
        ).issue,
        BandIssue.outOfRange,
      );
      expect(
        _issue(
          () => repo.add(
            name: 'x',
            startHz: 1000000,
            endHz: bandMaxHz + 1,
            mode: DemodMode.am,
            stepHz: 5000,
          ),
        ).issue,
        BandIssue.outOfRange,
      );
      expect(
        _issue(
          () => repo.add(
            name: 'x',
            startHz: 1000000,
            endHz: 2000000,
            mode: DemodMode.am,
            stepHz: 7000,
          ),
        ).issue,
        BandIssue.step,
      );
      expect(repo.entries, isEmpty);
    });

    test('overlap, including a shared boundary Hz, names the other band', () {
      addA();
      for (final (s, e) in [
        (101000000, 102000000), // shares the upper edge
        (99000000, 100000000), // shares the lower edge
        (100500000, 100600000), // inside
        (99000000, 102000000), // covers
      ]) {
        final err = _issue(
          () => repo.add(
            name: 'B',
            startHz: s,
            endHz: e,
            mode: DemodMode.nfm,
            stepHz: 12500,
          ),
        );
        expect(err.issue, BandIssue.overlap, reason: '$s-$e');
        expect(err.conflict!.name, 'A');
        expect(err.message, contains('«A»'));
      }
      // 1 Hz apart is not an overlap.
      repo.add(
        name: 'B',
        startHz: 101000001,
        endHz: 102000000,
        mode: DemodMode.nfm,
        stepHz: 12500,
      );
      expect(repo.entries, hasLength(2));
    });

    test('editing a band does not collide with itself, but with others', () {
      final a = addA();
      final b = repo.add(
        name: 'B',
        startHz: 105000000,
        endHz: 106000000,
        mode: DemodMode.am,
        stepHz: 25000,
      );
      repo.edit(
        a.id,
        name: 'A2',
        startHz: 100000000,
        endHz: 101500000,
        mode: DemodMode.wfm,
        stepHz: 100000,
      );
      expect(repo.entries.first.name, 'A2');
      expect(repo.entries.first.endHz, 101500000);
      final err = _issue(
        () => repo.edit(
          a.id,
          name: 'A2',
          startHz: 100000000,
          endHz: 105000000,
          mode: DemodMode.wfm,
          stepHz: 100000,
        ),
      );
      expect(err.issue, BandIssue.overlap);
      expect(err.conflict!.id, b.id);
      expect(repo.entries.first.endHz, 101500000, reason: 'unchanged');
      expect(repo.check(id: a.id, startHz: 1, endHz: 2), isNull);
    });

    test('list is sorted by start frequency and persists', () async {
      repo.add(
        name: 'high',
        startHz: 400000000,
        endHz: 401000000,
        mode: DemodMode.nfm,
        stepHz: 6250,
      );
      addA();
      repo.add(
        name: 'low',
        startHz: 3000000,
        endHz: 4000000,
        mode: DemodMode.usb,
        stepHz: 5000,
      );
      expect(repo.entries.map((b) => b.name), ['low', 'A', 'high']);
      final a = repo.entries[1];
      // Moving A above "high" re-sorts.
      repo.edit(
        a.id,
        name: 'A',
        startHz: 500000000,
        endHz: 501000000,
        mode: DemodMode.nfm,
        stepHz: 12500,
      );
      expect(repo.entries.map((b) => b.name), ['low', 'high', 'A']);
      await repo.flush();
      final reopened = BandsRepository();
      await reopened.load();
      expect(
        reopened.entries.map(
          (b) => (b.id, b.name, b.startHz, b.endHz, b.mode, b.stepHz),
        ),
        repo.entries.map(
          (b) => (b.id, b.name, b.startHz, b.endHz, b.mode, b.stepHz),
        ),
      );
      // New ids never reuse old ones after reload.
      final c = reopened.add(
        name: 'C',
        startHz: 700000000,
        endHz: 701000000,
        mode: DemodMode.nfm,
        stepHz: 12500,
      );
      expect(repo.entries.map((b) => b.id), isNot(contains(c.id)));
    });
  });

  group('bandAt', () {
    test('inclusive edges; outside every band → null', () async {
      final repo = BandsRepository();
      await repo.load();
      expect(repo.bandAt(87500000)!.name, 'FM');
      expect(repo.bandAt(108000000)!.name, 'FM');
      expect(repo.bandAt(100000000)!.name, 'FM');
      expect(repo.bandAt(87499999), isNull);
      expect(repo.bandAt(108000001), isNull);
      expect(repo.bandAt(125000000)!.name, 'Aircraft');
      expect(repo.bandAt(50000000), isNull);
    });
  });

  group('receiver entering a band', () {
    late _Radio radio;
    late BandsRepository bands;
    late CenteredReceiver r;
    setUp(() async {
      radio = _Radio();
      bands = BandsRepository();
      await bands.load();
      r = CenteredReceiver(radio)..bands = bands;
      r.tune(50000000); // outside every band
      r.changeMode(DemodMode.nfm);
      r.setStepHz(12500);
      r.markCurrentBand();
      radio.modes.clear();
    });
    tearDown(() => radio.dispose());

    test('keypad into FM: WFM, 100 kHz, snapped on the FM grid', () {
      _typeMhz(r, '101.03');
      expect(radio.mode, DemodMode.wfm);
      expect(r.stepHz, 100000);
      expect(radio.tunedFrequency, 101000000);
      expect(radio.centerFrequency, 101000000);
      expect(radio.vfoOffset, 0);
      expect(r.currentBand!.name, 'FM');
    });

    test(
      'a value just outside a band snapping onto its edge enters the band',
      () {
        r.tune(87499000);
        expect(radio.tunedFrequency, 87500000);
        expect(radio.mode, DemodMode.wfm);
        expect(r.stepHz, 100000);
      },
    );

    test('keypad into Aircraft: AM, 25 kHz', () {
      _typeMhz(r, '118.1');
      expect(radio.mode, DemodMode.am);
      expect(r.stepHz, 25000);
      expect(radio.tunedFrequency, 118100000);
      expect(r.currentBand!.name, 'Aircraft');
    });

    test('the band is chosen by the typed value, the snap stays inside', () {
      bands.add(
        name: 'Narrow',
        startHz: 300010000,
        endHz: 300060000,
        mode: DemodMode.am,
        stepHz: 25000,
      );
      // The band's grid starts at 300.010 MHz and stays inside its limits.
      r.tune(300012000);
      expect(r.stepHz, 25000);
      expect(radio.mode, DemodMode.am);
      expect(radio.tunedFrequency, 300010000);
      expect(r.currentBand!.name, 'Narrow');
    });

    test('manual mode/step inside the band is kept until the band is left', () {
      _typeMhz(r, '101.0');
      r.changeMode(DemodMode.nfm);
      r.setStepHz(12500);
      _typeMhz(r, '102.0125');
      expect(radio.mode, DemodMode.nfm, reason: 'still inside FM');
      expect(r.stepHz, 12500);
      expect(radio.tunedFrequency, 102012500);
      // Leaving: nothing is rolled back.
      _typeMhz(r, '60.0');
      expect(radio.mode, DemodMode.nfm);
      expect(r.stepHz, 12500);
      expect(r.currentBand, isNull);
      // Entering again applies the band once more.
      _typeMhz(r, '99.9');
      expect(radio.mode, DemodMode.wfm);
      expect(r.stepHz, 100000);
    });

    test('band to band: the new band is applied', () {
      _typeMhz(r, '101.0');
      _typeMhz(r, '145.5');
      expect(radio.mode, DemodMode.nfm);
      expect(r.stepHz, 12500);
      expect(r.currentBand!.name, '2 m (amateur)');
    });

    test('without bands (null) the receiver behaves as before', () {
      r.bands = null;
      _typeMhz(r, '101.03');
      expect(radio.mode, DemodMode.nfm);
      expect(r.stepHz, 12500);
      expect(radio.tunedFrequency, 101025000);
    });

    test('drag: name follows at once, mode/step applied once on release', () {
      r.tune(87000000);
      radio.modes.clear();
      radio.centers.clear();
      r.beginDrag();
      for (var i = 0; i < 80; i++) {
        r.dragBy(12500); // walks into FM (87.5 MHz)
      }
      expect(radio.tunedFrequency, 88000000);
      expect(r.currentBand!.name, 'FM', reason: 'status is live');
      expect(radio.mode, DemodMode.nfm, reason: 'no mode change during drag');
      expect(radio.modes, isEmpty);
      expect(r.stepHz, 12500, reason: 'no step change during drag');
      r.endDrag();
      expect(radio.modes, [DemodMode.wfm], reason: 'exactly once');
      expect(r.stepHz, 100000);
      expect(radio.tunedFrequency, 88000000);
      expect(radio.centerFrequency, 88000000);
      expect(radio.vfoOffset, 0);
      // A second drag inside the band does not re-apply it.
      r.changeMode(DemodMode.nfm);
      radio.modes.clear();
      r.beginDrag();
      r.dragBy(100000);
      r.endDrag();
      expect(radio.modes, isEmpty);
      expect(radio.mode, DemodMode.nfm);
      r.dispose();
    });

    test('drag cancelled outside a band changes nothing', () {
      r.beginDrag();
      r.dragBy(25000);
      r.endDrag();
      expect(radio.modes, isEmpty);
      expect(r.stepHz, 12500);
      expect(radio.vfoOffset, 0);
    });

    test('preset/channel: its own mode wins, the step is the band\'s', () {
      r.apply(125000000, DemodMode.nfm); // "preset" in Aircraft with NFM
      expect(radio.mode, DemodMode.nfm);
      expect(r.stepHz, 25000);
      expect(r.currentBand!.name, 'Aircraft');
      expect(radio.tunedFrequency, 125000000);
      // The band is "entered": a keypad tune inside keeps NFM.
      _typeMhz(r, '126.0');
      expect(radio.mode, DemodMode.nfm);
    });

    test('an edited band applies its new settings on the next entry', () {
      final fm = bands.entries.firstWhere((b) => b.name == 'FM');
      bands.edit(
        fm.id,
        name: 'FM broadcast',
        startHz: fm.startHz,
        endHz: fm.endHz,
        mode: DemodMode.nfm,
        stepHz: 200000,
      );
      _typeMhz(r, '100.1');
      expect(radio.mode, DemodMode.nfm);
      expect(r.stepHz, 200000);
      expect(radio.tunedFrequency, 100100000);
      expect(r.currentBand!.name, 'FM broadcast');
    });
  });

  group('channels', () {
    test('selecting a channel: channel mode wins, band step is used', () async {
      final radio = _Radio();
      final bands = BandsRepository();
      await bands.load();
      final r = CenteredReceiver(radio)..bands = bands;
      r.tune(50000000);
      r.setStepHz(5000);
      r.markCurrentBand();
      final repo = ChannelsRepository();
      final ctl = ChannelController(
        radio: radio,
        receiver: r,
        channels: repo,
        favorites: FavoritesRepository(),
      );
      final fm = repo.add(frequencyHz: 101200000, mode: DemodMode.nfm);
      final other = repo.add(frequencyHz: 50000000, mode: DemodMode.am);
      ctl.attach();
      expect(ctl.select(fm.id), isTrue);
      expect(radio.mode, DemodMode.nfm);
      expect(r.stepHz, 100000);
      expect(radio.tunedFrequency, 101200000);
      expect(ctl.select(other.id), isTrue);
      expect(r.stepHz, 100000, reason: 'leaving does not roll back');
      radio.dispose();
    });

    test('restoring the active channel on attach does not apply the band '
        '(the persisted step is kept)', () async {
      final radio = _Radio();
      final bands = BandsRepository();
      await bands.load();
      final r = CenteredReceiver(radio)..bands = bands;
      r.setStepHz(12500);
      final repo = ChannelsRepository();
      repo.add(frequencyHz: 145500000, mode: DemodMode.am);
      final ctl = ChannelController(
        radio: radio,
        receiver: r,
        channels: repo,
        favorites: FavoritesRepository(),
      );
      ctl.attach();
      expect(radio.tunedFrequency, 145500000);
      expect(radio.mode, DemodMode.am);
      expect(r.stepHz, 12500);
      // …but the receiver now counts as inside the band.
      r.changeMode(DemodMode.usb);
      r.tune(145600000);
      expect(radio.mode, DemodMode.usb);
      radio.dispose();
    });

    test('scanning never changes mode/step because of bands', () async {
      final radio = _Radio();
      final bands = BandsRepository();
      await bands.load();
      final r = CenteredReceiver(radio)..bands = bands;
      r.tune(50000000);
      r.setStepHz(5000);
      r.markCurrentBand();
      final repo = ChannelsRepository();
      final ctl = ChannelController(
        radio: radio,
        receiver: r,
        channels: repo,
        favorites: FavoritesRepository(),
      );
      final air = repo.add(frequencyHz: 125000000, mode: DemodMode.nfm);
      final fm = repo.add(frequencyHz: 101000000, mode: DemodMode.nfm);
      repo.activate(null);
      ctl.attach();
      radio.modes.clear();
      ctl.setScanning(true);
      expect(ctl.scanTo(air), isTrue);
      expect(ctl.scanTo(fm), isTrue);
      ctl.setScanning(false);
      expect(r.stepHz, 5000);
      expect(radio.mode, DemodMode.nfm);
      expect(radio.tunedFrequency, 101000000);
      radio.dispose();
    });
  });

  group('preset grouping', () {
    Favorite fav(String id, int hz) => Favorite(
      id: id,
      frequencyHz: hz,
      name: id,
      mode: DemodMode.nfm,
      category: 'VHF',
    );

    test('sections by band start, presets by frequency, "Out of band" last, '
        'empty sections hidden', () async {
      final bands = BandsRepository();
      await bands.load();
      final groups = groupPresetsByBand([
        fav('air2', 127000000),
        fav('out1', 50000000),
        fav('fm1', 101000000),
        fav('air1', 118100000),
        fav('out0', 30000000),
        fav('fm0', 88000000),
      ], bands.entries);
      expect(groups.map((g) => g.band?.name), ['FM', 'Aircraft', null]);
      expect(groups.map((g) => g.presets.map((f) => f.id).toList()), [
        ['fm0', 'fm1'],
        ['air1', 'air2'],
        ['out0', 'out1'],
      ]);
      expect(groupPresetsByBand(const [], bands.entries), isEmpty);
    });

    test('editing/deleting a band regroups, presets stay', () async {
      final bands = BandsRepository();
      await bands.load();
      final presets = [fav('fm', 101000000), fav('air', 125000000)];
      bands.delete('band-air');
      var groups = groupPresetsByBand(presets, bands.entries);
      expect(groups.map((g) => g.band?.name), ['FM', null]);
      final fm = bands.entries.firstWhere((b) => b.id == 'band-fm');
      bands.edit(
        fm.id,
        name: 'FM',
        startHz: 87500000,
        endHz: 100000000,
        mode: fm.mode,
        stepHz: fm.stepHz,
      );
      groups = groupPresetsByBand(presets, bands.entries);
      expect(groups.map((g) => g.band?.name), [null]);
      expect(groups.single.presets, hasLength(2));
    });
  });

  test('band range text', () {
    expect(formatBandRange(defaultBands[1]), '87.500–108.000 MHz');
  });

  test('presetCategoryFor stays a valid storage category', () {
    for (final hz in [27000000, 100000000, 125000000, 145500000, 433920000]) {
      final c = presetCategoryFor(hz, DemodMode.nfm);
      expect(favoriteCategories.skip(1), contains(c));
    }
    expect(snapToStep(26965000, 10000, origin: 26965000), 26965000);
  });
}
